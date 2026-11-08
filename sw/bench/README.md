# mahi-gpu benchmarks

46 kernels that measure where the GPU spends its cycles. Each runs on the golden model, which supplies the
architectural counts and reference outputs, and on the RTL under Verilator with simulation-only performance probes.
The report explains *why* a kernel takes the cycles it does and flags design limitations.

```bash
python sw/bench/run.py                         # all cases, testbench memory latency 0 and 20  (~15 s)
python sw/bench/run.py --suite micro --lat 0   # micro-benchmarks only
python sw/bench/run.py --cases gemm_naive,gemm_smem
python sw/bench/run.py --profile asic          # other profiles (cases that need 16-thread blocks are skipped)
python sw/bench/run.py --list
python sw/tests/test_bench.py                  # correctness + probe invariants
```

Results go to `sw/bench/results/<date>_<profile>/` (git-ignored): `results.json`, `report.md`, `report.html` (with
charts). The run of record is in [`baseline/fpga/`](baseline/fpga/report.md).

## Pieces

| file | role |
|---|---|
| `rtl/perf_probes.sv` | `bind`-only counters; no RTL change. Built only into `Device('verilator', perf=True)`, which gives `LaunchResult.perf`. |
| `cases.py` | the cases: kernel, inputs, launch, NumPy check |
| `kernels/*.s` | benchmark kernels; the FMA/ADD/DIV chain kernels are generated in `cases.py` |
| `metrics.py` | derived metrics and the bottleneck label |
| `rules.py` | oversight flags: one rule per known limitation, with the hardware change that would remove it |
| `report.py` | `report.md` / `report.html`: findings, oversights, the per-case table, issue-slot breakdown, roofline, latency sensitivity |

The golden model's counts come from `GoldenBackend(count=True)` → `LaunchResult.counts`:
- op mix and FLOPs;
- global, shared and atomic accesses;
- distinct lines touched;
- *ideal* transactions per warp memory instruction, i.e. the distinct 4-word lines its lanes touch.

## What is measured

**Issue slots.** Each core-cycle falls into exactly one bucket, so the buckets sum to the running cycles:

| bucket | meaning |
|---|---|
| `issue` | an instruction issued |
| `mem` | every warp waits on the LSU |
| `serial` | a ready warp is held back by its own serializing instruction (branch, memory, SYNC, FP) still in ID/EX |
| `ll_dep` | the instruction in ID waits for an FMA or divider result |
| `ll` | every warp waits for an FMA or divider result |
| `raw` | register RAW hazard at issue |
| `ifetch` | instruction fetch |
| `barrier` | SYNC |
| `drain` | no live warp |

**Per core:**
- IPC and SIMD efficiency (active lanes per issued instruction);
- ready-warp histogram;
- per-opcode warp and thread instruction counts;
- the 25 events of `core.sv`'s PMU event bus.

**Memory:**
- LSU requests and line transactions, which give the coalescing factor;
- LSU occupancy and queue depth;
- cycles per line read and per line written;
- D$ fills and write-through cycles;
- L2 hits, misses, victims, victim write buffer hits and stalls, end-of-kernel flush cycles;
- external line traffic.

**Other units:** shared-memory bank-conflict cycles, divider busy cycles, atomic cost per lane.

**Derived:**
- FLOP/cycle against the measured and datapath peaks;
- bytes per cycle at the data, L1, L2 and DRAM levels;
- arithmetic intensity, plotted on the roofline;
- exposed share of extra memory latency (the `+lat` sweep).

Ceilings come from the micro-benchmarks:
- FMA, ADD and DIV chains;
- `stream_read` at L1, L2 and DRAM footprints;
- copy, triad and memset;
- `stride_load`, `gather` and `ptr_chase`;
- `smem_stride`, `atomic_hist`, `diverge` and `barrier`.

## Memory beyond the L2

The FPGA profile's L2 holds 1024 words, as large as the default testbench memory. `Device(mem_words=N)` therefore goes
up to 16K words: `tb_random.sv` takes `+dwords=N`, still 1024 by default, and the golden model follows. This lets the
`*_dram` cases and the stream kernels work on data larger than the L2.
