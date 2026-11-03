#!/usr/bin/env python3
"""Vivado simulator (xsim) flow for the FPGA tree -- runs on Windows or Linux, no make needed.

  python sim/xsim_run.py unit                                  unit tests (8 modules, + ALU with the DIV/MOD stub)
  python sim/xsim_run.py system                                NZP/CALL/RET test, 2-core 5x5 matmul (shared divider
                                                               and USE_COMB_DIV)
  python sim/xsim_run.py rand [--seeds 0 50] [--lat 6] [--jobs 8]   random programs vs the Python golden model
  python sim/xsim_run.py all                                   unit + system + rand (seeds 0-40 at lat 0 and lat 6)

  --profile fpga   TARGET_FPGA (default): 2 cores x 4 warps x 4 lanes, 64K-word spaces, 256-line L2
  --profile sim    no profile define: same shape, 32-bit address spaces
  --vivado DIR     Vivado install (default: $XILINX_VIVADO, else the newest C:/Xilinx/Vivado/<ver>)

Builds go to sim/build/<test>/ (git-ignored); failing random seeds are kept in sim/build/rand_fail/lat<l>_seed_<n>/.

The random test runs one block of 16 threads (4 warps x 4 lanes) on core 0: generated programs use R31 (block-local
thread id) for their private memory regions, so a second block would overwrite the first. Both cores are exercised
by tb_matmul. The golden model (gen.py, isa.py) is the one in ASIC/scripts, shared with the ASIC flow.

xsim 2019.1 notes:
  * All tool options go through --file: the Windows .bat wrappers split arguments at '=' (defines, plusargs).
  * The SVA checkers in src/rtl/sva are not compiled: xsim 2019.1 rejects $past in properties and ignores several
    assertions. MAHI_SIM_CHECKS (a plain $error in core.sv: no operand is read while still in flight) stays on.
  * SYNTHESIS is defined, as in the Verilator flow, so the RTL's debug $display blocks are off.
  * The SVA files and some testbenches have no `timescale; xelab gives them 1ns/1ns.
"""
import argparse, glob, os, queue, shutil, subprocess, sys, time
from concurrent.futures import ThreadPoolExecutor

# Forward slashes only: xsim passes plusargs through Tcl, which eats Windows backslashes.
FPGA = os.path.dirname(os.path.dirname(os.path.abspath(__file__))).replace('\\', '/')
REPO = os.path.dirname(FPGA)
RTL, TB = f'{FPGA}/src/rtl', f'{FPGA}/src/tb'
BUILD = f'{FPGA}/sim/build'
GOLDEN = f'{REPO}/ASIC/scripts'

# Compile order: gpu_pkg.sv first (leaf parameter defaults reference it).
RTL_SOURCES = ['include/gpu_pkg.sv', 'dispatch.sv', 'fetcher.sv', 'decoder.sv', 'registers.sv', 'alu.sv', 'pc.sv',
               'lsu.sv', 'scheduler.sv', 'shared_mem.sv', 'dcache.sv', 'icache.sv', 'mahi_sram.sv', 'l2_data_array.sv',
               'l2_cache.sv', 'victim_write_buffer.sv', 'controller.sv', 'dcr.sv', 'core_pmu.sv', 'fp32_fma.sv',
               'divider.sv', 'core.sv', 'gpu.sv']
UNIT_SRC = {'l2_cache': ['victim_write_buffer.sv', 'mahi_sram.sv', 'l2_data_array.sv', 'l2_cache.sv']}
UNIT_DEF = {'alu': ['USE_COMB_DIV']}
PROFILE_DEF = {'fpga': ['TARGET_FPGA'], 'sim': []}
BASE_DEF = ['SYNTHESIS', 'MAHI_SIM_CHECKS']


def vivado_bin(a, tool):
    root = a.vivado or os.environ.get('XILINX_VIVADO')
    if not root:
        vers = sorted(glob.glob('C:/Xilinx/Vivado/*/bin'))
        root = os.path.dirname(vers[-1]) if vers else None
    if root:
        return os.path.join(root, 'bin', tool + ('.bat' if os.name == 'nt' else ''))
    return tool                                                  # on PATH (Linux with settings64.sh sourced)


