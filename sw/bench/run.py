#!/usr/bin/env python3
"""mahi-gpu benchmark runner.

  python sw/bench/run.py                                  # every case, RTL (Verilator) at lat 0 and 20
  python sw/bench/run.py --suite micro --lat 0            # micro-benchmarks only
  python sw/bench/run.py --cases gemm_naive,gemm_smem     # selected cases
  python sw/bench/run.py --list

Each case runs on the golden model (architectural counts, reference outputs) and on the RTL perf build (Verilator +
sw/bench/rtl/perf_probes.sv) at every `--lat` (testbench memory latency: uniform 0..lat extra cycles per external
line transfer). Outputs must be bit-identical to the golden model. Results go to --out: results.json, report.md and
report.html (see report.py).
"""
import argparse, datetime, json, os, sys, time, traceback
from concurrent.futures import ThreadPoolExecutor

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE); sys.path.insert(0, os.path.join(HERE, '..'))
import numpy as np  # noqa: E402
from mahi import Device  # noqa: E402
from cases import CASES  # noqa: E402
from metrics import derive, latency_sensitivity, fmt  # noqa: E402
from rules import flags  # noqa: E402
import report  # noqa: E402


def run_case(c, a):
    rec = dict(name=c.name, group=c.group, desc=c.desc, threads=c.threads, elements=c.elements, runs={})
    g = Device('golden', a.profile, heap_base=64, mem_words=c.mem_words, count=True)
    why = c.supported(g.profile)
    if why: rec['skipped'] = why; return rec
    t0 = time.time()
    try:
        gr, gout = c.run(g)
    except Exception as e:
        rec['error'] = f'golden: {e!r}'; return rec
    rec['counts'] = gr.counts
    for lat in a.lat:
        d = Device('verilator', a.profile, heap_base=64, mem_words=c.mem_words, perf=True, lat=lat)
        try:
            r, out, failed = c.run(d, soft=True)
        except Exception as e:
            rec['runs'][lat] = dict(error=repr(e)); continue
        same = np.array_equal(out, gout)
        m = derive(c, gr.counts, r.perf, r.cycles, g.profile, a.clock)
        m['bit_identical'] = same; m['check_failed'] = failed
        fl = flags(m)
        if failed or not same:
            fl.insert(0, dict(id='wrong_result', severity='high',
                              msg='; '.join(failed) or 'output differs from the golden model (bit level)',
                              hint='functional bug: the RTL result is wrong'))
        rec['runs'][lat] = dict(cycles=r.cycles, metrics=m, perf=r.perf, flags=fl)
    lats = [l for l in a.lat if 'metrics' in rec['runs'].get(l, {})]
    if len(lats) > 1 and lats[0] == 0:
        m0 = rec['runs'][0]['metrics']
        for l in lats[1:]:
            rec['runs'][l]['metrics']['lat_exposed'] = latency_sensitivity(m0, rec['runs'][l]['metrics'], l)
    rec['wall_s'] = time.time() - t0
    return rec


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--suite', default='micro,app'); ap.add_argument('--cases', default=None)
    ap.add_argument('--lat', default='0,20', help='testbench memory latencies (comma list)')
    ap.add_argument('--profile', default='fpga'); ap.add_argument('--clock', type=float, default=25.0, help='MHz')
    ap.add_argument('--jobs', type=int, default=4); ap.add_argument('--out', default=None)
    ap.add_argument('--list', action='store_true')
    a = ap.parse_args()
    a.lat = [int(x) for x in a.lat.split(',')]
    sel = [c for c in CASES if c.group in a.suite.split(',')]
    if a.cases: sel = [c for c in CASES if c.name in a.cases.split(',')]
    if a.list:
        for c in CASES: print(f'{c.group:6s} {c.name:18s} {c.desc}')
        return
    out = a.out or os.path.join(HERE, 'results', datetime.datetime.now().strftime('%Y%m%d_%H%M%S') + f'_{a.profile}')
    os.makedirs(out, exist_ok=True)
    Device('verilator', a.profile, perf=True)                     # build the perf simulator once, up front
    print(f'{len(sel)} cases, profile {a.profile}, lat {a.lat}, {a.jobs} jobs -> {out}')
    t0 = time.time(); results = []
    with ThreadPoolExecutor(a.jobs) as ex:
        for rec in ex.map(lambda c: run_case(c, a), sel):
            results.append(rec)
            r0 = rec['runs'].get(a.lat[0], {})
            if 'skipped' in rec: line = f'skipped: {rec["skipped"]}'
            elif 'error' in rec: line = 'ERROR ' + rec['error']
            elif 'error' in r0: line = 'ERROR ' + r0['error']
            else:
                m = r0['metrics']
                line = (f'{m["cycles"]:9,} cyc  IPC {fmt(m["ipc"])}  issue {fmt(m["b_issue"], "%"):>4}  '
                        f'mem {fmt(m["b_mem"], "%"):>4}  {m["bound"]:32s} '
                        f'{"bit-identical" if m["bit_identical"] else "MISMATCH"}  flags: '
                        f'{",".join(f["id"] for f in r0["flags"]) or "-"}')
            print(f'  {rec["name"]:18s} {line}', flush=True)
    meta = dict(profile=a.profile, lat=a.lat, clock_mhz=a.clock, date=datetime.datetime.now().isoformat(timespec='seconds'),
                wall_s=round(time.time() - t0, 1))
    with open(os.path.join(out, 'results.json'), 'w') as f:
        json.dump(dict(meta=meta, cases=results), f, indent=1, default=float)
    report.write(out, meta, results)
    print(f'done in {meta["wall_s"]} s: {out}/report.md, report.html')


if __name__ == '__main__':
    try:
        main()
    except KeyboardInterrupt:
        sys.exit(130)
