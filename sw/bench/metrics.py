"""Derived metrics of one launch, from the RTL probes (LaunchResult.perf) and the golden model's architectural counts
(LaunchResult.counts).

Units: cycles are GPU clock cycles; bandwidths are bytes per cycle; "core-cycles" are summed over cores.
Issue-slot buckets (sw/bench/rtl/perf_probes.sv, core_perf) partition each core's running cycles:
issue, ifetch, ll_dep, raw, serial, mem, ll, barrier, drain.
"""
import math
import os, sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', '..', 'ASIC', 'scripts'))
from isa import OP as OPC  # noqa: E402

BUCKETS = ['issue', 'mem', 'serial', 'll_dep', 'll', 'raw', 'ifetch', 'barrier', 'drain']
BUCKET_LABEL = {
    'issue': 'issuing', 'mem': 'all warps wait on memory', 'serial': 'warp blocked by its own in-flight instr',
    'll_dep': 'operand from FMA/DIV not ready', 'll': 'all warps wait on FMA/DIV', 'raw': 'register RAW hazard',
    'ifetch': 'instruction fetch', 'barrier': 'barrier wait', 'drain': 'no live warp (tail)'}
EV = dict(cycle=3, active=4, issue=5, fetch_stall=6, flush=7, mem=8, ic_acc=9, ic_hit=10, ic_stall=11, sched_idle=12,
          warp_switch=13, diverge=14, stall_mem=15, stall_barrier=16, stall_noready=17, dc_rd_acc=18, dc_rd_hit=19,
          dc_rd_stall=20, dc_wr_acc=21, dc_wr_hit=22, dc_wr_stall=23, fp_fire=24, fp_wb=25, fp_raw_stall=26,
          fp_wb_collision=27)
LINE_BYTES = 16


def _sum(perf, unit, key):
    return sum(v.get(key, 0) for v in perf.get(unit, {}).values())


def _div(a, b):
    return a / b if b else float('nan')


