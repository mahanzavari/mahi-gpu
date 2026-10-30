#!/usr/bin/env python3
"""Constrained-random regression: generate -> reference model -> DUT -> diff.

  rand_regress.py --bin build/rand/rand_tb --seeds 0 200 [--lat 6] [--jobs 8]

For each seed: build a program (gen.py), compute expected memory with the golden
interpreter (isa.py), run the Verilator testbench with randomized memory latency,
and compare the full data memory. Failing seeds keep their artifacts under
--keep/seed_<n>/ (program, input, expected, actual) so they can be replayed.
"""
import argparse, os, subprocess, sys, shutil
from concurrent.futures import ThreadPoolExecutor
sys.path.insert(0, os.path.dirname(__file__))
from gen import Gen, make_input, write_hex, PRIV_BASE, PRIV_STRIDE, POOL
from isa import Machine, Fault
from profile_cfg import THREADS

def read_hex(path):
    with open(path) as f: return [int(l, 16) for l in f if l.strip()]

def bounded_run(cmd, timeout, keep=200_000):
    """Run cmd, keeping only the first and last `keep` bytes of output (failing DUTs can print GBs)."""
    import time, collections
    p = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    head, tail, n, t0 = b'', collections.deque(), 0, time.time()
    tlen = 0
    while True:
        chunk = p.stdout.read(65536)
        if not chunk: break
        if len(head) < keep: head += chunk[:keep - len(head)]
        tail.append(chunk); tlen += len(chunk)
        while tlen - len(tail[0]) > keep: tlen -= len(tail.popleft())
        if time.time() - t0 > timeout:
            p.kill(); raise subprocess.TimeoutExpired(cmd, timeout)
    p.wait()
    txt = head.decode(errors='replace') + '\n...[truncated]...\n' + b''.join(tail).decode(errors='replace')
    return p.returncode, txt

def run_seed(a, seed):
    d = os.path.join(a.work, f'seed_{seed}'); os.makedirs(d, exist_ok=True)
    prog = Gen(seed).build(); inp = make_input(seed)
    write_hex(f'{d}/prog.hex', prog); write_hex(f'{d}/dmem.hex', inp)
    mem = {i: w for i, w in enumerate(inp)}
    try:
        Machine(prog, mem).run()
    except Fault as e:
        return seed, 'GENFAULT', str(e)           # generator/model bug, not a DUT failure
    expect = [mem.get(i, 0) for i in range(1024)]
    cmd = [a.bin, f'+prog={d}/prog.hex', f'+dmem={d}/dmem.hex', f'+out={d}/out.hex',
           f'+lat={a.lat}', f'+seed={seed}', f'+threads={THREADS}', '+verilator+quiet']
    try:
        rc, log = bounded_run(cmd, a.timeout)
    except subprocess.TimeoutExpired:
        return seed, 'TIMEOUT', 'simulator wall-clock timeout'
    open(f'{d}/run.log', 'w').write(log)
    sva = [l for l in log.splitlines() if 'SVA' in l or '%Error' in l]
    if 'TB_TIMEOUT' in log: return seed, 'HANG', 'DUT never asserted done'
    if sva: return seed, 'SVA', sva[0]
    flt = [l for l in log.splitlines() if 'TB_FAULT' in l]
    if flt: return seed, 'FAULT', flt[0].strip()          # generated programs never fault
    if rc != 0 or not os.path.exists(f'{d}/out.hex'): return seed, 'CRASH', f'rc={rc}'
    got = read_hex(f'{d}/out.hex')
    diffs = [i for i in range(1024) if got[i] != expect[i]]
    write_hex(f'{d}/expect.hex', expect)
    if diffs:
        i = diffs[0]
        where = ''
        if i >= PRIV_BASE:
            t, off = divmod(i - PRIV_BASE, PRIV_STRIDE); where = f' (thread {t}, private[{off}]' + (f' = R{off})' if off < len(POOL) else ')')
        return seed, 'MISMATCH', f'{len(diffs)} words differ; first @{i}{where}: got {got[i]:08x} exp {expect[i]:08x}'
    for f in ('run.log', 'out.hex', 'expect.hex'): os.remove(f'{d}/{f}')
    return seed, 'PASS', ''

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--bin', required=True); ap.add_argument('--seeds', type=int, nargs=2, default=[0, 50])
    ap.add_argument('--lat', type=int, default=0); ap.add_argument('--jobs', type=int, default=os.cpu_count() or 4)
    ap.add_argument('--work', default='build/rand/work'); ap.add_argument('--keep', default='build/rand/fail')
    ap.add_argument('--timeout', type=int, default=120)
    a = ap.parse_args()
    shutil.rmtree(a.work, ignore_errors=True); os.makedirs(a.work); os.makedirs(a.keep, exist_ok=True)
    seeds = range(a.seeds[0], a.seeds[1])
    with ThreadPoolExecutor(a.jobs) as ex: res = list(ex.map(lambda s: run_seed(a, s), seeds))
    bad = [r for r in res if r[1] != 'PASS']
    for seed, kind, msg in bad:
        print(f'seed {seed}: {kind} {msg}')
        dst = f'{a.keep}/seed_{seed}'; shutil.rmtree(dst, ignore_errors=True); shutil.copytree(f'{a.work}/seed_{seed}', dst)
    kinds = {}
    for _, k, _ in res: kinds[k] = kinds.get(k, 0) + 1
    print(f'{len(res)} seeds (lat<= {a.lat}): ' + ', '.join(f'{k}={v}' for k, v in sorted(kinds.items())))
    sys.exit(1 if bad else 0)

if __name__ == '__main__': main()
