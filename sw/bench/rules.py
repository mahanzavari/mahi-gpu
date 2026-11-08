"""Oversight flags: rules over one case's metrics that point at a design limitation (or a kernel problem).

Each rule: (id, severity, test(m) -> bool, message(m) -> str, hint). severity: 'high' | 'med' | 'info'.
`hint` names the hardware (or kernel) change that would remove the limitation; the report groups flags by id so a
limitation that shows up in many kernels stands out.
"""
import math

from metrics import fmt


def _ok(v): return v is not None and not (isinstance(v, float) and math.isnan(v))


def gt(k, x): return lambda m: _ok(m.get(k)) and m[k] > x


def lt(k, x): return lambda m: _ok(m.get(k)) and m[k] < x


RULES = [
    ('store_stall', 'high', gt('st_wait_share', 0.15),
     lambda m: f'stores keep the LSU waiting {fmt(m["st_wait_share"], "%")} of core-cycles '
               f'({fmt(m["st_line_latency"])} cycles per stored line)',
     'write-through, blocking D$: every store goes to L2 and the LSU waits for it -> store buffer / write-back L1'),
    ('mem_latency_exposed', 'high', lambda m: m['b_mem'] > 0.4 and m['ready_warps'] < 1.0,
     lambda m: f'all warps wait on memory {fmt(m["b_mem"], "%")} of cycles, {fmt(m["ready_warps"])} ready warps on '
               f'average',
     'one outstanding request per warp and a blocking LSU: 4 warps cannot hide L1/L2 latency -> non-blocking '
     'loads (scoreboard), more warps, or an LSU that overlaps requests'),
    ('lsu_saturated', 'high', gt('lsu_busy', 0.85),
     lambda m: f'LSU busy {fmt(m["lsu_busy"], "%")} of core-cycles, {fmt(m["lsu_queue"])} warps queued on average',
     'one line per transaction, one transaction at a time per core -> wider/pipelined LSU, MSHRs'),
    ('uncoalesced', 'med', gt('tx_per_ld', 1.5),
     lambda m: f'{fmt(m["tx_per_ld"])} line transactions per warp load',
     'access pattern (kernel) or line size: lanes touch several 4-word lines'),
    ('coalescer_waste', 'med', lambda m: _ok(m['tx_per_ld']) and _ok(m['ideal_tx_per_ld'])
     and m['tx_per_ld'] > 1.05 * m['ideal_tx_per_ld'],
     lambda m: f'LSU issues {fmt(m["tx_per_ld"])} transactions per load where {fmt(m["ideal_tx_per_ld"])} lines are '
               f'touched',
     'coalescer splits accesses to the same line'),
    ('l1_thrash', 'med', lambda m: _ok(m['l1_refetch']) and m['l1_refetch'] > 2 * m['cores_used'] and m['lsu_req_rd'] > 64,
     lambda m: f'L1 read hit rate {fmt(m["l1_read_hit"], "%")}: {m["l1_fills"]:,} line fills for {m["ld_lines"]:,} '
               f'distinct lines ({fmt(m["l1_refetch"])}x refetch)',
     '16-line (64-word) L1 per core: working sets larger than 64 words miss -> bigger L1 / shared-memory tiling'),
    ('divergence', 'med', lambda m: lt('simd_eff', 0.75)(m) and m['threads'] >= m['block'],
     lambda m: f'SIMD efficiency {fmt(m["simd_eff"], "%")} (active lanes per issued instruction)',
     'branch divergence: lanes idle while the warp runs the other path'),
    ('ll_latency', 'med', lambda m: m['b_ll_dep'] + m['b_ll'] > 0.2,
     lambda m: f'{fmt(m["b_ll_dep"] + m["b_ll"], "%")} of cycles wait on FMA/DIV results',
     'FMA latency (5 cycles) / iterative divider not hidden: more independent work per warp or more warps'),
    ('serialization', 'med', gt('b_serial', 0.25),
     lambda m: f'{fmt(m["b_serial"], "%")} of cycles a ready warp is blocked by its own branch/memory/FP instruction',
     'serializing instructions hold their warp until they leave EX: with few warps the issue slot idles'),
    ('raw_stall', 'info', gt('b_raw', 0.1),
     lambda m: f'register RAW hazard {fmt(m["b_raw"], "%")} of cycles', 'no forwarding to issue: back-to-back dependent ALU ops stall'),
    ('ifetch', 'med', gt('b_ifetch', 0.05),
     lambda m: f'instruction fetch stalls {fmt(m["b_ifetch"], "%")} of cycles (I$ hit {fmt(m["icache_hit"], "%")})',
     'small I$ / fetch latency'),
    ('bank_conflicts', 'med', gt('smem_conflict', 0.1),
     lambda m: f'shared-memory bank conflicts in {fmt(m["smem_conflict"], "%")} of shared-memory cycles',
     '4 banks (address & 3): strided lanes collide -> padding in the kernel, or more banks'),
    ('atomic_serial', 'med', gt('atomic_cycles', 8),
     lambda m: f'{fmt(m["atomic_cycles"])} LSU cycles per lane atomic', 'atomics are a per-lane read + write through '
     'the write-through L1 -> atomic unit at L2'),
    ('barrier', 'info', gt('b_barrier', 0.2),
     lambda m: f'barrier wait {fmt(m["b_barrier"], "%")} of cycles', 'SYNC cost / load imbalance between warps'),
    ('flush_tail', 'info', gt('flush_share', 0.1),
     lambda m: f'end-of-kernel L2 flush is {fmt(m["flush_share"], "%")} of the runtime',
     'the whole L2 is written back at the end of every launch: short kernels pay it in full'),
    ('tail', 'info', gt('b_drain', 0.15),
     lambda m: f'cores idle with no live warp {fmt(m["b_drain"], "%")} of cycles', 'load imbalance / partial last wave'),
    ('one_core', 'info', lambda m: m['cores_used'] < 2 and m['threads'] > m['block'],
     lambda m: 'only one core did work', 'launch has fewer threads than one block per core'),
    ('vwb_stall', 'info', gt('l2_vwb_stall', 0),
     lambda m: f'L2 stalled {m["l2_vwb_stall"]} cycles on a full victim write buffer', 'VWB depth / DRAM write rate'),
    ('instr_mismatch', 'high', lambda m: not m['instr_match'],
     lambda m: f'RTL executed {m["thread_instr"]:,} thread-instructions, the golden model counts a different number',
     'replayed or lost instructions: probe or pipeline issue, investigate'),
]


def flags(m):
    out = []
    for rid, sev, test, msg, hint in RULES:
        try:
            if test(m): out.append(dict(id=rid, severity=sev, msg=msg(m), hint=hint))
        except (KeyError, TypeError, ZeroDivisionError):
            pass
    return out
