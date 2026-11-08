# mahi-gpu benchmark report — profile `fpga`

2026-11-08T20:39:52, testbench memory latency [0, 20] (uniform 0..lat extra cycles per external line), clock 25.0 MHz for µs. Tables use lat = 0.

## Measured ceilings

| ceiling | value |
|---|---|
| peak FP32 throughput | 6.75 FLOP/cycle |
| peak integer throughput | 6.80 thread-ops/cycle |
| read bandwidth, L1-resident | 1.77 B/cycle |
| read bandwidth, L2-resident | 1.22 B/cycle |
| read bandwidth, from DRAM | 1.21 B/cycle |
| copy bandwidth (read + write) | 0.92 B/cycle |
| triad bandwidth | 1.00 B/cycle |
| store-only bandwidth | 0.73 B/cycle |
| dependent load, L1 hit | 24.91 cycles/hop |
| dependent load, L2 hit | 36.51 cycles/hop |
| dependent load, DRAM | 38.51 cycles/hop |
| barrier (ADD + SYNC round) | 39.30 cycles |
| atomic, no contention | 17.36 LSU cycles/lane |
| 4-way bank conflict slowdown | 1.04 × |
| 1/4-lanes divergence slowdown | 1.00 × |

## Findings

- **FP instruction-level parallelism**: with 8 independent FMA chains a warp still gets an FP instruction out only every 9.1 warp-cycles (1 chain: 13.7; the issue-slot limit with 4 warps sharing a core is 4). Independent FMAs of one warp do not overlap: the scheduler parks the warp in WAITING_FP after every FP instruction until its writeback, so the FMA round trip, not the data dependence, sets the rate; only more warps fill it. Peak reached: 6.75 of 16 FLOP/cycle.
- **Divider**: one DIV keeps the per-core divider busy 46 cycles and the warp waits for it; DIV-bound code issues 15% of cycles.
- **Atomics are not coherent across cores**: ATOM_ADD on one word is correct inside one core but loses updates when both cores use it (atomic bins=1: 1 of 1 values wrong, first got [128] want [256]). Each core's write-through L1 keeps its own copy of the line; the LSU's atomic read can hit that stale copy, nothing invalidates it when the other core writes. Also seen in: atomic_b4, histogram.
- **Coalescing**: lanes 4 words apart cost 2.73x the cycles of consecutive lanes (3.53 vs 1.00 line transactions per warp load, 19.2 LSU cycles per line).
- **Load latency**: LSU cycles per load line: 4.5 on an L1 hit, 15.9 from L2, 17.9 from testbench DRAM at this latency setting; a dependent-load loop of 6 instructions takes 24.9 / 36.5 / 38.5 cycles per hop. Even an L1 hit costs several cycles in the LSU state machine (request, D$ answer, writeback), and the warp waits throughout.
- **Read bandwidth by level**: 1.77 / 1.22 / 1.21 B/cycle for L1 / L2 / DRAM-resident data (LSU busy 41% / 75% / 96%). L1-resident streaming is limited by loop instructions (8 per element, no immediates); beyond L1 the per-core LSU (one line at a time, blocking) is the limit, far below what a 16-byte line port could deliver.
- **Stores**: store-only bandwidth 0.73 B/cycle (32.9 LSU cycles per stored line) vs 1.22 for reads.
- **External-memory latency is not overlapped**: raising the testbench memory latency to 0..20 cycles makes stream_read_dram 1.76x slower; 100% of the added latency is exposed. The L2 serves one request at a time and waits for each miss (no MSHRs), so with only 2 cores x 1 outstanding line nothing overlaps.
- **Shared-memory banks**: 4-way bank conflicts cost 1.04x (conflict in 67% of shared-memory cycles).
- **Divergence**: with 1 of 4 lanes working, the kernel still takes 1.00x the cycles of all lanes working (SIMD efficiency 32%): the idle lanes save nothing.
- **Shared-memory tiling (GEMM)**: tiled GEMM 23,600 vs naive 24,608 cycles (1.04x): it removes 69% of the global loads but executes 1.55x the instructions (address arithmetic without immediates or an addressing mode).
- **Transpose**: shared-memory transpose 3,069 vs naive 3,794 cycles; store transactions per warp store 1.00 vs 4.00.

## Oversights

Rules over every case (sw/bench/rules.py), grouped; most severe and most frequent first.

