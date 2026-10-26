#!/usr/bin/env python3
"""Characterization tests for the documented limitations (docs/04-limitations.md).

Each case runs a tiny hand-built program on the RTL (via src/tb/random/tb_random.sv) and asserts the
*documented* behaviour: the limited behaviour for open items, the fixed behaviour for resolved ones (L1 is now a
fault, L2 divides, L12 reports the fault). A case that FAILS here means the design changed: update
docs/04-limitations.md and the case, or something regressed.

    scripts/limits.py --bin build/rand/rand_tb [--only L1,L5]
"""
import argparse, os, re, subprocess, sys, tempfile
sys.path.insert(0, os.path.dirname(__file__))
from isa import *
from gen import write_hex

ZERO = 0          # R0 is 0 after reset in all these programs (never written)
OUT = 300         # result words live at OUT + tid


def run_f(binary, words, maxcyc=40000, lat=0, dmem=None):
    """Run a program; returns (done: bool, mem: list[1024], fault: (cause, warp, pc) or None)."""
    with tempfile.TemporaryDirectory() as d:
        write_hex(f'{d}/p.hex', words); write_hex(f'{d}/d.hex', dmem or [0] * 128)
        p = subprocess.run([binary, f'+prog={d}/p.hex', f'+dmem={d}/d.hex', f'+out={d}/o.hex', f'+maxcyc={maxcyc}',
                            f'+lat={lat}', f'+threads={THREADS}', '+verilator+quiet'], capture_output=True, text=True, timeout=120)
        log = p.stdout + p.stderr
        if 'TB_TIMEOUT' in log: return False, [0] * 1024, None
        m = re.search(r'TB_FAULT cause=(\d+) warp=(\d+) pc=(\d+)', log)
        return True, [int(l, 16) for l in open(f'{d}/o.hex')], tuple(map(int, m.groups())) if m else None


def run(binary, words, **kw):
    """Run a program; returns (done: bool, mem: list[1024])."""
    return run_f(binary, words, **kw)[:2]


def model(words, **kw):
    mem = {}
    Machine(words, mem, **kw).run()
    return [mem.get(i, 0) for i in range(1024)]


def case_L1(b):
    """Warp-divergent loop, then SYNC. The lanes leave the loop at different times and reach SYNC with the
    divergence stack non-empty; that used to release the barrier early (stale shared-memory reads), it is now a
    fault: cause 3 at the SYNC, kernel still finishes. Same program without divergence (uniform trip count) passes."""
    def prog(divergent):
        c = [enc_I('CONST', 6, 0, 3), enc_I('CONST', 7, 0, 1),
             enc_R('AND', 1, 31, 6) if divergent else enc_R('AND', 1, ZERO, 6), enc_R('ADD', 1, 1, 7)]
        top = len(c)
        c += [enc_R('ADD', 5, 5, 7), enc_R('SUB', 1, 1, 7), enc_R('CMP', 0, 1, ZERO), enc_BR(1, top)]
        c += [enc_I('CONST', 2, 0, 100), enc_R('ADD', 2, 2, 31), enc_I('STSH', 2, 31, 0), OP['SYNC'] << 26]
        c += [enc_R('XOR', 3, 31, 7), enc_R('LDSH', 8, 3, 0), enc_I('STR', 8, 31, OUT), enc_EXIT()]
        return c
    sync_pc = 11
    want = [100 + (t ^ 1) for t in range(THREADS)]
    du, mu, fu = run_f(b, prog(False))
    uniform_ok = du and fu is None and [mu[OUT + t] for t in range(THREADS)] == want
    dd, _, fd = run_f(b, prog(True))
    fault_ok = dd and fd is not None and fd[0] == 3 and fd[2] == sync_pc
    ok = uniform_ok and fault_ok
    return ok, f'uniform loop + SYNC correct; divergent SYNC faults (cause 3, pc {sync_pc})' if ok else \
        f'uniform done={du} fault={fu} got={[mu[OUT + t] for t in range(THREADS)]}; divergent done={dd} fault={fd}'


