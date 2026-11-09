"""Benchmark report: report.md (tables) and report.html (the same plus SVG charts: issue-slot breakdown, roofline).

  python sw/bench/report.py sw/bench/results/<run>       # re-render from results.json
"""
import html, json, math, os, sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from metrics import BUCKETS, BUCKET_LABEL, fmt  # noqa: E402
from rules import RULES  # noqa: E402

COLORS = {'issue': '#2e9e5b', 'mem': '#d1495b', 'serial': '#edae49', 'll_dep': '#8d6cab', 'll': '#b497d6',
          'raw': '#66a0d6', 'ifetch': '#00798c', 'barrier': '#e07a5f', 'drain': '#9a9a9a'}
SEV_ORDER = {'high': 0, 'med': 1, 'info': 2}


def _m(rec, lat):
    return rec['runs'].get(lat, {}).get('metrics')


def ceilings(results, lat):
    """machine ceilings measured by the micro-benchmarks (None when the case was not run)"""
    by = {r['name']: _m(r, lat) for r in results if _m(r, lat)}

    def best(names, key):
        v = [by[n][key] for n in names if n in by]
        return max(v) if v else None

    c = dict(
        flop=best([f'fma_chain{k}' for k in (1, 2, 4, 8)], 'flop_per_cycle'),
        int_ops=best(['add_chain1', 'add_chain4'], 'thread_ops_per_cycle'),
        bw_l1=best(['stream_read_l1'], 'bw_data'), bw_l2=best(['stream_read_l2', 'stride_s1'], 'bw_data'),
        bw_dram=best(['stream_read_dram'], 'bw_data'), bw_copy=best(['stream_copy'], 'bw_data'),
        bw_triad=best(['stream_triad'], 'bw_data'), bw_store=best(['stream_memset'], 'bw_data'))
    for lvl in ('l1', 'l2', 'dram'):
        n = f'chase_{lvl}'
        c[f'hop_{lvl}'] = by[n]['cycles_per_elem'] if n in by else None
    c['barrier'] = by['barrier']['cycles_per_elem'] if 'barrier' in by else None
    c['atomic'] = by['atomic_b64']['atomic_cycles'] if 'atomic_b64' in by else None
    if 'smem_s1' in by and 'smem_s4' in by: c['smem_conflict_x'] = by['smem_s4']['cycles'] / by['smem_s1']['cycles']
    if 'diverge_m0' in by and 'diverge_m3' in by: c['diverge_x'] = by['diverge_m3']['cycles'] / by['diverge_m0']['cycles']
    return c


def ceiling_rows(c):
    return [('peak FP32 throughput', c['flop'], 'FLOP/cycle'), ('peak integer throughput', c['int_ops'], 'thread-ops/cycle'),
            ('read bandwidth, L1-resident', c['bw_l1'], 'B/cycle'), ('read bandwidth, L2-resident', c['bw_l2'], 'B/cycle'),
            ('read bandwidth, from DRAM', c['bw_dram'], 'B/cycle'), ('copy bandwidth (read + write)', c['bw_copy'], 'B/cycle'),
            ('triad bandwidth', c['bw_triad'], 'B/cycle'), ('store-only bandwidth', c['bw_store'], 'B/cycle'),
            ('dependent load, L1 hit', c['hop_l1'], 'cycles/hop'), ('dependent load, L2 hit', c['hop_l2'], 'cycles/hop'),
            ('dependent load, DRAM', c['hop_dram'], 'cycles/hop'), ('barrier (ADD + SYNC round)', c['barrier'], 'cycles'),
            ('atomic, no contention', c['atomic'], 'LSU cycles/lane'),
            ('4-way bank conflict slowdown', c.get('smem_conflict_x'), '×'), ('1/4-lanes divergence slowdown', c.get('diverge_x'), '×')]