def derive(case, counts, perf, cycles, profile, clock_mhz=25.0):
    """one dict of metrics; NaN where a ratio has no denominator"""
    m = dict(cycles=cycles, time_us=cycles / clock_mhz, cycles_per_elem=_div(cycles, case.elements or 0),
             threads=case.threads, block=profile.block)
    lanes, ncores = profile.lanes, profile.cores
    cores = list(perf['core'].values())
    run = sum(c['run'] for c in cores)
    m['core_cycles'] = run
    m['cores_used'] = sum(1 for c in cores if c['issue'])
    for b in BUCKETS: m['b_' + b] = _div(sum(c[b] for c in cores), run)

    # ---- instruction throughput
    warp_i = sum(v for c in cores for k, v in c.items() if k.startswith('opw'))
    thr_i = sum(v for c in cores for k, v in c.items() if k.startswith('opt'))
    m.update(warp_instr=warp_i, thread_instr=thr_i, instr_match=thr_i == counts['thread_instr'],
             ipc=_div(warp_i, cycles), issue_util=_div(sum(c['issue'] for c in cores), run),
             simd_eff=_div(thr_i, warp_i * lanes), thread_ops_per_cycle=_div(thr_i, cycles),
             peak_thread_ops=ncores * lanes)
    m['ready_warps'] = _div(sum(i * c.get(f'ready{i}', 0) for c in cores for i in range(profile.warps + 1)), run)

    # ---- compute
    fl = counts['flops']
    m.update(flops=fl, flop_per_cycle=_div(fl, cycles), peak_flop=2 * ncores * lanes,
             fp_frac=_div(sum(counts['ops'].get(o, 0) for o in ('FADD', 'FSUB', 'FMUL', 'FMA')), counts['thread_instr']),
             mem_instr_frac=_div(sum(counts['ops'].get(o, 0) for o in ('LDR', 'STR', 'ATOM_ADD', 'LDSH', 'STSH')),
                                 counts['thread_instr']))
    opw = lambda ops: sum(c.get(f'opw{OPC[o]}', 0) for c in cores for o in ops)
    m['fp_warp_instr'] = opw(('FADD', 'FSUB', 'FMUL', 'FMA'))
    m['div_warp_instr'] = opw(('DIV', 'MOD'))
    # warp-cycles per FP instruction: how often one warp gets an FP instruction out (>= warps per core when every
    # issue slot is FP; a warp blocked until each FP result is written back shows the FMA round trip instead)
    m['fp_interval'] = _div(run * profile.warps, m['fp_warp_instr'])
    m['div_cycles'] = _div(_sum(perf, 'div', 'busy'), m['div_warp_instr'])
    m['fp_wb_collisions'] = sum(c.get(f'ev{EV["fp_wb_collision"]}', 0) for c in cores)

    # ---- memory traffic per level
    data_words = counts['ld_words'] - counts['ld_param'] + counts['st_words'] + 2 * counts['atomics']
    l1_lines = _sum(perf, 'dcache', 'reads') + _sum(perf, 'dcache', 'writes')
    l2_req = _sum(perf, 'l2', 'req_rd') + _sum(perf, 'l2', 'req_wr')
    dram_lines = _sum(perf, 'ext', 'line_reads') + _sum(perf, 'ext', 'line_writes')
    m.update(data_bytes=4 * data_words, bw_data=_div(4 * data_words, cycles),
             l1_bytes=LINE_BYTES * l1_lines, bw_l1=_div(LINE_BYTES * l1_lines, cycles),
             l2_bytes=LINE_BYTES * l2_req, bw_l2=_div(LINE_BYTES * l2_req, cycles),
             dram_bytes=LINE_BYTES * dram_lines, bw_dram=_div(LINE_BYTES * dram_lines, cycles),
             dram_reads=_sum(perf, 'ext', 'line_reads'), dram_writes=_sum(perf, 'ext', 'line_writes'))
    m['ai_data'] = _div(fl, 4 * data_words) if fl else 0.0
    m['ai_dram'] = _div(fl, LINE_BYTES * dram_lines) if fl else 0.0

    # ---- caches
    rd, fills = _sum(perf, 'dcache', 'reads'), _sum(perf, 'dcache', 'fills')
    m['l1_read_hit'] = 1 - _div(fills, rd) if rd else float('nan')
    m['l1_fills'], m['ld_lines'] = fills, counts['ld_lines']
    m['l1_refetch'] = _div(fills, counts['ld_lines'])       # >> 1 per core: lines fetched again (capacity/conflict)
    hits = _sum(perf, 'l2', 'hit_rd') + _sum(perf, 'l2', 'hit_wr')
    m['l2_hit'] = _div(hits, l2_req)
    m['l2_rd_hit'] = _div(_sum(perf, 'l2', 'hit_rd'), _sum(perf, 'l2', 'req_rd'))
    m['l2_victims'] = _sum(perf, 'l2', 'victims')
    m['l2_vwb_stall'] = _sum(perf, 'l2', 'vwb_stall')
    m['l2_flush_cycles'] = _sum(perf, 'l2', 'flush')
    m['flush_share'] = _div(m['l2_flush_cycles'], cycles)
    ic_acc = sum(c.get(f'ev{EV["ic_acc"]}', 0) for c in cores)
    m['icache_hit'] = _div(sum(c.get(f'ev{EV["ic_hit"]}', 0) for c in cores), ic_acc)

    # ---- LSU: coalescing, occupancy, per-line latency
    req_rd, req_wr = _sum(perf, 'lsu', 'req_rd'), _sum(perf, 'lsu', 'req_wr')
    tx_rd, tx_wr = _sum(perf, 'lsu', 'tx_rd'), _sum(perf, 'lsu', 'tx_wr')
    m.update(lsu_req_rd=req_rd, lsu_req_wr=req_wr, lsu_req_sh=_sum(perf, 'lsu', 'req_sh'),
             lsu_req_at=_sum(perf, 'lsu', 'req_at'),
             tx_per_ld=_div(tx_rd, req_rd), tx_per_st=_div(tx_wr, req_wr),
             ideal_tx_per_ld=_div(counts['ideal_tx_rd'], counts['warp_ld']),
             ideal_tx_per_st=_div(counts['ideal_tx_wr'], counts['warp_st']))
    busy_keys = ('coal_rd', 'wait_rd', 'coal_wr', 'wait_wr', 'wait_sh', 'at_rd', 'at_wait_rd', 'at_wait_wr')
    lsu_busy = sum(_sum(perf, 'lsu', k) for k in busy_keys)
    m['lsu_busy'] = _div(lsu_busy, run)
    m['lsu_queue'] = _div(_sum(perf, 'lsu', 'queued'), run)          # mean warps with a pending request, per core
    # LSU cycles per line transaction (issue + wait for the D$ answer), i.e. what one line costs the serial LSU
    m['ld_line_latency'] = _div(_sum(perf, 'lsu', 'wait_rd') + _sum(perf, 'lsu', 'coal_rd'), tx_rd)
    m['st_line_latency'] = _div(_sum(perf, 'lsu', 'wait_wr') + _sum(perf, 'lsu', 'coal_wr'), tx_wr)
    m['st_wait_share'] = _div(_sum(perf, 'lsu', 'wait_wr'), run)
    m['ld_wait_share'] = _div(_sum(perf, 'lsu', 'wait_rd'), run)
    tx_at = _sum(perf, 'lsu', 'tx_at')
    m['atomic_cycles'] = _div(sum(_sum(perf, 'lsu', k) for k in ('at_rd', 'at_wait_rd', 'at_wait_wr')), tx_at)

    # ---- shared memory, divider
    sb = _sum(perf, 'smem', 'busy')
    m['smem_busy'] = sb
    m['smem_conflict'] = _div(_sum(perf, 'smem', 'conflict'), sb) if sb else float('nan')
    m['div_busy'] = _div(_sum(perf, 'div', 'busy'), run)

    m['bound'] = classify(m)
    return m