- **wrong_result** (high, 3 cases): functional bug: the RTL result is wrong
  - `atomic_b1`: atomic bins=1: 1 of 1 values wrong, first got [128] want [256]
  - `atomic_b4`: atomic bins=4: 4 of 4 values wrong, first got [32 32 32 32] want [64 64 64 64]
  - `histogram`: histogram: 16 of 16 values wrong, first got [37 36 40 34] want [72 60 77 65]
- **mem_latency_exposed** (high, 20 cases): one outstanding request per warp and a blocking LSU: 4 warps cannot hide L1/L2 latency -> non-blocking loads (scoreboard), more warps, or an LSU that overlaps requests
  - `stream_copy`: all warps wait on memory 62% of cycles, 0.39 ready warps on average
  - `stream_triad`: all warps wait on memory 62% of cycles, 0.39 ready warps on average
  - `stream_memset`: all warps wait on memory 50% of cycles, 0.52 ready warps on average
  - `stride_s2`: all warps wait on memory 50% of cycles, 0.53 ready warps on average
  - `stride_s4`: all warps wait on memory 72% of cycles, 0.30 ready warps on average
  - `stride_s8`: all warps wait on memory 70% of cycles, 0.32 ready warps on average
  - … and 14 more
- **lsu_saturated** (high, 18 cases): one line per transaction, one transaction at a time per core -> wider/pipelined LSU, MSHRs
  - `stream_read_dram`: LSU busy 96% of core-cycles, 2.00 warps queued on average
  - `stream_copy`: LSU busy 97% of core-cycles, 2.58 warps queued on average
  - `stream_triad`: LSU busy 96% of core-cycles, 2.53 warps queued on average
  - `stream_memset`: LSU busy 96% of core-cycles, 2.45 warps queued on average
  - `stride_s1`: LSU busy 92% of core-cycles, 2.09 warps queued on average
  - `stride_s2`: LSU busy 96% of core-cycles, 2.44 warps queued on average
  - … and 12 more
- **store_stall** (high, 9 cases): write-through, blocking D$: every store goes to L2 and the LSU waits for it -> store buffer / write-back L1
  - `stream_copy`: stores keep the LSU waiting 52% of core-cycles (35.50 cycles per stored line)
  - `stream_triad`: stores keep the LSU waiting 25% of core-cycles (25.00 cycles per stored line)
  - `stream_memset`: stores keep the LSU waiting 90% of core-cycles (32.90 cycles per stored line)
  - `gather`: stores keep the LSU waiting 15% of core-cycles (27.53 cycles per stored line)
  - `vadd`: stores keep the LSU waiting 19% of core-cycles (21.79 cycles per stored line)
  - `stencil3`: stores keep the LSU waiting 41% of core-cycles (24.35 cycles per stored line)
  - … and 3 more
- **uncoalesced** (med, 7 cases): access pattern (kernel) or line size: lanes touch several 4-word lines
  - `stride_s2`: 1.84 line transactions per warp load
  - `stride_s4`: 3.53 line transactions per warp load
  - `stride_s8`: 3.53 line transactions per warp load
  - `gather`: 2.39 line transactions per warp load
  - `matvec`: 2.23 line transactions per warp load
  - `stencil3`: 1.62 line transactions per warp load
  - … and 1 more
- **serialization** (med, 5 cases): serializing instructions hold their warp until they leave EX: with few warps the issue slot idles
  - `stream_read_l2`: 34% of cycles a ready warp is blocked by its own branch/memory/FP instruction
  - `stream_read_dram`: 38% of cycles a ready warp is blocked by its own branch/memory/FP instruction
  - `stride_s1`: 29% of cycles a ready warp is blocked by its own branch/memory/FP instruction
  - `chase_l1`: 34% of cycles a ready warp is blocked by its own branch/memory/FP instruction
  - `gemm_naive`: 34% of cycles a ready warp is blocked by its own branch/memory/FP instruction
- **l1_thrash** (med, 5 cases): 16-line (64-word) L1 per core: working sets larger than 64 words miss -> bigger L1 / shared-memory tiling
  - `stride_s4`: L1 read hit rate 4%: 1,034 line fills for 258 distinct lines (4.01x refetch)
  - `stride_s8`: L1 read hit rate 4%: 1,032 line fills for 130 distinct lines (7.94x refetch)
  - `gemm_naive`: L1 read hit rate 46%: 1,809 line fills for 226 distinct lines (8.00x refetch)
  - `linear_fwd`: L1 read hit rate 19%: 8,484 line fills for 198 distinct lines (42.85x refetch)
  - `mlp_train`: L1 read hit rate 65%: 15,776 line fills for 93 distinct lines (170x refetch)
