# 04 — Limitation register

> Verified against commit `dadec7f` (+ uncommitted docs), 2026-10-21. A *limitation* is behaviour that is a design choice, a missing feature, or
> a verification blind spot — as opposed to the *fixed bugs* in [05-bug-log](05-bug-log.md).
> Entries marked **[exec]** have an executable characterization test (`make limits`, script `scripts/limits.py`) that
> **passes while the limitation exists and fails if it is fixed** — a failure there means *update this page*.
> Entries marked **[static]** are checked by `make docs-check` (text/RTL pattern). Severity: **H** can silently give wrong
> results or blocks use; **M** surprising but contained; **L** inconvenience.

| ID | Title | Sev | Check |
|---|---|---|---|
| [L1](#l1) | No join-point reconvergence → `SYNC` unsafe after divergence | **H** | exec |
| [L2](#l2) | `DIV`/`MOD` return 0 unless `USE_COMB_DIV` | M | exec (`unit-alu-stub`) |
| [L3](#l3) | ~~`gpu_asic_top` has no memory~~ — **resolved**: 2×2 KB SRAM window | — | static |
| [L4](#l4) | L2 PMU events hard-wired to 0 | L | static |
| [L5](#l5) | `CMP` is unsigned; NZP resets to 0 | M | exec |
| [L6](#l6) | Call stack 8 deep, wraps silently | M | exec |
| [L7](#l7) | Divergence stack 4 deep | L | SVA |
| [L8](#l8) | FP: truncation, flush-to-zero, no Inf/NaN, alignment quirk | M | exec |
| [L9](#l9) | Atomics: `CAS`, ordering and multi-core untested | M | — |
| [L10](#l10) | Fixes B2–B4 exist only in `ASIC/src/rtl` | M | static |
| [L11](#l11) | Tooling/legacy test debt | L | — |
| [L12](#l12) | Faults (div0, bad address) are invisible outside the core | **H** | exec |
| [L13](#l13) | PMU/DCR registers unreachable from chip pins | L | static |
| [L14](#l14) | Global addresses above the 14-bit bus alias silently | M | exec |
| [L15](#l15) | On-chip memory is only 512 + 512 words; out-of-range GPU accesses read 0 / are dropped | M | exec (chip TB) |
| [L16](#l16) | Host cannot touch memory while running; re-running needs a soft reset | M | exec (chip TB) |
| [L17](#l17) | SRAM macro timing is TT-only in every STA corner | M | static |

---
## L1
**No join-point reconvergence → `SYNC` is unsafe after divergence.**
- **Symptom.** After a divergent branch the lanes of a warp finish the remaining program one *group* at a time. A `SYNC`
  placed after the divergent region (even at the top level of the source) executes once per group and the first group to
  arrive counts as "this warp arrived", so it can pass the barrier before other lanes/warps have done their work.
- **Root cause.** `scheduler.sv` pushes the not-taken group on a 4-entry stack at a divergent branch (`scheduler.sv:238-241`) and only
  pops it when (a) `EXIT` executes (`scheduler.sv:229-234`) or (b) a later non-divergent branch targets exactly the stacked PC
  (`is_reconverge`, `scheduler.sv:247-254`). There is no reconvergence at the join/post-dominator, so merging almost never happens.
  `SYNC` only counts *warps* (`barrier_count >= num_active_warps_comb`, `scheduler.sv:272`), not lanes.
  The same logic is in `src/rtl/scheduler.sv` (checked by diff, only trace prints differ).
- **Evidence.** Random-regression seed 76 (shared-memory program): the final readout executed lane by lane — lane 0 finished
  at t≈24,900 ns, lane 1 ≈45,700, lane 2 ≈67,600, lane 3 ≈90,300 — while other lanes' stores were still pending; 18/240
  seeds failed before the generator was made warp-uniform. Reproduced by `make limits` (case `L1`).
- **Impact.** Any kernel using `SYNC` (reductions, shared-memory tiling) with data-dependent control flow before it can
  read stale shared memory. Also an efficiency issue: the program tail runs once per lane group.
- **Workaround.** Make all control flow before every `SYNC` warp-uniform (conditions/loop counts derived from block/warp
  constants). The random generator does this in "uniform mode" (`scripts/gen.py`). Divergence *without* barriers is fine
  (covered by unit, system and random tests).
- **Fix options.** Reconverge at the immediate post-dominator (compiler-inserted join point or hardware stack
  with a join PC); or make `SYNC` wait for an all-lanes mask. Not started.

## L2
**`DIV`/`MOD` return 0 unless built with `USE_COMB_DIV`** (`alu.sv:78-95`; comment: "division stubbed or delegated to
software" for area/timing). `rt==0` still raises the fault flag. Kernels needing integer division (e.g. `matmul`) must be
simulated with `-DUSE_COMB_DIV=1` (`make verify-matmul` does). Not part of the synthesized default.
Check: `make unit-alu` (with) and `make unit-alu-stub` (without) assert both behaviours. Gate-level confirmation: the synthesized netlist returns 0 for DIV/MOD (`make gls` needs `MAHI_NO_DIV=1` in the golden model; without it 28 of the first 40 seeds mismatch).

## L3
**RESOLVED — `gpu_asic_top` now has memory.** It used to tie off every memory port (no program could be loaded; synthesis kept
854 flops). The top now decodes `0x3000_1000–0x3000_1FFF` onto two OpenRAM `sky130_sram_2kbyte_1rw1r_32x512_8` macros through
`gpu_mem_subsys.sv` and connects the GPU's program/data channels to them. Proof: `make top-quick` (random programs loaded,
run and read back purely over Wishbone, golden-model compared) and the synthesised flop count in
[07-physical-flow](07-physical-flow.md). The entry stays as history; remaining consequences are L15–L17.

## L4
**L2 `ev_*` PMU outputs are constants 0** (`l2_cache.sv:333-340`). They were already undriven regs in `src/rtl`; the port made
it explicit. L2 hit/miss counters in the PMU therefore read 0. L1 (I/D cache) events are real.

## L5
**`CMP` is unsigned; NZP resets to 0.** `alu.sv:53` computes `{rs<rt, rs==rt, rs>rt}` on unsigned operands, so
`CMP(-1, 1)` reports *greater*. NZP is 0 at reset (`pc.sv`), so a `BRnzp` executed before any `CMP` falls through even with
mask `111`; "unconditional" jumps need a preceding `CMP`. Exec check: `make limits` case `L5`.

## L6
**Call stack is 8 deep and wraps silently.** `pc.sv:29-33`: 8 entries, 3-bit pointer, no overflow/underflow detection.
The 9th nested `CALL` overwrites the oldest return address; unwinding then returns to the wrong place (or hangs).
`RET` on an empty stack reads a stale entry. Exec check: `make limits` case `L6`. No assertion covers it (open item).

## L7
**Divergence stack is 4 deep** (`scheduler.sv:57`). With 4 lanes per warp the maximum nesting is 3, so it cannot overflow in the
ASIC profile; a profile with `THREADS_PER_BLOCK` ≥ 6 can (the sim profile used by `tb_matmul` has 8 lanes and was not seen to
overflow). SVA `sched_sva.a_depth` flags `stack_ptr > 4`.

## L8
**Floating point is not IEEE-754.** `fp32_fma.sv`: no rounding (truncation), denormal inputs read as 0 and tiny results
flush to ±0, exponent 255 is treated as an ordinary number (no NaN/Inf; overflow produces an Inf *encoding*).
Alignment quirk: the product's exponent is computed even when an operand is zero, so `0 × 2¹²⁷ + c` shifts `c` right by
the exponent difference and **drops low bits of `c`** (e.g. `0x219e0651 → 0x219e0000`). `isa.py:fma_bits` is a bit-exact port
(unit test `tb_fp32_fma` checks against a double-precision reference with tolerance; random regression checks bit-exact
agreement with the port). Exec check: `make limits` case `L8`.

## L9
**Atomics.** `ATOM_ADD` final sums are validated under divergence and across warps; the *returned old value* is order dependent
and not checked. `ATOM_CAS` is not covered by any random or directed test. Everything is single-core; multi-core coherence
(L1 write-through, shared L2) is exercised only by `verify-matmul`.

## L10
**Fixes B2 (ID-latch), B3 (fetcher PC match), B4 (L2/VWB push gating) are only in `ASIC/src/rtl`.** By inspection `src/rtl/core.sv:110`,
`src/rtl/l2_cache.sv:193,229` still contain the buggy forms and `src/rtl/fetcher.sv` has no PC check (not run on `src/rtl`). Its
`pc.sv` is not affected by B1. Static check: `docs-check` fails when the patterns change, to prompt updating this entry.

## L11
**Tooling/test debt.** `tb_matmul` completes under Verilator but **times out under iverilog**; the old `make sim` target is
not part of `verify`. Testbenches in `src/tb/{AXI4,compute,fault,infant,memory,performance,pipeline,warp}` and
`ISA/tb_call_ret_exit.sv` use a pre-block-interface memory model and do not build against the current `gpu` ports
(`tb_call_ret_exit` fails with "Element types are not compatible"). Lint waives 10 warning classes (`Makefile LINT_WAIVE`).
Verilator pitfalls are listed in [06-verification](06-verification.md).

## L12
**Faults are invisible outside the core.** Division by zero and out-of-range addresses set `ex_exception_valid`; the scheduler
marks the warp `FAULTED` and flushes it (`scheduler.sv:205-209`), and `FAULTED` counts as finished for `done`
(`scheduler.sv:285`). `core.sv` exposes `exception_*` outputs but `gpu.sv` never connects them. A faulting kernel therefore **completes
with `done` high and silently missing results**. Exec check: `make limits` case `L12`.

## L13
**PMU/DCR registers are unreachable from the chip pins.** `gpu_asic_top` always drives `device_control_address = 0`
(`gpu_asic_top.sv`: `dcr_addr` only assigned `8'h00`) and leaves `pmu_snap_*` unconnected, so PMU configuration
(DCR 0x01/0x02/0x10-0x13) and snapshots cannot be used on the chip.

## L14
**Global addresses above the 14-bit data bus alias silently.** The core's fault check compares the full 32-bit effective address with
`MAX_MEM_ADDR = 0xFFFF` (`core.sv:13,365`), but the LSU truncates the address to `DATA_MEM_ADDR_BITS` = 14 (`lsu.sv:82`).
An access to `0x4000…0xFFFF` is therefore neither faulted nor reaching that address: it wraps onto `addr & 0x3FFF`
(e.g. a store to `0x412C` lands at word 300). Exec check: `make limits` case `L14`. Fix: set `MAX_MEM_ADDR` from the profile
(`(1<<DATA_MEM_ADDR_BITS)-1`).

## L15
**Only 512 program words and 512 data words exist on chip.** PMEM = GPU instruction words 0..511, DMEM = GPU data words 0..511
(`gpu_mem_subsys.sv`: block address ≥ 128 is out of range). Out-of-range instruction fetches return zeros; out-of-range data
loads return 0 and stores are dropped, setting the sticky `STATUS[2]` (`gpu_oob`) flag (data side only). The ISA/`gpu_pkg` still
advertise 4K program / 16K data words. Consequence for tests: the random generator runs with `GEN_STRIDE=32` at chip level
(private region 256..511), and programs must be ≤ 512 words. Check: chip TB asserts `gpu_oob == 0` for in-range kernels.

## L16
**Host memory access is exclusive with GPU activity; re-running needs a soft reset.** While `STATUS.busy` the window answers every
access immediately with `0xBAD0_BAD0` (reads) / nothing (writes) and sets `STATUS[3]` (`host_blocked`). After a run the L1/L2/I-caches
are flushed but **not invalidated**, so a second kernel (or new data) would read stale cache lines; the host must write
`CTRL[1]=1` (soft reset: clears DCR, scheduler, caches; SRAM contents survive) before reloading. `top-quick` runs two different
programs per seed with a soft reset in between and matches the model for both.

## L17
**Macro timing is typical-corner only.** OpenRAM produced a single `TT_1p8V_25C` liberty file; `config.yaml` maps it to all nine
STA corners (`lib: "*"`). SS/FF slack involving the SRAM pins is therefore not trustworthy; the SRAM clock-to-Q is also only
modelled at one corner. Re-characterise (OpenRAM `-c corners`) before sign-off.