def findings(results, lat):
    """conclusions that need two cases (a micro-benchmark and its control); [(title, text)]"""
    by = {r['name']: _m(r, lat) for r in results if _m(r, lat)}
    rec = {r['name']: r for r in results}
    F = []

    def has(*n): return all(x in by for x in n)
    if has('fma_chain1', 'fma_chain8'):
        a, b = by['fma_chain1'], by['fma_chain8']
        F.append(('FP instruction-level parallelism', f'with 8 independent FMA chains a warp still gets an FP instruction '
                  f'out only every {b["fp_interval"]:.1f} warp-cycles (1 chain: {a["fp_interval"]:.1f}; the issue-slot limit '
                  f'with {rec["fma_chain8"]["threads"] // 8} warps sharing a core is 4). '
                  + ('Independent FMAs of one warp do not overlap: the scheduler parks the warp in WAITING_FP after every '
                     'FP instruction until its writeback, so the FMA round trip, not the data dependence, sets the rate; '
                     f'only more warps fill it. Peak reached: {b["flop_per_cycle"]:.2f} of {b["peak_flop"]} FLOP/cycle.'
                     if b['fp_interval'] > 6 else 'Independent FMAs overlap within a warp.')))
    if has('div_chain1'):
        d = by['div_chain1']
        F.append(('Divider', f'one DIV keeps the per-core divider busy {d["div_cycles"]:.0f} cycles and the warp waits for it; '
                  f'DIV-bound code issues {100 * d["b_issue"]:.0f}% of cycles.'))
    if has('atomic_b1', 'atomic_b1_1core'):
        two, one = rec['atomic_b1']['runs'][lat]['metrics'], rec['atomic_b1_1core']['runs'][lat]['metrics']
        if two['check_failed'] and not one['check_failed']:
            F.append(('Atomics are not coherent across cores', 'ATOM_ADD on one word is correct inside one core but loses '
                      f'updates when both cores use it ({two["check_failed"][0]}). Each core\'s write-through L1 keeps its own '
                      'copy of the line; the LSU\'s atomic read can hit that stale copy, nothing invalidates it when the other '
                      'core writes. Also seen in: ' + ', '.join(n for n, r in rec.items() if n not in ('atomic_b1',)
                      and _m(r, lat) and _m(r, lat).get('check_failed')) + '.'))
    if has('stride_s1', 'stride_s4'):
        a, b = by['stride_s1'], by['stride_s4']
        F.append(('Coalescing', f'lanes 4 words apart cost {b["cycles"] / a["cycles"]:.2f}x the cycles of consecutive lanes '
                  f'({b["tx_per_ld"]:.2f} vs {a["tx_per_ld"]:.2f} line transactions per warp load, '
                  f'{b["ld_line_latency"]:.1f} LSU cycles per line).'))
    if has('chase_l1', 'chase_l2', 'chase_dram'):
        c = [by[f'chase_{x}']['ld_line_latency'] for x in ('l1', 'l2', 'dram')]
        h = [by[f'chase_{x}']['cycles_per_elem'] for x in ('l1', 'l2', 'dram')]
        F.append(('Load latency', f'LSU cycles per load line: {c[0]:.1f} on an L1 hit, {c[1]:.1f} from L2, {c[2]:.1f} '
                  f'from testbench DRAM at this latency setting; a dependent-load loop of 6 instructions takes '
                  f'{h[0]:.1f} / {h[1]:.1f} / {h[2]:.1f} cycles per hop. Even an L1 hit costs several cycles in the '
                  f'LSU state machine (request, D$ answer, writeback), and the warp waits throughout.'))
    if has('stream_read_l1', 'stream_read_l2', 'stream_read_dram'):
        b = [by[f'stream_read_{x}']['bw_data'] for x in ('l1', 'l2', 'dram')]
        lb = [by[f'stream_read_{x}']['lsu_busy'] for x in ('l1', 'l2', 'dram')]
        F.append(('Read bandwidth by level', f'{b[0]:.2f} / {b[1]:.2f} / {b[2]:.2f} B/cycle for L1 / L2 / DRAM-resident '
                  f'data (LSU busy {100 * lb[0]:.0f}% / {100 * lb[1]:.0f}% / {100 * lb[2]:.0f}%). L1-resident streaming is '
                  f'limited by loop instructions (8 per element, no immediates); beyond L1 the per-core LSU (one line '
                  f'at a time, blocking) is the limit, far below what a 16-byte line port could deliver.'))
    if has('stream_copy', 'stream_read_l2', 'stream_memset'):
        F.append(('Stores', f'store-only bandwidth {by["stream_memset"]["bw_data"]:.2f} B/cycle '
                  f'({by["stream_memset"]["st_line_latency"]:.1f} LSU cycles per stored line) vs '
                  f'{by["stream_read_l2"]["bw_data"]:.2f} for reads.'))
    if len(rec) and 'stream_read_dram' in by:
        lats = sorted(k for k in rec['stream_read_dram']['runs'] if 'metrics' in rec['stream_read_dram']['runs'][k])
        if len(lats) > 1:
            e = rec['stream_read_dram']['runs'][lats[-1]]['metrics'].get('lat_exposed')
            F.append(('External-memory latency is not overlapped', f'raising the testbench memory latency to '
                      f'0..{lats[-1]} cycles makes stream_read_dram {rec["stream_read_dram"]["runs"][lats[-1]]["cycles"] / by["stream_read_dram"]["cycles"]:.2f}x '
                      f'slower; {100 * e:.0f}% of the added latency is exposed. The L2 serves one request at a time and '
                      f'waits for each miss (no MSHRs), so with only 2 cores x 1 outstanding line nothing overlaps.'))
    if has('smem_s1', 'smem_s4'):
        F.append(('Shared-memory banks', f'4-way bank conflicts cost {by["smem_s4"]["cycles"] / by["smem_s1"]["cycles"]:.2f}x '
                  f'(conflict in {100 * by["smem_s4"]["smem_conflict"]:.0f}% of shared-memory cycles).'))
    if has('diverge_m0', 'diverge_m3'):
        a, b = by['diverge_m0'], by['diverge_m3']
        F.append(('Divergence', f'with 1 of 4 lanes working, the kernel still takes {b["cycles"] / a["cycles"]:.2f}x the '
                  f'cycles of all lanes working (SIMD efficiency {100 * b["simd_eff"]:.0f}%): the idle lanes save nothing.'))
    if has('gemm_naive', 'gemm_smem'):
        a, b = by['gemm_naive'], by['gemm_smem']
        F.append(('Shared-memory tiling (GEMM)', f'tiled GEMM {b["cycles"]:,} vs naive {a["cycles"]:,} cycles '
                  f'({a["cycles"] / b["cycles"]:.2f}x): it removes {100 * (1 - b["lsu_req_rd"] / a["lsu_req_rd"]):.0f}% of '
                  f'the global loads but executes {b["thread_instr"] / a["thread_instr"]:.2f}x the instructions '
                  f'(address arithmetic without immediates or an addressing mode).'))
    if has('transpose_naive', 'transpose_smem'):
        a, b = by['transpose_naive'], by['transpose_smem']
        F.append(('Transpose', f'shared-memory transpose {b["cycles"]:,} vs naive {a["cycles"]:,} cycles; store '
                  f'transactions per warp store {b["tx_per_st"]:.2f} vs {a["tx_per_st"]:.2f}.'))
    return F