- **atomic_serial** (med, 5 cases): atomics are a per-lane read + write through the write-through L1 -> atomic unit at L2
  - `atomic_b1`: 15.90 LSU cycles per lane atomic
  - `atomic_b4`: 15.90 LSU cycles per lane atomic
  - `atomic_b64`: 17.36 LSU cycles per lane atomic
  - `atomic_b1_1core`: 14.30 LSU cycles per lane atomic
  - `histogram`: 16.92 LSU cycles per lane atomic
- **ll_latency** (med, 4 cases): FMA latency (5 cycles) / iterative divider not hidden: more independent work per warp or more warps
  - `fma_chain4`: 20% of cycles wait on FMA/DIV results
  - `fma_chain8`: 22% of cycles wait on FMA/DIV results
  - `div_chain1`: 76% of cycles wait on FMA/DIV results
  - `div_chain4`: 87% of cycles wait on FMA/DIV results
- **bank_conflicts** (med, 3 cases): 4 banks (address & 3): strided lanes collide -> padding in the kernel, or more banks
  - `smem_s2`: shared-memory bank conflicts in 40% of shared-memory cycles
  - `smem_s4`: shared-memory bank conflicts in 67% of shared-memory cycles
  - `transpose_smem`: shared-memory bank conflicts in 60% of shared-memory cycles
- **divergence** (med, 2 cases): branch divergence: lanes idle while the warp runs the other path
  - `diverge_m1`: SIMD efficiency 55% (active lanes per issued instruction)
  - `diverge_m3`: SIMD efficiency 32% (active lanes per issued instruction)
- **flush_tail** (info, 18 cases): the whole L2 is written back at the end of every launch: short kernels pay it in full
  - `add_chain1`: end-of-kernel L2 flush is 11% of the runtime
  - `div_chain1`: end-of-kernel L2 flush is 15% of the runtime
  - `stream_read_l1`: end-of-kernel L2 flush is 13% of the runtime
  - `stream_memset`: end-of-kernel L2 flush is 21% of the runtime
  - `smem_s1`: end-of-kernel L2 flush is 14% of the runtime
  - `smem_s2`: end-of-kernel L2 flush is 14% of the runtime
  - … and 12 more
- **raw_stall** (info, 1 case): no forwarding to issue: back-to-back dependent ALU ops stall
  - `stride_s1`: register RAW hazard 14% of cycles

## Per case