def case_L2(b):
    """DIV/MOD compute the unsigned quotient/remainder on the shared iterative divider (were stubbed to 0)."""
    c = [enc_I('CONST', 6, 0, 7), enc_I('CONST', 7, 0, 3), enc_I('CONST', 8, 0, 1000),
         enc_R('MUL', 1, 31, 6), enc_R('ADD', 1, 1, 8),          # R1 = 7*tid + 1000
         enc_R('ADD', 2, 31, 7),                                  # R2 = tid + 3
         enc_R('DIV', 3, 1, 2), enc_R('MOD', 4, 1, 2), enc_R('ADD', 5, 3, 4),   # back-to-back DIV, MOD, dependent use
         enc_I('STR', 3, 31, OUT), enc_I('STR', 4, 31, OUT + 16), enc_I('STR', 5, 31, OUT + 32), enc_EXIT()]
    ref = model(c)
    done, mem, f = run_f(b, c)
    rng = [o + t for o in (OUT, OUT + 16, OUT + 32) for t in range(THREADS)]
    ok = done and f is None and all(mem[i] == ref[i] for i in rng)
    return ok, 'DIV/MOD match the golden model' if ok else \
        f'done={done} fault={f} got={[mem[i] for i in rng]} want={[ref[i] for i in rng]}'


def case_L5(b):
    """BR 111 before any CMP is not taken; CMP is unsigned (-1 > 1)."""
    c = [enc_BR(7, 3),                                   # 0: never taken (NZP==0)
         enc_I('CONST', 3, 0, 111), enc_I('STR', 3, 31, OUT + 16),   # 1,2: executed because the branch fell through
         enc_I('CONST', 1, 0, -1), enc_I('CONST', 2, 0, 1), enc_R('CMP', 0, 1, 2), enc_BR(1, 10),   # 3-6: P taken iff unsigned
         enc_I('CONST', 4, 0, 2), enc_BR(7, 11),         # 7,8: signed-compare path
         0,                                              # 9: pad
         enc_I('CONST', 4, 0, 1),                        # 10: unsigned path
         enc_I('STR', 4, 31, OUT), enc_EXIT()]           # 11,12
    # fix target of the two forward branches (pad shifts indexes): recompute explicitly
    c[6] = enc_BR(1, 10); c[8] = enc_BR(7, 11)
    c[9] = enc_I('CONST', 4, 0, 2)                       # filler (not reached when unsigned)
    done, mem = run(b, c)
    pre = [mem[OUT + 16 + t] for t in range(THREADS)]; cmpv = [mem[OUT + t] for t in range(THREADS)]
    ok = done and pre == [111] * THREADS and cmpv == [1] * THREADS
    return ok, f'pre-CMP branch not taken ({pre[0]}), -1>1 unsigned ({cmpv[0]})' if ok else f'got pre={pre} cmp={cmpv}'


def nested_calls(depth):
    """main calls F1 -> F2 -> ... -> F<depth>, each adds 1 to R5; main then stores R5 and a marker."""
    main = [enc_I('CONST', 6, 0, 1), enc_CALL(0),  enc_I('STR', 5, 31, OUT), enc_I('CONST', 7, 0, 1),
            enc_I('STR', 7, 31, OUT + 16), enc_EXIT()]
    base = len(main)
    funcs = []
    for k in range(depth):
        addr = base + 3 * k
        funcs += [enc_R('ADD', 5, 5, 6), enc_CALL(addr + 3) if k < depth - 1 else enc_I('CONST', 9, 0, 0), enc_RET()]
    main[1] = enc_CALL(base)
    return main + funcs


def case_L6(b):
    """8 nested calls work; the 9th wraps the return-address stack and breaks the unwinding."""
    ok8, m8 = run(b, nested_calls(8), maxcyc=30000)
    w8 = model(nested_calls(8))
    good8 = ok8 and [m8[OUT + t] for t in range(THREADS)] == [8] * THREADS and [m8[OUT + 16 + t] for t in range(THREADS)] == [1] * THREADS
    ok9, m9 = run(b, nested_calls(9), maxcyc=30000)
    w9 = model(nested_calls(9))
    assert [w9[OUT + t] for t in range(THREADS)] == [9] * THREADS
    bad9 = (not ok9) or [m9[OUT + t] for t in range(THREADS)] != [9] * THREADS or [m9[OUT + 16 + t] for t in range(THREADS)] != [1] * THREADS
    ok = good8 and bad9
    return ok, ('depth 8 correct; depth 9 ' + ('hangs' if not ok9 else 'gives wrong results')) if ok else \
        f'depth8 ok={good8}, depth9 broken={bad9}'