def oversights(results, lat):
    """flags grouped by rule id: [(id, severity, hint, [(case, msg)])], most severe and most frequent first"""
    g = {}
    for r in results:
        run = r['runs'].get(lat, {})
        for f in run.get('flags', []):
            e = g.setdefault(f['id'], dict(severity=f['severity'], hint=f['hint'], cases=[]))
            e['cases'].append((r['name'], f['msg']))
    return sorted(g.items(), key=lambda kv: (kv[0] != 'wrong_result', SEV_ORDER[kv[1]['severity']], -len(kv[1]['cases'])))


COLS = [('cycles', 'cycles', 'i'), ('time_us', 'µs', 'f'), ('ipc', 'IPC', 'f'), ('simd_eff', 'SIMD', '%'),
        ('flop_per_cycle', 'FLOP/c', 'f'), ('bw_data', 'data B/c', 'f'), ('bw_dram', 'DRAM B/c', 'f'),
        ('l1_read_hit', 'L1 hit', '%'), ('l2_hit', 'L2 hit', '%'), ('tx_per_ld', 'tx/ld', 'f'),
        ('lsu_busy', 'LSU busy', '%'), ('ready_warps', 'ready', 'f')]


def _cell(m, k, kind):
    v = m.get(k)
    return fmt(int(v), 'i') if kind == 'i' and v is not None else fmt(v, kind)