| case | cycles | µs | IPC | SIMD | FLOP/c | data B/c | DRAM B/c | L1 hit | L2 hit | tx/ld | LSU busy | ready | bound |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---|
| `fma_chain1` | 3,823 | 153 | 1.24 | 100% | 4.29 | 0.03 | 0.07 | 92% | 10% | 1.00 | 4% | 2.36 | compute (FP) |
| `fma_chain2` | 5,909 | 236 | 1.15 | 100% | 5.55 | 0.04 | 0.09 | 92% | 6% | 1.00 | 5% | 1.97 | compute (FP) |
| `fma_chain4` | 10,539 | 422 | 1.04 | 100% | 6.22 | 0.05 | 0.10 | 92% | 3% | 1.00 | 4% | 1.79 | compute (FP) |
| `fma_chain8` | 19,421 | 777 | 0.99 | 100% | 6.75 | 0.05 | 0.11 | 92% | 2% | 1.00 | 4% | 1.63 | compute (FP) |
| `add_chain1` | 2,861 | 114 | 1.66 | 100% | 0.00 | 0.04 | 0.10 | 92% | 10% | 1.00 | 6% | 3.76 | compute (instruction overhead) |
| `add_chain4` | 6,441 | 258 | 1.70 | 100% | 0.00 | 0.08 | 0.16 | 92% | 3% | 1.00 | 7% | 3.71 | compute (instruction overhead) |
| `div_chain1` | 2,036 | 81.44 | 0.25 | 100% | 0.00 | 0.06 | 0.13 | 92% | 10% | 1.00 | 8% | 2.83 | FMA/DIV latency |
| `div_chain4` | 7,127 | 285 | 0.11 | 100% | 0.00 | 0.07 | 0.15 | 92% | 3% | 1.00 | 7% | 2.86 | FMA/DIV latency |
| `stream_read_l1` | 2,392 | 95.68 | 1.33 | 100% | 0.43 | 1.77 | 0.23 | 93% | 13% | 1.00 | 41% | 2.72 | compute (instruction overhead) |
| `stream_read_l2` | 6,810 | 272 | 0.66 | 100% | 0.30 | 1.22 | 0.34 | 6% | 74% | 1.00 | 75% | 0.92 | pipeline serialization |
| `stream_read_dram` | 27,279 | 1,091 | 0.61 | 100% | 0.30 | 1.21 | 1.21 | 2% | 0% | 1.00 | 96% | 0.78 | pipeline serialization |
| `stream_copy` | 17,753 | 710 | 0.26 | 100% | 0.00 | 0.92 | 1.39 | 5% | 0% | 1.00 | 97% | 0.39 | memory: LSU throughput |
| `stream_triad` | 24,455 | 978 | 0.26 | 100% | 0.17 | 1.00 | 1.34 | 4% | 0% | 1.00 | 96% | 0.39 | memory: LSU throughput |
| `stream_memset` | 11,151 | 446 | 0.33 | 100% | 0.00 | 0.73 | 1.47 | 94% | 0% | 1.00 | 96% | 0.52 | memory: LSU throughput |
| `stride_s1` | 4,003 | 160 | 0.68 | 100% | 0.00 | 1.06 | 1.10 | 14% | 1% | 1.00 | 92% | 0.87 | pipeline serialization |
| `stride_s2` | 6,319 | 253 | 0.43 | 100% | 0.00 | 0.67 | 0.70 | 7% | 49% | 1.84 | 96% | 0.53 | memory: LSU throughput |
| `stride_s4` | 10,913 | 437 | 0.25 | 100% | 0.00 | 0.39 | 0.40 | 4% | 74% | 3.53 | 98% | 0.30 | memory: LSU throughput |
| `stride_s8` | 10,388 | 416 | 0.26 | 100% | 0.00 | 0.41 | 0.23 | 4% | 87% | 3.53 | 98% | 0.32 | memory: LSU throughput |
| `gather` | 21,718 | 869 | 0.13 | 100% | 0.00 | 0.57 | 1.21 | 3% | 9% | 2.39 | 98% | 0.20 | memory: LSU throughput |
| `chase_l1` | 6,376 | 255 | 0.28 | 25% | 0.00 | 0.16 | 0.03 | 97% | 0% | 1.00 | 19% | 0.72 | pipeline serialization |
| `chase_l2` | 9,346 | 374 | 0.19 | 25% | 0.00 | 0.11 | 0.22 | 1% | 50% | 1.00 | 46% | 0.48 | memory: latency |
| `chase_dram` | 9,858 | 394 | 0.18 | 25% | 0.00 | 0.10 | 0.42 | 1% | 0% | 1.00 | 49% | 0.46 | memory: latency |
| `smem_s1` | 2,199 | 87.96 | 1.47 | 100% | 0.00 | 0.06 | 0.12 | 94% | 10% | 1.00 | 40% | 3.11 | compute (instruction overhead) |
| `smem_s2` | 2,199 | 87.96 | 1.47 | 100% | 0.00 | 0.06 | 0.12 | 94% | 10% | 1.00 | 53% | 2.95 | compute (instruction overhead) |
| `smem_s4` | 2,288 | 91.52 | 1.42 | 100% | 0.00 | 0.06 | 0.12 | 94% | 10% | 1.00 | 77% | 2.51 | compute (instruction overhead) |
| `atomic_b1` ⚠ | 2,520 | 101 | 0.27 | 100% | 0.00 | 0.81 | 0.02 | 99% | 99% | 1.00 | 94% | 0.42 | memory: LSU throughput |
| `atomic_b4` ⚠ | 2,520 | 101 | 0.27 | 100% | 0.00 | 0.81 | 0.02 | 99% | 99% | 1.00 | 94% | 0.42 | memory: LSU throughput |
| `atomic_b64` | 2,813 | 113 | 0.24 | 100% | 0.00 | 0.73 | 0.19 | 93% | 94% | 1.00 | 95% | 0.38 | memory: LSU throughput |
| `atomic_b1_1core` | 4,170 | 167 | 0.15 | 100% | 0.00 | 0.49 | 0.01 | 99% | 99% | 1.00 | 96% | 0.41 | memory: LSU throughput |
| `diverge_m0` | 1,046 | 41.84 | 1.09 | 100% | 0.00 | 0.12 | 0.26 | 92% | 10% | 1.00 | 22% | 3.21 | compute (instruction overhead) |
| `diverge_m1` | 1,049 | 41.96 | 1.08 | 55% | 0.00 | 0.12 | 0.26 | 92% | 10% | 1.00 | 22% | 3.21 | compute (instruction overhead) |
| `diverge_m3` | 1,049 | 41.96 | 1.08 | 32% | 0.00 | 0.12 | 0.26 | 92% | 10% | 1.00 | 22% | 3.21 | compute (instruction overhead) |
| `barrier` | 2,515 | 101 | 1.46 | 100% | 0.00 | 0.05 | 0.11 | 88% | 10% | 1.00 | 6% | 3.45 | compute (instruction overhead) |
| `vadd` | 3,154 | 126 | 0.26 | 100% | 0.06 | 0.73 | 0.98 | 64% | 5% | 1.00 | 81% | 0.55 | memory: LSU throughput |
| `matvec` | 12,041 | 482 | 0.24 | 100% | 0.17 | 0.72 | 0.41 | 23% | 73% | 2.23 | 93% | 0.32 | memory: LSU throughput |
| `reduce_sum` | 4,145 | 166 | 0.89 | 99% | 0.19 | 0.20 | 0.21 | 54% | 16% | 1.00 | 44% | 1.93 | memory: latency |
| `dot` | 14,921 | 597 | 0.43 | 100% | 0.29 | 1.10 | 1.10 | 5% | 1% | 1.00 | 91% | 0.66 | memory: LSU throughput |
| `gemm_naive` | 24,608 | 984 | 0.67 | 100% | 0.50 | 2.03 | 0.22 | 46% | 85% | 1.00 | 77% | 0.83 | pipeline serialization |
| `gemm_smem` | 23,600 | 944 | 1.08 | 100% | 0.52 | 0.55 | 0.23 | 24% | 65% | 1.00 | 60% | 1.79 | compute (instruction overhead) |
| `stencil3` | 15,590 | 624 | 0.25 | 100% | 0.33 | 1.05 | 1.04 | 68% | 27% | 1.62 | 90% | 0.41 | memory: LSU throughput |
| `transpose_naive` | 3,794 | 152 | 0.24 | 100% | 0.00 | 0.40 | 0.62 | 82% | 60% | 1.00 | 84% | 0.52 | memory: LSU throughput |
| `transpose_smem` | 3,069 | 123 | 0.58 | 100% | 0.00 | 0.50 | 0.76 | 81% | 5% | 1.00 | 74% | 1.38 | memory: latency |
| `histogram` ⚠ | 12,296 | 492 | 0.20 | 100% | 0.00 | 1.00 | 0.35 | 79% | 80% | 1.00 | 97% | 0.29 | memory: LSU throughput |
| `prefix_scan` | 3,570 | 143 | 0.74 | 100% | 0.00 | 0.29 | 0.43 | 65% | 2% | 1.00 | 48% | 1.65 | memory: latency |
| `linear_fwd` | 87,961 | 3,518 | 0.25 | 100% | 0.19 | 0.79 | 0.12 | 19% | 94% | 2.44 | 94% | 0.31 | memory: LSU throughput |
| `mlp_train` | 525,943 | 21,038 | 0.44 | 100% | 0.27 | 1.16 | 0.01 | 65% | 100% | 1.21 | 81% | 1.26 | memory: LSU throughput |