def classify(m):
    """dominant limiter, from the issue-slot breakdown and the LSU occupancy"""
    if m['b_issue'] >= 0.5:
        return 'compute (FP)' if m['fp_frac'] >= 0.3 else 'compute (instruction overhead)'
    stalls = {b: m['b_' + b] for b in BUCKETS if b != 'issue'}
    top = max(stalls, key=stalls.get)
    if top == 'mem':
        return 'memory: LSU throughput' if m['lsu_busy'] >= 0.8 else 'memory: latency'
    return {'serial': 'pipeline serialization', 'll_dep': 'FMA/DIV latency', 'll': 'FMA/DIV latency',
            'raw': 'register dependency', 'ifetch': 'front-end (fetch)', 'barrier': 'synchronization',
            'drain': 'tail / occupancy'}[top]


def latency_sensitivity(m0, m1, lat):
    """exposed share of the extra memory latency: tb `+lat` adds a uniform 0..lat (mean lat/2) cycles per external
    line transfer; 1.0 = every added cycle shows up in the runtime (no overlap), 0 = fully hidden"""
    extra = (m0['dram_reads'] + m0['dram_writes']) * lat / 2
    return _div(m1['cycles'] - m0['cycles'], extra) if extra else float('nan')


def fmt(v, kind='f'):
    if v is None or (isinstance(v, float) and math.isnan(v)): return '–'
    if kind == '%': return f'{100 * v:.0f}%'
    if isinstance(v, bool): return 'yes' if v else 'NO'
    if isinstance(v, int): return f'{v:,}'
    return f'{v:.2f}' if abs(v) < 100 else f'{v:,.0f}'