def opts_file(path, lines):
    with open(path, 'w') as f: f.write('\n'.join(lines) + '\n')
    return path


class BuildError(Exception): pass


def build(a, name, top, files, defines=()):
    """xvlog + xelab into sim/build/<name>/, snapshot <name>. Raises BuildError with the ERROR lines."""
    d = f'{BUILD}/{name}'
    shutil.rmtree(d, ignore_errors=True)
    if os.path.exists(d): raise BuildError(f'cannot clear {d} (an xsim process may still hold it)')
    os.makedirs(d)
    defs = BASE_DEF + PROFILE_DEF[a.profile] + list(defines) + a.define
    xv = opts_file(f'{d}/xvlog.f', ['--sv', '-i', f'{RTL}/include'] + [x for df in defs for x in ('-d', df)] + files)
    xe = opts_file(f'{d}/xelab.f', ['-debug', 'off', '--timescale', '1ns/1ns', '-s', name, f'work.{top}'])
    for tool, f in (('xvlog', xv), ('xelab', xe)):
        p = subprocess.run([vivado_bin(a, tool), '--file', f], cwd=d, capture_output=True, text=True)
        if p.returncode != 0:
            errs = [l for l in (p.stdout + p.stderr).splitlines() if l.startswith('ERROR')] or [p.stdout[-2000:]]
            raise BuildError(f'{tool} failed: ' + ' | '.join(errs[:3]))
    return d


def run_test(a, label, name, top, files, defs, needle):
    """Build, run, and judge one self-checking test: PASS needs the needle, no FAIL and no $error/$fatal."""
    t0 = time.time()
    try:
        d = build(a, name, top, files, defs)
    except BuildError as e:
        return label, False, str(e), time.time() - t0
    rc, log = simulate(a, d, name)
    open(f'{d}/run.log', 'w').write(log)
    errs = sim_errors(log)
    ok = rc == 0 and not errs and needle in log and 'FAIL' not in log
    last = next((l for l in reversed(log.splitlines()) if needle in l or 'FAIL' in l), '(no result line)')
    return label, ok, (errs[0] if errs else last.strip()), time.time() - t0


def simulate(a, d, name, plusargs=(), timeout=600, fdir=None):
    """Run snapshot <name> in build dir d (options file in fdir, default d); returns (returncode, output)."""
    args = ['--runall', '--onfinish', 'quit', '--nolog'] + [x for p in plusargs for x in ('--testplusarg', p)]
    f = opts_file(f'{fdir or d}/xsim.f', args)
    p = subprocess.Popen([vivado_bin(a, 'xsim'), name, '--file', f], cwd=d, stdout=subprocess.PIPE,
                         stderr=subprocess.STDOUT, text=True)
    try:
        out, _ = p.communicate(timeout=timeout)
    except subprocess.TimeoutExpired:
        # On Windows killing the .bat wrapper leaves xsimk running: kill the whole tree.
        if os.name == 'nt': subprocess.run(['taskkill', '/T', '/F', '/PID', str(p.pid)], capture_output=True)
        else: p.kill()
        p.communicate()
        raise
    return p.returncode, out


def sim_errors(log):
    """$error/$fatal reports from the RTL or testbench (xsim prints them as 'Error:' / 'Fatal:')."""
    return [l for l in log.splitlines() if l.lstrip().startswith(('Error:', 'Fatal:', 'ERROR:', 'FATAL'))]


# ------------------------------------------------------------------ unit and system tests
def unit(a):
    tests = sorted(os.path.basename(p)[3:-3] for p in glob.glob(f'{TB}/unit/tb_*.sv'))
    runs = [(t, t, UNIT_DEF.get(t, [])) for t in tests] + [('alu_stub', 'alu', [])]   # ALU without USE_COMB_DIV
    def one(r):
        name, t, defs = r
        src = [f'{RTL}/{s}' for s in ['include/gpu_pkg.sv'] + UNIT_SRC.get(t, [f'{t}.sv'])]
        return run_test(a, f'unit {name}', f'unit_{name}', f'tb_{t}', src + [f'{TB}/unit/tb_{t}.sv'], defs, 'ALL PASSED')
    with ThreadPoolExecutor(a.jobs) as ex: return list(ex.map(one, runs))