def write_md(out, meta, results):
    lat0 = meta['lat'][0]
    c = ceilings(results, lat0)
    L = [f'# mahi-gpu benchmark report — profile `{meta["profile"]}`', '',
         f'{meta["date"]}, testbench memory latency {meta["lat"]} (uniform 0..lat extra cycles per external line), '
         f'clock {meta["clock_mhz"]} MHz for µs. Tables use lat = {lat0}.', '', '## Measured ceilings', '',
         '| ceiling | value |', '|---|---|']
    rows = ceiling_rows(c)
    L += [f'| {n} | {fmt(v)} {u if v is not None else ""} |' for n, v, u in rows]
    L += ['', '## Findings', '']
    L += [f'- **{t}**: {x}' for t, x in findings(results, lat0)]
    L += ['', '## Oversights', '', 'Rules over every case (sw/bench/rules.py), grouped; most severe and most frequent first.', '']
    for rid, e in oversights(results, lat0):
        L.append(f'- **{rid}** ({e["severity"]}, {len(e["cases"])} case{"s" * (len(e["cases"]) != 1)}): {e["hint"]}')
        for name, msg in e['cases'][:6]: L.append(f'  - `{name}`: {msg}')
        if len(e['cases']) > 6: L.append(f'  - … and {len(e["cases"]) - 6} more')
    L += ['', '## Per case', '', '| case | ' + ' | '.join(h for _, h, _ in COLS) + ' | bound |',
          '|---|' + '---:|' * len(COLS) + '---|']
    for r in results:
        m = _m(r, lat0)
        if not m: L.append(f'| `{r["name"]}` | ' + (r.get('skipped') or r.get('error') or 'error') + ' |'); continue
        ok = '' if m['bit_identical'] else ' ⚠'
        L.append(f'| `{r["name"]}`{ok} | ' + ' | '.join(_cell(m, k, kd) for k, _, kd in COLS) + f' | {m["bound"]} |')
    L += ['', '## Issue-slot breakdown (share of core-cycles)', '',
          '| case | ' + ' | '.join(BUCKETS) + ' |', '|---|' + '---:|' * len(BUCKETS)]
    for r in results:
        m = _m(r, lat0)
        if m: L.append(f'| `{r["name"]}` | ' + ' | '.join(fmt(m['b_' + b], '%') for b in BUCKETS) + ' |')
    L += [''] + [f'- **{b}**: {BUCKET_LABEL[b]}' for b in BUCKETS]
    if len(meta['lat']) > 1:
        L += ['', '## Memory-latency sensitivity', '',
              'Exposed share = added cycles / added latency summed over external line transfers (1 = nothing overlaps).', '',
              '| case | ' + ' | '.join(f'cycles @lat {l}' for l in meta['lat']) + ' | ' +
              ' | '.join(f'exposed @{l}' for l in meta['lat'][1:]) + ' |',
              '|---|' + '---:|' * (2 * len(meta['lat']) - 1)]
        for r in results:
            ms = [_m(r, l) for l in meta['lat']]
            if not all(ms): continue
            L.append(f'| `{r["name"]}` | ' + ' | '.join(f'{x["cycles"]:,}' for x in ms) + ' | ' +
                     ' | '.join(fmt(x.get('lat_exposed')) for x in ms[1:]) + ' |')
    L += ['', '## Cases', ''] + [f'- `{r["name"]}` ({r["group"]}): {r["desc"]}' for r in results]
    with open(os.path.join(out, 'report.md'), 'w') as f: f.write('\n'.join(L) + '\n')