def case_L8(b):
    """0 * 2^127 + c drops low bits of c (IEEE would return c unchanged)."""
    c = [enc_LUI(2, 0x7F000),                              # R2 = 0x7F000000 (exponent 254)
         enc_LUI(3, 0x219E0), enc_I('CONST', 4, 0, 0x651), enc_R('OR', 3, 3, 4),   # R3 = 0x219E0651
         enc_R('FMA', 3, 1, 2),                            # R3 = R1(0) * R2 + R3
         enc_I('STR', 3, 31, OUT), enc_EXIT()]
    done, mem = run(b, c)
    got = [mem[OUT + t] for t in range(THREADS)]
    ok = done and got == [0x219E0000] * THREADS
    return ok, f'result {got[0]:08x} (IEEE would give 219e0651)' if ok else f'got {[hex(x) for x in got]}'


def case_L12(b):
    """Division by zero and a bad address stop the warp; the kernel still finishes (done), the post-fault store is
    missing, and the fault is reported (gpu.fault -> STATUS[4] / FAULT_INFO): cause 1 at pc 2, cause 2 at pc 1."""
    div0 = [enc_I('CONST', 1, 0, 5), enc_I('CONST', 2, 0, 0), enc_R('DIV', 3, 1, 2),
            enc_I('CONST', 4, 0, 77), enc_I('STR', 4, 31, OUT), enc_EXIT()]
    badaddr = [enc_LUI(1, 0x00010), enc_I('LDR', 3, 1, 0), enc_I('CONST', 4, 0, 77), enc_I('STR', 4, 31, OUT), enc_EXIT()]
    d1, m1, f1 = run_f(b, div0); d2, m2, f2 = run_f(b, badaddr)
    ok = d1 and d2 and all(m1[OUT + t] == 0 for t in range(THREADS)) and all(m2[OUT + t] == 0 for t in range(THREADS)) \
        and f1 is not None and (f1[0], f1[2]) == (1, 2) and f2 is not None and (f2[0], f2[2]) == (2, 1)
    return ok, f'done asserted, post-fault store missing, fault reported (div0 {f1}, badaddr {f2})' if ok else \
        f'div0 done={d1} fault={f1} stores={m1[OUT:OUT+THREADS]}, badaddr done={d2} fault={f2} stores={m2[OUT:OUT+THREADS]}'


def case_L14(b):
    """A store to 0x4000+300 (beyond the 14-bit data address bus but below the 0xFFFF fault limit) is not
    faulted: it aliases onto address 300."""
    c = [enc_LUI(1, 0x00004), enc_I('CONST', 2, 0, 300), enc_R('ADD', 1, 1, 2),     # R1 = 0x4000 + 300
         enc_I('CONST', 3, 0, 0x1234), enc_I('STR', 3, 1, 0), enc_EXIT()]
    done, mem = run(b, c)
    ok = done and mem[300] == 0x1234
    return ok, 'store to 0x412C landed at 300 (14-bit alias, no fault)' if ok else f'done={done}, mem[300]={mem[300]:#x}'


CASES = {'L1': case_L1, 'L2': case_L2, 'L5': case_L5, 'L6': case_L6, 'L8': case_L8, 'L12': case_L12, 'L14': case_L14}

if __name__ == '__main__':
    ap = argparse.ArgumentParser(); ap.add_argument('--bin', required=True); ap.add_argument('--only', default='')
    a = ap.parse_args()
    sel = [x for x in a.only.split(',') if x] or list(CASES)
    bad = 0
    for k in sel:
        try: ok, msg = CASES[k](a.bin)
        except Exception as e: ok, msg = False, f'exception: {e!r}'
        print(f'{k:4} {"PASS (documented behaviour observed)" if ok else "FAIL (documented behaviour NOT observed)"}: {msg}')
        bad += not ok
    sys.exit(1 if bad else 0)