def system(a):
    rtl = [f'{RTL}/{s}' for s in RTL_SOURCES]
    runs = (('call_ret_branch', 'tb_asic_call_ret_branch', 'ISA/tb_asic_call_ret_branch.sv', [], 'THREADS PASSED'),
            ('matmul', 'tb_matmul', 'kernels/tb_matmul.sv', [], 'TESTS PASSED'),
            ('matmul_combdiv', 'tb_matmul', 'kernels/tb_matmul.sv', ['USE_COMB_DIV'], 'TESTS PASSED'))
    def one(r):
        name, top, tb, defs, needle = r
        return run_test(a, name, name, top, rtl + [f'{TB}/{tb}'], defs, needle)
    with ThreadPoolExecutor(a.jobs) as ex: return list(ex.map(one, runs))


# ------------------------------------------------------------------ random programs vs the golden model
def rand(a, seeds, lat):
    # 16 threads = one block (4 warps x 4 lanes); shared memory 8 words/thread; 32-word private regions so 16
    # threads fit below 1024 words. Must be set before the golden-model modules are imported.
    os.environ.update(MAHI_THREADS='16', MAHI_LANES='4', MAHI_SHARED='128', GEN_STRIDE='32')
    sys.path.insert(0, GOLDEN)
    from gen import Gen, make_input, write_hex, PRIV_BASE, PRIV_STRIDE, POOL
    from isa import Machine, Fault
    from profile_cfg import THREADS

    label = f'rand seeds {seeds[0]}-{seeds[1] - 1} lat<={lat}'
    try:
        d = build(a, 'rand', 'tb_random', [f'{RTL}/{s}' for s in RTL_SOURCES] + [f'{TB}/random/tb_random.sv'])
    except BuildError as e:
        return [(label, False, str(e), 0.0)]
    work, keep = f'{BUILD}/rand_work', f'{BUILD}/rand_fail'
    shutil.rmtree(work, ignore_errors=True); os.makedirs(work); os.makedirs(keep, exist_ok=True)
    # One snapshot copy per worker: xsim writes xsim.dir/<snapshot>/xsim_script.tcl on every run, so parallel runs
    # from one directory overwrite each other's command line.
    slots = queue.Queue()
    for k in range(a.jobs):
        shutil.copytree(f'{d}/xsim.dir', f'{work}/w{k}/xsim.dir'); slots.put(f'{work}/w{k}')

    def read_hex(p):
        with open(p) as f: return [int(l, 16) for l in f if l.strip()]

    def run_seed(seed):
        s = f'{work}/seed_{seed}'; os.makedirs(s)
        prog, inp = Gen(seed).build(), make_input(seed)
        write_hex(f'{s}/prog.hex', prog); write_hex(f'{s}/dmem.hex', inp)
        mem = {i: w for i, w in enumerate(inp)}
        try:
            Machine(prog, mem).run()
        except Fault as e:
            return seed, 'GENFAULT', str(e)
        expect = [mem.get(i, 0) for i in range(1024)]
        write_hex(f'{s}/expect.hex', expect)
        w = slots.get()
        try:
            rc, log = simulate(a, w, 'rand', [f'prog={s}/prog.hex', f'dmem={s}/dmem.hex', f'out={s}/out.hex',
                                              f'lat={lat}', f'seed={seed}', f'threads={THREADS}',
                                              f'maxcyc={a.maxcyc}'], a.timeout, s)
        except subprocess.TimeoutExpired:
            return seed, 'TIMEOUT', 'xsim wall-clock timeout'
        finally:
            slots.put(w)
        open(f'{s}/run.log', 'w').write('\n'.join(log.splitlines()[-400:]))
        errs = sim_errors(log)
        if 'TB_TIMEOUT' in log: return seed, 'HANG', 'DUT never asserted done'
        if errs: return seed, 'CHECK', errs[0].strip()
        flt = [l for l in log.splitlines() if 'TB_FAULT' in l]
        if flt: return seed, 'FAULT', flt[0].strip()
        if rc != 0 or not os.path.exists(f'{s}/out.hex'): return seed, 'CRASH', f'rc={rc}'
        got = read_hex(f'{s}/out.hex')
        diffs = [i for i in range(1024) if got[i] != expect[i]]
        if diffs:
            i, where = diffs[0], ''
            if i >= PRIV_BASE:
                t, off = divmod(i - PRIV_BASE, PRIV_STRIDE)
                where = f' (thread {t}, private[{off}]' + (f' = R{off})' if off < len(POOL) else ')')
            return seed, 'MISMATCH', f'{len(diffs)} words differ; first @{i}{where}: got {got[i]:08x} exp {expect[i]:08x}'
        cyc = next((l.split('cycles=')[1].split()[0] for l in log.splitlines() if 'TB_DONE' in l), '?')
        shutil.rmtree(s)
        return seed, 'PASS', cyc

    t0 = time.time()
    with ThreadPoolExecutor(a.jobs) as ex: res = list(ex.map(run_seed, range(*seeds)))
    bad = [r for r in res if r[1] != 'PASS']
    for seed, kind, msg in bad:
        print(f'  seed {seed}: {kind} {msg}')
        dst = f'{keep}/lat{lat}_seed_{seed}'; shutil.rmtree(dst, ignore_errors=True)
        shutil.copytree(f'{work}/seed_{seed}', dst)
    kinds = {}
    for _, k, _ in res: kinds[k] = kinds.get(k, 0) + 1
    cycles = [int(m) for _, k, m in res if k == 'PASS' and m.isdigit()]
    detail = ', '.join(f'{k}={v}' for k, v in sorted(kinds.items()))
    if cycles: detail += f'; cycles min/avg/max {min(cycles)}/{sum(cycles) // len(cycles)}/{max(cycles)}'
    return [(label, not bad, detail, time.time() - t0)]


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('what', choices=['unit', 'system', 'rand', 'all'])
    ap.add_argument('--profile', choices=sorted(PROFILE_DEF), default='fpga')
    ap.add_argument('--vivado'); ap.add_argument('--seeds', type=int, nargs=2, default=[0, 50])
    ap.add_argument('--lat', type=int, default=0); ap.add_argument('--jobs', type=int, default=min(8, os.cpu_count() or 4))
    ap.add_argument('--timeout', type=int, default=600, help='wall-clock seconds per random seed')
    # tb_random's own default (400k) is too short for 16 threads: seed 311 legitimately needs 546k cycles
    # (warp 3 runs 10x the loop trips of warp 0 while warp 0 waits at a barrier).
    ap.add_argument('--maxcyc', type=int, default=2_000_000, help='hang watchdog per random seed, in cycles')
    ap.add_argument('--define', action='append', default=[], metavar='NAME[=VAL]',
                    help='extra Verilog define for every build (repeatable), e.g. MEM_TRACE')
    a = ap.parse_args()

    print(f'xsim flow: profile={a.profile}, vivado={os.path.dirname(os.path.dirname(vivado_bin(a, "xsim")))}')
    res = []
    if a.what in ('unit', 'all'): res += unit(a)
    if a.what in ('system', 'all'): res += system(a)
    if a.what == 'rand': res += rand(a, a.seeds, a.lat)
    if a.what == 'all': res += rand(a, (0, 40), 0) + rand(a, (0, 40), 6)
    for name, ok, msg, secs in res:
        print(f'{"PASS" if ok else "FAIL"}  {name:<32} {secs:7.1f}s  {msg}')
    nbad = sum(not ok for _, ok, _, _ in res)
    print(f'== {len(res) - nbad}/{len(res)} passed ==')
    sys.exit(1 if nbad else 0)


if __name__ == '__main__': main()