# ---------------------------------------------------------------------------------------------------------- SVG
def svg_breakdown(results, lat):
    rows = [(r['name'], _m(r, lat)) for r in results if _m(r, lat)]
    W, lw, bh, gap, top = 760, 150, 16, 5, 30
    H = top + len(rows) * (bh + gap) + 40
    s = [f'<svg viewBox="0 0 {W} {H}" role="img" aria-label="issue-slot breakdown" class="chart">']
    x0, x1 = lw, W - 10
    for i, frac in enumerate((0, .25, .5, .75, 1)):
        x = x0 + frac * (x1 - x0)
        s.append(f'<line x1="{x:.1f}" y1="{top - 6}" x2="{x:.1f}" y2="{H - 34}" class="grid"/>'
                 f'<text x="{x:.1f}" y="{top - 10}" class="tick" text-anchor="middle">{int(frac * 100)}%</text>')
    for i, (name, m) in enumerate(rows):
        y = top + i * (bh + gap); x = x0
        s.append(f'<text x="{lw - 6}" y="{y + bh - 4}" class="lbl" text-anchor="end">{html.escape(name)}</text>')
        for b in BUCKETS:
            w = (m['b_' + b] or 0) * (x1 - x0)
            if w <= 0: continue
            s.append(f'<rect x="{x:.1f}" y="{y}" width="{w:.1f}" height="{bh}" fill="{COLORS[b]}">'
                     f'<title>{name}: {BUCKET_LABEL[b]} {100 * m["b_" + b]:.1f}%</title></rect>')
            x += w
    lx, ly = x0, H - 18
    for b in BUCKETS:
        s.append(f'<rect x="{lx}" y="{ly - 9}" width="10" height="10" fill="{COLORS[b]}"/>'
                 f'<text x="{lx + 13}" y="{ly}" class="tick">{b}</text>')
        lx += 13 + 7 * len(b) + 14
    s.append('</svg>')
    return '\n'.join(s)


