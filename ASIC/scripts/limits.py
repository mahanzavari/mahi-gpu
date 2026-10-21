#!/usr/bin/env python3
"""Characterization tests for the documented limitations (docs/04-limitations.md).

Each case runs a tiny hand-built program on the RTL (via src/tb/random/tb_random.sv) and asserts the
*documented, limited* behaviour. A case that FAILS here means the design changed: either the limitation was
fixed (update docs/04-limitations.md and delete/flip the case) or something regressed.

    scripts/limits.py --bin build/rand/rand_tb [--only L1,L5]
"""
import argparse, os, subprocess, sys, tempfile
sys.path.insert(0, os.path.dirname(__file__))
from isa import *
from gen import write_hex

ZERO = 0          # R0 is 0 after reset in all these programs (never written)
OUT = 300         # result words live at OUT + tid


def run(binary, words, maxcyc=40000, lat=0, dmem=None):
    """Run a program; returns (done: bool, mem: list[1024])."""
    with tempfile.TemporaryDirectory() as d:
        write_hex(f'{d}/p.hex', words); write_hex(f'{d}/d.hex', dmem or [0] * 128)
        p = subprocess.run([binary, f'+prog={d}/p.hex', f'+dmem={d}/d.hex', f'+out={d}/o.hex', f'+maxcyc={maxcyc}',
                            f'+lat={lat}', '+verilator+quiet'], capture_output=True, text=True, timeout=120)
        if 'TB_TIMEOUT' in p.stdout + p.stderr: return False, [0] * 1024
        return True, [int(l, 16) for l in open(f'{d}/o.hex')]


def model(words, **kw):
    mem = {}
    Machine(words, mem, **kw).run()
    return [mem.get(i, 0) for i in range(1024)]


def case_L1(b):
    """Warp-divergent loop, then SYNC, then read the slot of the neighbouring LANE (tid^1) of the same warp.
    A correct barrier gives 100+(tid^1) for all threads; with L1 the earlier lane groups pass SYNC before later
    groups have stored, so some threads read 0."""
    c = [enc_I('CONST', 6, 0, 3), enc_I('CONST', 7, 0, 1),
         enc_R('AND', 1, 31, 6), enc_R('ADD', 1, 1, 7)]                       # R1 = (tid&3)+1 : lane-divergent trip count
    top = len(c)
    c += [enc_R('ADD', 5, 5, 7), enc_R('SUB', 1, 1, 7), enc_R('CMP', 0, 1, ZERO), enc_BR(1, top)]
    c += [enc_I('CONST', 2, 0, 100), enc_R('ADD', 2, 2, 31), enc_I('STSH', 2, 31, 0), OP['SYNC'] << 26]
    c += [enc_R('XOR', 3, 31, 7), enc_R('LDSH', 8, 3, 0), enc_I('STR', 8, 31, OUT), enc_EXIT()]
    want = [100 + (t ^ 1) for t in range(8)]
    ref = model(c)
    assert [ref[OUT + t] for t in range(8)] == want, 'model disagrees with hand computation'
    done, mem = run(b, c)
    got = [mem[OUT + t] for t in range(8)]
    stale = [t for t in range(8) if got[t] != want[t]]
    ok = done and len(stale) > 0 and all(got[t] in (0, want[t]) for t in range(8))
    return ok, f'{len(stale)}/8 threads read stale shared memory past SYNC (got {got})' if ok else \
        f'expected stale reads (limitation L1), got {got}, done={done}'


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
    pre = [mem[OUT + 16 + t] for t in range(8)]; cmpv = [mem[OUT + t] for t in range(8)]
    ok = done and pre == [111] * 8 and cmpv == [1] * 8
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
    good8 = ok8 and [m8[OUT + t] for t in range(8)] == [8] * 8 and [m8[OUT + 16 + t] for t in range(8)] == [1] * 8
    ok9, m9 = run(b, nested_calls(9), maxcyc=30000)
    w9 = model(nested_calls(9))
    assert [w9[OUT + t] for t in range(8)] == [9] * 8
    bad9 = (not ok9) or [m9[OUT + t] for t in range(8)] != [9] * 8 or [m9[OUT + 16 + t] for t in range(8)] != [1] * 8
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
    got = [mem[OUT + t] for t in range(8)]
    ok = done and got == [0x219E0000] * 8
    return ok, f'result {got[0]:08x} (IEEE would give 219e0651)' if ok else f'got {[hex(x) for x in got]}'


def case_L12(b):
    """Division by zero and a bad address kill the warp silently: the kernel still finishes (done) but stores are missing."""
    div0 = [enc_I('CONST', 1, 0, 5), enc_I('CONST', 2, 0, 0), enc_R('DIV', 3, 1, 2),
            enc_I('CONST', 4, 0, 77), enc_I('STR', 4, 31, OUT), enc_EXIT()]
    badaddr = [enc_LUI(1, 0x00010), enc_I('LDR', 3, 1, 0), enc_I('CONST', 4, 0, 77), enc_I('STR', 4, 31, OUT), enc_EXIT()]
    d1, m1 = run(b, div0); d2, m2 = run(b, badaddr)
    ok = d1 and d2 and all(m1[OUT + t] == 0 for t in range(8)) and all(m2[OUT + t] == 0 for t in range(8))
    return ok, 'done asserted, post-fault store missing (div0 and bad address)' if ok else \
        f'div0 done={d1} stores={m1[OUT:OUT+8]}, badaddr done={d2} stores={m2[OUT:OUT+8]}'


CASES = {'L1': case_L1, 'L5': case_L5, 'L6': case_L6, 'L8': case_L8, 'L12': case_L12}

if __name__ == '__main__':
    ap = argparse.ArgumentParser(); ap.add_argument('--bin', required=True); ap.add_argument('--only', default='')
    a = ap.parse_args()
    sel = [x for x in a.only.split(',') if x] or list(CASES)
    bad = 0
    for k in sel:
        try: ok, msg = CASES[k](a.bin)
        except Exception as e: ok, msg = False, f'exception: {e!r}'
        print(f'{k:4} {"PASS (limitation present)" if ok else "FAIL (documented behaviour NOT observed)"}: {msg}')
        bad += not ok
    sys.exit(1 if bad else 0)