## Issue-slot breakdown (share of core-cycles)

| case | issue | mem | serial | ll_dep | ll | raw | ifetch | barrier | drain |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| `fma_chain1` | 68% | 3% | 23% | 0% | 6% | 0% | 1% | 0% | 0% |
| `fma_chain2` | 62% | 3% | 18% | 0% | 16% | 0% | 1% | 0% | 0% |
| `fma_chain4` | 54% | 3% | 21% | 0% | 20% | 0% | 1% | 0% | 0% |
| `fma_chain8` | 51% | 3% | 23% | 0% | 22% | 0% | 1% | 0% | 0% |
| `add_chain1` | 93% | 4% | 1% | 0% | 0% | 0% | 2% | 0% | 0% |
| `add_chain4` | 92% | 5% | 1% | 0% | 0% | 0% | 1% | 0% | 0% |
| `div_chain1` | 15% | 5% | 2% | 76% | 0% | 0% | 2% | 0% | 0% |
| `div_chain4` | 6% | 5% | 1% | 87% | 0% | 0% | 1% | 0% | 0% |
| `stream_read_l1` | 77% | 6% | 10% | 0% | 0% | 4% | 2% | 0% | 0% |
| `stream_read_l2` | 34% | 19% | 34% | 0% | 3% | 8% | 1% | 0% | 0% |
| `stream_read_dram` | 31% | 23% | 38% | 0% | 0% | 8% | 0% | 0% | 0% |
| `stream_copy` | 14% | 62% | 17% | 0% | 0% | 6% | 0% | 0% | 0% |
| `stream_triad` | 13% | 62% | 18% | 0% | 0% | 7% | 0% | 0% | 0% |
| `stream_memset` | 21% | 50% | 24% | 0% | 0% | 6% | 0% | 0% | 0% |
| `stride_s1` | 37% | 19% | 29% | 0% | 0% | 14% | 1% | 0% | 0% |
| `stride_s2` | 23% | 50% | 18% | 0% | 0% | 8% | 1% | 0% | 0% |
| `stride_s4` | 13% | 72% | 10% | 0% | 0% | 5% | 0% | 0% | 0% |
| `stride_s8` | 13% | 70% | 11% | 0% | 0% | 5% | 0% | 0% | 0% |
| `gather` | 7% | 81% | 9% | 0% | 0% | 4% | 0% | 0% | 0% |
| `chase_l1` | 29% | 28% | 34% | 0% | 0% | 8% | 0% | 0% | 0% |
| `chase_l2` | 20% | 51% | 23% | 0% | 0% | 6% | 0% | 0% | 0% |
| `chase_dram` | 19% | 54% | 22% | 0% | 0% | 5% | 0% | 0% | 0% |
| `smem_s1` | 86% | 6% | 3% | 0% | 0% | 2% | 3% | 0% | 0% |
| `smem_s2` | 86% | 6% | 3% | 0% | 0% | 2% | 3% | 0% | 0% |
| `smem_s4` | 82% | 5% | 3% | 0% | 0% | 7% | 3% | 0% | 0% |
| `atomic_b1` | 15% | 65% | 13% | 0% | 0% | 5% | 1% | 0% | 0% |
| `atomic_b4` | 15% | 65% | 13% | 0% | 0% | 5% | 1% | 0% | 0% |
| `atomic_b64` | 14% | 68% | 12% | 0% | 0% | 5% | 1% | 0% | 0% |
| `atomic_b1_1core` | 16% | 63% | 14% | 0% | 0% | 6% | 1% | 0% | 0% |
| `diverge_m0` | 78% | 14% | 2% | 0% | 0% | 1% | 5% | 0% | 0% |
| `diverge_m1` | 78% | 14% | 3% | 0% | 0% | 1% | 5% | 0% | 0% |
| `diverge_m3` | 78% | 14% | 3% | 0% | 0% | 1% | 5% | 0% | 0% |
| `barrier` | 84% | 4% | 7% | 0% | 0% | 0% | 2% | 3% | 0% |
| `vadd` | 16% | 63% | 18% | 0% | 1% | 0% | 1% | 0% | 0% |
| `matvec` | 12% | 75% | 11% | 0% | 0% | 0% | 0% | 0% | 0% |
| `reduce_sum` | 48% | 23% | 18% | 0% | 0% | 8% | 1% | 1% | 0% |
| `dot` | 22% | 45% | 25% | 0% | 0% | 7% | 1% | 0% | 0% |
| `gemm_naive` | 34% | 29% | 34% | 0% | 2% | 1% | 0% | 0% | 0% |
| `gemm_smem` | 56% | 19% | 17% | 0% | 0% | 7% | 1% | 0% | 0% |
| `stencil3` | 13% | 64% | 18% | 0% | 1% | 3% | 0% | 0% | 0% |
| `transpose_naive` | 14% | 68% | 11% | 0% | 0% | 6% | 1% | 0% | 0% |
| `transpose_smem` | 36% | 37% | 14% | 0% | 0% | 9% | 3% | 0% | 0% |
| `histogram` | 10% | 73% | 12% | 0% | 0% | 4% | 0% | 0% | 0% |
| `prefix_scan` | 43% | 29% | 23% | 0% | 0% | 2% | 2% | 1% | 0% |
| `linear_fwd` | 13% | 74% | 12% | 0% | 0% | 0% | 0% | 0% | 0% |
| `mlp_train` | 44% | 25% | 21% | 0% | 1% | 6% | 3% | 0% | 0% |