def svg_roofline(results, lat, c):
    pts = [(r['name'], _m(r, lat)) for r in results if _m(r, lat) and _m(r, lat)['flops']]
    if not pts: return ''
    W, ml, mb, mt, mr = 760, 60, 46, 16, 16
    keyrows = (len(pts) + 2) // 3
    H0 = 420; H = H0 + 18 * keyrows + 10
    xs = [m['ai_data'] for _, m in pts]; ys = [m['flop_per_cycle'] for _, m in pts]
    peak = pts[0][1]['peak_flop']
    xmin, xmax = 10 ** math.floor(math.log10(min(xs) / 2)), 10 ** math.ceil(math.log10(max(xs) * 2))
    ymin, ymax = 10 ** math.floor(math.log10(min(ys) / 2)), 10 ** math.ceil(math.log10(peak * 1.5))
    X = lambda v: ml + (math.log10(v) - math.log10(xmin)) / (math.log10(xmax) - math.log10(xmin)) * (W - ml - mr)
    Y = lambda v: H0 - mb - (math.log10(v) - math.log10(ymin)) / (math.log10(ymax) - math.log10(ymin)) * (H0 - mb - mt)
    s = [f'<svg viewBox="0 0 {W} {H}" role="img" aria-label="roofline" class="chart">']
    e = math.floor(math.log10(xmin))
    while 10 ** e <= xmax:
        s.append(f'<line x1="{X(10 ** e):.1f}" y1="{mt}" x2="{X(10 ** e):.1f}" y2="{H0 - mb}" class="grid"/>'
                 f'<text x="{X(10 ** e):.1f}" y="{H0 - mb + 16}" class="tick" text-anchor="middle">{10 ** e:g}</text>'); e += 1
    e = math.floor(math.log10(ymin))
    while 10 ** e <= ymax:
        s.append(f'<line x1="{ml}" y1="{Y(10 ** e):.1f}" x2="{W - mr}" y2="{Y(10 ** e):.1f}" class="grid"/>'
                 f'<text x="{ml - 6}" y="{Y(10 ** e) + 4:.1f}" class="tick" text-anchor="end">{10 ** e:g}</text>'); e += 1
    s.append(f'<text x="{(W + ml) / 2}" y="{H0 - 8}" class="lbl" text-anchor="middle">arithmetic intensity (FLOP per data byte)</text>'
             f'<text x="14" y="{(H0 - mb) / 2}" class="lbl" text-anchor="middle" transform="rotate(-90 14 {(H0 - mb) / 2})">FLOP / cycle</text>')

    def roof(bw, cap, cls, label):
        if not bw: return
        knee = cap / bw
        x_a = xmin; x_b = min(knee, xmax)
        s.append(f'<line x1="{X(x_a):.1f}" y1="{Y(max(bw * x_a, ymin)):.1f}" x2="{X(x_b):.1f}" y2="{Y(bw * x_b):.1f}" class="{cls}"/>')
        s.append(f'<text x="{X(x_a) + 4:.1f}" y="{Y(max(bw * x_a, ymin)) - 6:.1f}" class="tick {cls}t">{label} {bw:.2f} B/c</text>')
    cap = c['flop'] or peak
    s.append(f'<line x1="{ml}" y1="{Y(peak):.1f}" x2="{W - mr}" y2="{Y(peak):.1f}" class="roof2"/>'
             f'<text x="{W - mr - 4}" y="{Y(peak) - 5:.1f}" class="tick" text-anchor="end">datapath peak {peak} FLOP/c</text>')
    if c['flop']:
        s.append(f'<line x1="{ml}" y1="{Y(cap):.1f}" x2="{W - mr}" y2="{Y(cap):.1f}" class="roof"/>'
                 f'<text x="{W - mr - 4}" y="{Y(cap) + 14:.1f}" class="tick" text-anchor="end">measured FMA peak {cap:.2f}</text>')
    roof(c['bw_l1'], cap, 'roof3', 'L1')
    if c['bw_l2'] and c['bw_dram'] and abs(c['bw_l2'] - c['bw_dram']) < 0.05 * c['bw_l2']:
        roof(c['bw_l2'], cap, 'roof', 'L2 = DRAM')
    else:
        roof(c['bw_l2'], cap, 'roof', 'L2'); roof(c['bw_dram'], cap, 'roof', 'DRAM')
    for i, (name, m) in enumerate(pts, 1):
        x, y = X(m['ai_data']), Y(m['flop_per_cycle'])
        s.append(f'<g><title>{name}: AI {m["ai_data"]:.2f}, {m["flop_per_cycle"]:.3f} FLOP/c ({m["bound"]})</title>'
                 f'<circle cx="{x:.1f}" cy="{y:.1f}" r="7.5" class="pt"/>'
                 f'<text x="{x:.1f}" y="{y + 3.5:.1f}" class="ptn" text-anchor="middle">{i}</text></g>')
        kx = ml + ((i - 1) % 3) * (W - ml) / 3; ky = H0 + 8 + ((i - 1) // 3) * 18
        s.append(f'<text x="{kx:.1f}" y="{ky:.1f}" class="tick"><tspan class="lbl">{i}</tspan>  {html.escape(name)} '
                 f'({m["flop_per_cycle"]:.2f} FLOP/c)</text>')
    s.append('</svg>')
    return '\n'.join(s)


CSS = """
:root{--bg:#fbfaf7;--fg:#1d1d1f;--mut:#6b6b70;--line:#dedbd3;--card:#fff;--acc:#2e6fd8}
@media (prefers-color-scheme: dark){:root:not([data-theme="light"]){--bg:#17181b;--fg:#ececec;--mut:#9a9aa2;--line:#33353b;--card:#1f2125;--acc:#7aa7f0}}
:root[data-theme="dark"]{--bg:#17181b;--fg:#ececec;--mut:#9a9aa2;--line:#33353b;--card:#1f2125;--acc:#7aa7f0}
body{background:var(--bg);color:var(--fg);font:14px/1.5 system-ui,-apple-system,Segoe UI,sans-serif;margin:0;padding:24px 16px}
main{max-width:1100px;margin:0 auto}h1{font-size:22px;margin:0 0 4px}h2{font-size:17px;margin:28px 0 10px}
.mut{color:var(--mut)}table{border-collapse:collapse;width:100%;font-size:12.5px;background:var(--card)}
th,td{border-bottom:1px solid var(--line);padding:4px 6px;text-align:right;white-space:nowrap}
th:first-child,td:first-child{text-align:left}.scroll{overflow-x:auto}
code{font:12px ui-monospace,SFMono-Regular,Menlo,monospace}
.chart{width:100%;height:auto;background:var(--card);border:1px solid var(--line);border-radius:6px}
.chart .grid{stroke:var(--line);stroke-width:1}.chart .tick{fill:var(--mut);font-size:10.5px}.chart .lbl{fill:var(--fg);font-size:11.5px}
.chart .roof{stroke:var(--acc);stroke-width:2}.chart .roof2{stroke:var(--mut);stroke-dasharray:4 4}
.chart .roof3{stroke:#d1495b;stroke-width:2}.chart .rooft{fill:var(--acc)}.chart .roof3t{fill:#d1495b}.chart .pt{fill:var(--fg)}.chart .ptn{fill:var(--bg);font-size:9px;font-weight:700}
.flag{margin:10px 0;padding:8px 10px;background:var(--card);border-left:4px solid var(--line);border-radius:4px}
.flag.high{border-color:#d1495b}.flag.med{border-color:#edae49}.flag.info{border-color:var(--mut)}
.flag ul{margin:4px 0 0;padding-left:18px}.bad{color:#d1495b;font-weight:600}
"""


def write_html(out, meta, results):
    lat0 = meta['lat'][0]
    c = ceilings(results, lat0)
    H = ['<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">',
         f'<title>mahi-gpu benchmarks</title><style>{CSS}</style></head><body><main>',
         f'<h1>mahi-gpu benchmark report</h1><div class="mut">profile <code>{meta["profile"]}</code> · {meta["date"]} · '
         f'memory latency {meta["lat"]} · tables and charts at lat = {lat0} · {meta["clock_mhz"]} MHz for µs</div>']
    H.append('<h2>Findings</h2><ul>' + ''.join(f'<li><b>{html.escape(t)}</b>: {html.escape(x)}</li>'
                                                for t, x in findings(results, lat0)) + '</ul>')
    H.append('<h2>Oversights</h2>')
    for rid, e in oversights(results, lat0):
        items = ''.join(f'<li><code>{html.escape(n)}</code>: {html.escape(msg)}</li>' for n, msg in e['cases'][:8])
        more = f'<li class="mut">… and {len(e["cases"]) - 8} more</li>' if len(e['cases']) > 8 else ''
        H.append(f'<div class="flag {e["severity"]}"><b>{rid}</b> <span class="mut">({e["severity"]}, '
                 f'{len(e["cases"])} cases)</span> — {html.escape(e["hint"])}<ul>{items}{more}</ul></div>')
    H.append('<h2>Issue-slot breakdown</h2><p class="mut">Each core-cycle in exactly one bucket. ' +
             '; '.join(f'<b>{b}</b>: {BUCKET_LABEL[b]}' for b in BUCKETS) + '.</p>')
    H.append(svg_breakdown(results, lat0))
    H.append('<h2>Roofline</h2><p class="mut">Cases that do FP work. Ceilings are measured by the micro-benchmarks '
             '(FMA chains, stream_read); the dashed line is the datapath peak (2 cores × 4 lanes × FMA).</p>')
    H.append(svg_roofline(results, lat0, c))
    H.append('<h2>Per case</h2><div class="scroll"><table><tr><th>case</th>' +
             ''.join(f'<th>{h}</th>' for _, h, _ in COLS) + '<th>bound</th></tr>')
    for r in results:
        m = _m(r, lat0)
        if not m:
            H.append(f'<tr><td><code>{r["name"]}</code></td><td colspan="{len(COLS) + 1}" class="mut" style="text-align:left">'
                     f'{html.escape(r.get("skipped") or r.get("error") or str(r["runs"].get(lat0)))}</td></tr>'); continue
        bad = '' if m['bit_identical'] else ' <span class="bad">≠ golden</span>'
        H.append(f'<tr><td><code>{r["name"]}</code>{bad}</td>' + ''.join(f'<td>{_cell(m, k, kd)}</td>' for k, _, kd in COLS) +
                 f'<td style="text-align:left">{m["bound"]}</td></tr>')
    H.append('</table></div>')
    H.append('<h2>Measured ceilings</h2><table><tr><th>ceiling</th><th>value</th></tr>')
    for n, v, u in ceiling_rows(c):
        H.append(f'<tr><td>{html.escape(n)}</td><td>{fmt(v)} {u if v is not None else ""}</td></tr>')
    H.append('</table><h2>Cases</h2><ul>' + ''.join(f'<li><code>{r["name"]}</code> ({r["group"]}): {html.escape(r["desc"])}</li>'
                                                     for r in results) + '</ul></main></body></html>')
    with open(os.path.join(out, 'report.html'), 'w') as f: f.write('\n'.join(H))


def write(out, meta, results):
    write_md(out, meta, results)
    write_html(out, meta, results)


if __name__ == '__main__':
    d = sys.argv[1]
    with open(os.path.join(d, 'results.json')) as f: j = json.load(f)
    for r in j['cases']: r['runs'] = {int(k): v for k, v in r['runs'].items()}
    write(d, j['meta'], j['cases'])
    print(f'{d}/report.md, report.html')
