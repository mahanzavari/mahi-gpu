#!/usr/bin/env python3
"""Chip-level regression: random program pairs through gpu_asic_top's Wishbone port.

  top_regress.py --bin build/top/top_tb --seeds 0 40 [--gap 0]

For each seed s the testbench loads program s into the PMEM window and its input into DMEM,
runs it, reads the 512-word DMEM window back, then soft-resets and does the same with
program s+500 (so stale I-/D-/L2-cache contents from run 1 would show up as a mismatch in run 2).
Both results are compared against the golden model (isa.py). Generator layout: GEN_STRIDE=32,
so 8 threads fit the 512-word on-chip data memory.
"""
import argparse, os, shutil, subprocess, sys
from concurrent.futures import ThreadPoolExecutor
os.environ['GEN_STRIDE'] = '32'
sys.path.insert(0, os.path.dirname(__file__))
from gen import Gen, make_input, write_hex
from isa import Machine, Fault
from rand_regress import bounded_run, read_hex

def prep(d, tag, seed):
    prog = Gen(seed).build(); inp = make_input(seed)
    assert len(prog) <= 512, f'program {seed} has {len(prog)} words (> 512 PMEM words)'
    write_hex(f'{d}/p{tag}.hex', prog); write_hex(f'{d}/d{tag}.hex', inp)
    mem = {i: w for i, w in enumerate(inp)}
    Machine(prog, mem).run()
    return [mem.get(i, 0) for i in range(512)]

def run_seed(a, seed):
    d = os.path.join(a.work, f'seed_{seed}'); os.makedirs(d, exist_ok=True)
    try:
        e1 = prep(d, '1', seed); e2 = prep(d, '2', seed + 500)
    except Fault as e:
        return seed, 'GENFAULT', str(e)
    cmd = [a.bin, '+verilator+quiet', f'+prog={d}/p1.hex', f'+dmem={d}/d1.hex', f'+out={d}/o1.hex',
           f'+prog2={d}/p2.hex', f'+dmem2={d}/d2.hex', f'+out2={d}/o2.hex', f'+gap={a.gap}', '+maxcyc=60000']
    try:
        rc, log = bounded_run(cmd, a.timeout)
    except subprocess.TimeoutExpired:
        return seed, 'TIMEOUT', 'wall-clock'
    open(f'{d}/run.log', 'w').write(log)
    if 'TB_TIMEOUT' in log: return seed, 'HANG', 'done never set'
    if 'TOP_TB_PASS' not in log:
        return seed, 'TBFAIL', next((l for l in log.splitlines() if 'TB_' in l and 'RUN_DONE' not in l), f'rc={rc}')
    for tag, exp in (('1', e1), ('2', e2)):
        got = read_hex(f'{d}/o{tag}.hex')
        diffs = [i for i in range(512) if got[i] != exp[i]]
        if diffs:
            i = diffs[0]
            return seed, 'MISMATCH', f'run{tag}: {len(diffs)} words differ; first @{i}: got {got[i]:08x} exp {exp[i]:08x}'
    shutil.rmtree(d)
    return seed, 'PASS', ''

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--bin', required=True); ap.add_argument('--seeds', type=int, nargs=2, default=[0, 20])
    ap.add_argument('--gap', type=int, default=0); ap.add_argument('--jobs', type=int, default=os.cpu_count() or 4)
    ap.add_argument('--work', default='build/top/work'); ap.add_argument('--timeout', type=int, default=300)
    a = ap.parse_args()
    shutil.rmtree(a.work, ignore_errors=True); os.makedirs(a.work)
    with ThreadPoolExecutor(a.jobs) as ex: res = list(ex.map(lambda s: run_seed(a, s), range(*a.seeds)))
    for seed, kind, msg in res:
        if kind != 'PASS': print(f'seed {seed}: {kind} {msg}')
    kinds = {}
    for _, k, _ in res: kinds[k] = kinds.get(k, 0) + 1
    print(f'{len(res)} seeds (wb gap {a.gap}): ' + ', '.join(f'{k}={v}' for k, v in sorted(kinds.items())))
    sys.exit(0 if all(k == 'PASS' for _, k, _ in res) else 1)

if __name__ == '__main__': main()
