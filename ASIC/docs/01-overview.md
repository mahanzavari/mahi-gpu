# 01 — Overview: what the ASIC variant is

> Verified against commit `dadec7f` (+ uncommitted docs), 2026-10-21.

## What it is
`ASIC/src/rtl/` is a copy of `src/rtl/` (the generic SIMT GPU used for simulation/FPGA) retargeted for a
sky130 ASIC: hard-coded widths replaced by a **profile package** (`include/gpu_pkg.sv`), small size
(1 core, 2 warps × 4 lanes), plus an ASIC top module (`gpu_asic_top.sv`, Wishbone slave). Everything else
(ISA, pipeline, caches) is the same design.

Build profile selection (`ASIC/src/rtl/include/gpu_pkg.sv:27-86`):
`-DTARGET_ASIC=1` → ASIC profile, `-DTARGET_FPGA=1` → FPGA profile, neither → "sim" profile (32-bit
addresses, 2 cores, 4 warps). **`gpu_pkg.sv` must be first on every compile line** (leaf defaults reference it).

## File map and delta against `src/rtl`
Legend: **=** byte-identical to `src/rtl`; **Δ** differs. (Checked with `diff -u src/rtl/X ASIC/src/rtl/X`.)

| File | | Nature of the difference |
|---|---|---|
| `controller.sv`, `core_pmu.sv`, `dcr.sv`, `axi4_adaptor.sv`, `axi_ram.v` | = | not touched (they take widths via instance parameters) |
| `gpu_pkg.sv` (`include/`) | new | profile constants; `WARP_ID_BITS`, `THREADS_PER_CORE`, … |
| `gpu_asic_top.sv` | new | Wishbone slave + DCR/start/done/soft-reset + 4 KB SRAM window (`gpu_mem_subsys.sv`, `mahi_sram.sv` new) → [L3](04-limitations.md#l3) resolved, [L15](04-limitations.md#l15) |
| `gpu.sv`, `core.sv`, `dispatch.sv`, `fetcher.sv`*, `registers.sv`, `icache.sv`, `dcache.sv`, `lsu.sv`, `shared_mem.sv`, `victim_write_buffer.sv`, `gpu_axi4_adaptor.sv`, `decoder.sv` | Δ | parameter defaults → `gpu_pkg::CFG_*`; formatting of instances |
| `alu.sv` | Δ | `DIV`/`MOD` are **stubbed to 0 unless `USE_COMB_DIV`** (`alu.sv:78,90`) → [L2](04-limitations.md#l2); shift-carry index simplified |
| `l2_cache.sv` | Δ | `ev_*` outputs changed `reg`→`wire`, tied to 0 (`l2_cache.sv:333+`) → [L4](04-limitations.md#l4); `$clog2(1)` guards (`PORT_PTR_WIDTH`, `WAY_PTR_WIDTH`) |
| `scheduler.sv` | Δ | latch-avoiding default assignments (`comb_target_a`, `check_w_var`, `will_flush`); `$clog2` guard |
| `pc.sv` | Δ | `$clog2` guard; debug prints under `` `ifndef SYNTHESIS ``. (A port bug that deleted the NZP/CALL/RET state updates was fixed — [B1](05-bug-log.md#b1).) |
| `fp32_fma.sv` | Δ | `$display` under `` `ifndef SYNTHESIS `` only |

\* `fetcher.sv`, `core.sv`, `l2_cache.sv`, `victim_write_buffer.sv` additionally carry the **post-port fixes** B2–B4
(see [05-bug-log](05-bug-log.md)); these fixes are **not** in `src/rtl` ([L10](04-limitations.md#l10)).

Port-era systematic changes (all behaviour-preserving):
1. `$clog2(N)` of a possibly-1 value guarded (`N>1 ? $clog2(N) : 1`) for the 1-core / 1-port ASIC corner.
2. Simulation `$display` blocks wrapped in `` `ifndef SYNTHESIS `` so synthesis ignores them.
3. Lint-driven fixes (latch inference defaults in `scheduler.sv`).

## Debug / verification hooks added to the RTL (all off by default)
| Macro | Where | Effect |
|---|---|---|
| `MEM_TRACE` | `icache.sv`, `l2_cache.sv`, `scheduler.sv`, `core.sv`, `fetcher.sv`, `victim_write_buffer.sv` | detailed event prints (miss/fill, L2 accept/hit/miss, divergence/reconverge, fetch FSM, VWB push/drain) |
| `SHM_TRACE` | `shared_mem.sv` | per-lane shared-memory read/write prints |
| `SYNTHESIS` | everywhere | removes `$display` blocks (the random-regression build defines it to silence the RTL) |
| `USE_COMB_DIV` | `alu.sv` | enable combinational `/` and `%` |
| `src/rtl/sva/*` | bound via `bind_*.sv` | assertions; no RTL edits |

## Repository layout (ASIC part)
```
ASIC/
├── Makefile            verification entry points (see 06-verification)
├── rtl.f               canonical compile order (gpu_pkg first)
├── run_asic.sh / run.sh  sv2v + LibreLane driver (identical copies)
├── flow/config.yaml    LibreLane configuration; flow/runs/ = generated runs (git-ignored)
├── scripts/            isa.py (golden model), gen.py (program generator), rand_regress.py, test_model.py
├── src/rtl/            RTL (+ include/gpu_pkg.sv, sva/; a local verilog-sv2v/ holds untracked legacy artifacts)
├── src/tb/             unit/ (new), ISA/tb_asic_call_ret_branch.sv, random/tb_random.sv, kernels/tb_matmul.sv, legacy dirs
└── docs/               this documentation
```
Legacy testbenches under `src/tb/{AXI4,compute,fault,infant,memory,performance,pipeline,warp}` and
`src/tb/ISA/tb_call_ret_exit.sv` pre-date the block-memory interface and are **not maintained** ([L11](04-limitations.md#l11)).