- **issue**: issuing
- **mem**: all warps wait on memory
- **serial**: warp blocked by its own in-flight instr
- **ll_dep**: operand from FMA/DIV not ready
- **ll**: all warps wait on FMA/DIV
- **raw**: register RAW hazard
- **ifetch**: instruction fetch
- **barrier**: barrier wait
- **drain**: no live warp (tail)

## Memory-latency sensitivity

Exposed share = added cycles / added latency summed over external line transfers (1 = nothing overlaps).

| case | cycles @lat 0 | cycles @lat 20 | exposed @20 |
|---|---:|---:|---:|
| `fma_chain1` | 3,823 | 4,057 | 1.38 |
| `fma_chain2` | 5,909 | 6,150 | 0.73 |
| `fma_chain4` | 10,539 | 10,954 | 0.64 |
| `fma_chain8` | 19,421 | 20,425 | 0.78 |
| `add_chain1` | 2,861 | 3,041 | 1.06 |
| `add_chain4` | 6,441 | 6,871 | 0.66 |
| `div_chain1` | 2,036 | 2,177 | 0.83 |
| `div_chain4` | 7,127 | 7,392 | 0.41 |
| `stream_read_l1` | 2,392 | 2,621 | 0.67 |
| `stream_read_l2` | 6,810 | 8,170 | 0.93 |
| `stream_read_dram` | 27,279 | 47,954 | 1.00 |
| `stream_copy` | 17,753 | 30,670 | 0.84 |
| `stream_triad` | 24,455 | 42,420 | 0.88 |
| `stream_memset` | 11,151 | 18,597 | 0.73 |
| `stride_s1` | 4,003 | 6,561 | 0.93 |
| `stride_s2` | 6,319 | 8,930 | 0.95 |
| `stride_s4` | 10,913 | 13,482 | 0.93 |
| `stride_s8` | 10,388 | 11,737 | 0.92 |
| `gather` | 21,718 | 36,909 | 0.92 |
| `chase_l1` | 6,376 | 6,511 | 1.23 |
| `chase_l2` | 9,346 | 10,531 | 0.90 |
| `chase_dram` | 9,858 | 12,344 | 0.96 |
| `smem_s1` | 2,199 | 2,409 | 1.24 |
| `smem_s2` | 2,199 | 2,401 | 1.19 |
| `smem_s4` | 2,288 | 2,505 | 1.28 |
| `atomic_b1` | 2,520 | 2,569 | 1.63 |
| `atomic_b4` | 2,520 | 2,569 | 1.63 |
| `atomic_b64` | 2,813 | 3,045 | 0.70 |
| `atomic_b1_1core` | 4,170 | 4,205 | 1.17 |
| `diverge_m0` | 1,046 | 1,199 | 0.90 |
| `diverge_m1` | 1,049 | 1,199 | 0.88 |
| `diverge_m3` | 1,049 | 1,199 | 0.88 |
| `barrier` | 2,515 | 2,636 | 0.71 |
| `vadd` | 3,154 | 4,557 | 0.73 |
| `matvec` | 12,041 | 14,919 | 0.93 |
| `reduce_sum` | 4,145 | 4,580 | 0.79 |
| `dot` | 14,921 | 25,196 | 1.00 |
| `gemm_naive` | 24,608 | 27,755 | 0.95 |
| `gemm_smem` | 23,600 | 26,523 | 0.85 |
| `stencil3` | 15,590 | 23,361 | 0.77 |
| `transpose_naive` | 3,794 | 4,790 | 0.68 |
| `transpose_smem` | 3,069 | 3,961 | 0.61 |
| `histogram` | 12,296 | 14,739 | 0.92 |
| `prefix_scan` | 3,570 | 4,119 | 0.57 |
| `linear_fwd` | 87,961 | 94,576 | 0.99 |
| `mlp_train` | 525,943 | 542,542 | 8.92 |

## Cases

- `fma_chain1` (micro): 1 independent FP32 FMA chain(s) per thread, unroll 4
- `fma_chain2` (micro): 2 independent FP32 FMA chain(s) per thread, unroll 4
- `fma_chain4` (micro): 4 independent FP32 FMA chain(s) per thread, unroll 4
- `fma_chain8` (micro): 8 independent FP32 FMA chain(s) per thread, unroll 4
- `add_chain1` (micro): 1 independent integer ADD chain(s) per thread, unroll 4
- `add_chain4` (micro): 4 independent integer ADD chain(s) per thread, unroll 4
- `div_chain1` (micro): 1 independent integer DIV chain(s) per thread, unroll 1
- `div_chain4` (micro): 4 independent integer DIV chain(s) per thread, unroll 1
- `stream_read_l1` (micro): read 64 words x 16 passes (footprint L1)
- `stream_read_l2` (micro): read 512 words x 4 passes (footprint L2)
- `stream_read_dram` (micro): read 8192 words x 1 passes (footprint DRAM)
- `stream_copy` (micro): b[i] = a[i], n = 2048 (4096 words, > L2)
- `stream_triad` (micro): a[i] = b[i] + s*c[i], n = 2048 (6144 words, > L2)
- `stream_memset` (micro): a[i] = v (stores only), n = 2048 (2048 words, > L2)
- `stride_s1` (micro): warp lanes 1 word(s) apart (L2-resident 1K-word footprint)
- `stride_s2` (micro): warp lanes 2 word(s) apart (L2-resident 1K-word footprint)
- `stride_s4` (micro): warp lanes 4 word(s) apart (L2-resident 1K-word footprint)
- `stride_s8` (micro): warp lanes 8 word(s) apart (L2-resident 1K-word footprint)
- `gather` (micro): out[i] = a[idx[i]], random idx over 4096 words
- `chase_l1` (micro): dependent loads, 8-line random cycle (fits L1)
- `chase_l2` (micro): dependent loads, 128-line random cycle (fits L2)
- `chase_dram` (micro): dependent loads, 2048-line random cycle (fits DRAM)
- `smem_s1` (micro): shared-memory loads, lanes 1 word(s) apart (1-way bank use)
- `smem_s2` (micro): shared-memory loads, lanes 2 word(s) apart (2-way bank use)
- `smem_s4` (micro): shared-memory loads, lanes 4 word(s) apart (4-way bank use)
- `atomic_b1` (micro): ATOM_ADD into 1 bin(s), 32 threads, 2 cores at once
- `atomic_b4` (micro): ATOM_ADD into 4 bin(s), 32 threads, 2 cores at once
- `atomic_b64` (micro): ATOM_ADD into 64 bin(s), 32 threads, 2 cores at once
- `atomic_b1_1core` (micro): ATOM_ADD into 1 bin(s), 16 threads, one block (one core)
- `diverge_m0` (micro): all lanes run a 32-trip loop, the rest wait at the join
- `diverge_m1` (micro): 1/2 of the lanes run a 32-trip loop, the rest wait at the join
- `diverge_m3` (micro): 1/4 of the lanes run a 32-trip loop, the rest wait at the join
- `barrier` (micro): 64 rounds of ADD + SYNC
- `vadd` (app): c = a + b, 192 elements, thread per element
- `matvec` (app): y = W x + b, 64x16, thread per row
- `reduce_sum` (app): per-block sum of 192 values, shared-memory tree
- `dot` (app): x . y, n = 2048: grid-stride FMA + shared-memory tree
- `gemm_naive` (app): C = A B, 12x32x16, every operand from global memory
- `gemm_smem` (app): C = A B, 12x32x16, 4x4 tiles staged in shared memory
- `stencil3` (app): 3-point stencil, n = 1026
- `transpose_naive` (app): 12x16 transpose, strided stores
- `transpose_smem` (app): 12x16 transpose, 4x4 tiles through shared memory, coalesced both ways
- `histogram` (app): 16-bin histogram of 1024 values with ATOM_ADD
- `prefix_scan` (app): per-block inclusive scan of 128 ints (Hillis-Steele)
- `linear_fwd` (app): Y = X W^T + b, batch 32, 16 -> 16, thread per sample
- `mlp_train` (app): fused MLP 2-8-1 training, batch 16, 20 steps
