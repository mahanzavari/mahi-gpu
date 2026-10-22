# 07 — Physical flow (sv2v → Yosys → LibreLane/OpenROAD → GDS)

> Verified against commit `1d42d45`, 2026-10-22. **Bottom line: with memory attached the design synthesizes, places, CTS-es and globally routes, but there is
> still NO routed/DRC-clean layout, no GDS, no LVS and no final metrics.** The sections "The existing run" below describe the *old, memory-less* run
> from 2026-10-19 and are kept only as history; the numbers that matter are in "Attempts since memory was attached".

## How to run
```bash
cd ASIC
./run_asic.sh -a         # sv2v + quick yosys elaboration/latch audit only
./run_asic.sh -f         # ... through OpenROAD floorplan
./run_asic.sh -r         # ... through detailed routing
./run_asic.sh            # full flow
./run_asic.sh -R         # resume from global routing in the newest run dir
./run_asic.sh -D         # resume from detailed routing in the newest run dir
./run_asic.sh -P RUN_DIR # re-run placement onward (new run dir) from RUN_DIR's pre-placement state
./run_asic.sh -F RUN_DIR # re-run floorplan onward (e.g. new die) from RUN_DIR's synthesis
./run_asic.sh --clean    # delete build/ and flow/runs (destructive)
```
`run.sh` is a byte-identical copy of `run_asic.sh`. Requirements: `sv2v`, `yosys` on PATH; LibreLane virtualenv at
`$HOME/eda/librelane/.venv` (`run_asic.sh:VENV_PATH`); LibreLane is invoked `--dockerized` (Docker needed).

Stages (`run_asic.sh`):
1. `sv2v -DSYNTHESIS -DTARGET_ASIC=1 -I src/rtl/include src/rtl/include/gpu_pkg.sv src/rtl/*.sv -w ../build/test/gpu_asic_converted.v`
   (the glob takes every top-level `.sv`, **not** the `sva/` subfolder; `SYNTHESIS` removes debug prints).
2. Yosys audit: `hierarchy -check -top gpu_asic_top; proc; opt; memory; …; select -assert-none t:$_DLATCH_*` (zero latches).
3. `librelane --dockerized [--to OpenROAD.<stage>] flow/config.yaml`.

## Configuration (`flow/config.yaml`)
<!-- BEGIN GENERATED: flowcfg -->
| Key | Value |
|---|---|
| `DESIGN_NAME` | `gpu_asic_top` |
| `VERILOG_FILES` | `gpu_inst.unified_cache.data_eng.g_sram.sram.macro vccd1 vssd1 vccd1 vssd1` |
| `CLOCK_PORT` / `CLOCK_PERIOD` | `clk` / 40.0 ns |
| `FP_SIZING` / `DIE_AREA` / `CORE_AREA` | absolute / [0, 0, 3000, 3000] / [50, 50, 2950, 2950] |
| `PL_TARGET_DENSITY_PCT` | 30 |
| `PDK` | `sky130A` |
<!-- END GENERATED: flowcfg -->
Everything else is a LibreLane default (CTS on, linter on). There is **no** SDC/IO-constraint file and **no** macros (no SRAM).

## The existing run: `flow/runs/RUN_2026-10-19_14-54-17` (git-ignored; `flow/runs` is in `.gitignore`)
Status of the run:
- Built from commit `a1d47e0` RTL, i.e. **before** all four fixes — including the dead NZP/CALL/RET logic ([B1](05-bug-log.md#b1)).
- **Incomplete.** The log ends inside step `64-magic-drc` (no `final/` directory, no `state_out.json` for that step; Magic was
  still walking ~1.27 M instances when it stopped, `magic-drc.log`). Steps after it (KLayout DRC, illegal-overlap check, **LVS**,
  final metrics) never ran. The commit message "Librelane ran successfully" is therefore not accurate.
- The numbers below are from the last completed step's `state_out.json` (`metrics`).

| Metric | Value | Comment |
|---|---|---|
| Yosys cells / area | 3,162 / 38,657 µm² (`06-yosys-synthesis/reports/stat.rpt`) | tiny — see below |
| Flip-flops (`dfxtp_2`) | **854** | register files alone need ≥ 8,192 (2 warps × 32 × 32 b × 4 lanes) |
| Std cells after PnR (incl. tap) | 86,537 (`stdcell` class, 154,364 µm²); fill 1,545,744 | die 6.25 mm², cell utilisation ≈ 2.5 % |
| Setup WS (worst corner `max_ss_100C_1v60`) | +19.17 ns at 40 ns clock | meaningless until the design is real |
| Hold WS (worst `min_ff_n40C_1v95`) | +0.105 ns | |
| Route DRC errors / antenna violations | 0 / 0 (TritonRoute iterations: 4, 0, 120, 5, 0) | |
| IR drop (worst / avg) | 0.15 mV / 0.61 µV | |
| Power (vectorless) | 1.78 mW | meaningless |
| KLayout XOR (Magic vs KLayout stream-out) | clear | |

**Why the design is nearly empty (hypothesis, evidence-based but not proven).** `gpu_asic_top` leaves every memory *output* of
`gpu` unconnected and ties every memory *input* to constants ([L3](04-limitations.md#l3)); the only observable outputs are
`wb_dat_o`, `wb_ack_o`, `gpu_done_pin`. Yosys therefore keeps only logic that can influence those, and constant instruction data
lets most of the datapath fold away (854 flops vs ≥ 16 k state bits for registers + caches). To confirm, count flops/hierarchy after
attaching a memory model; or run `yosys … stat` before `opt` on `build/test/gpu_asic_converted.v`.

## Attempts since memory was attached (2026-10-21/22)
All runs use the netlist of the then-current RTL (`gpu_asic_top` + SRAM macros) and 40 ns clock. Evidence is in each run's logs under `flow/runs/` (git-ignored); the
failed first global-routing log is kept in `flow/failed_logs/`.

| Run | Design | Result |
|---|---|---|
| `RUN_2026-10-21_10-58-33` | 2 OpenRAM macros (PMEM/DMEM windows), die 2.5 mm; 175,640 instances, **31,818 flops** (was 854 before memory), 2.70 mm² | Timing repair after CTS took ~5 h (−9.2 ns setup at the slow corner, ~24k gates resized). Global routing with `GRT_ADJUSTMENT 0.3` ended with **71,864 overflow** after 50 extra iterations (~7 h). |
| same run, resumed | `GRT_ADJUSTMENT 0.15` | Overflow 0 with 40 iterations, global route 4 min. 4,027 nets violate antenna rules; OpenROAD's GRT antenna repair crashes (`GRT-0183`, net34287) so it is disabled (`RUN_ANTENNA_REPAIR: false`). **Detailed routing was OOM-killed by the kernel twice** (11.0 and 11.1 GB resident on a 16 GB host), 8 vs ~17 threads made no difference. |
| `RUN_2026-10-22_07-31-46` | 3 macros (L2 data array moved into SRAM, `l2_data_array.sv`); 151,502 instances, 24,269 flops, 1.80 mm² cells + 0.85 mm² macros | Timing repair converged quickly; global route overflow 280. Detailed routing: pass 0 **223,731 violations**, pass 1 **139,474**, ~35 min/pass, 11.07/11.34 GB; stopped by the user in pass 2. |

**Violation breakdown (detailed routing log, same run):** met1 shorts 137,622 → 101,063 (61% → 72% of all violations), met2 shorts 35,155 → 18,483, met1 spacing 24,867 → 13,974;
met4+met5 (the macro-pin layers) ~1% → 0.2%. So the SRAM macros are not the problem; it is local pin access in dense standard-cell regions (global routing layer usage was only 57% met1 / 66% met2).

**Placement density:** `PL_TARGET_DENSITY_PCT` below ~44% had no effect on the 2.5 mm die. The placer reports "target density too low for the available free area" and raises it
(0.40 → 0.44; 0.28 → 0.44). Cells (1.88 mm², of which 0.09 mm² are tap cells, plus 0.24 mm² virtual pin-density area) need that much of the ~4.3 mm² placeable area.
Lowering density therefore needs a bigger die: the current config uses a 3.0 mm die (core 2.9 mm), where the placer honours 0.30. That run (`floor_*` run dir) was in progress when this page was written;
its detailed-routing result is **not** recorded here.

Other effects measured: the gate-level netlist is correct (200-seed zero-delay GLS, see [06](06-verification.md)); area barely changed by the L2 macro (−2%) but cells −14% and flops −24%.

## Not done (sign-off gaps)
| Item | Status |
|---|---|
| Complete the flow (Magic/KLayout DRC, LVS, final metrics) | not completed |
| Gate-level simulation (post-synthesis, post-route + SDF) | not done (SDFs exist: `55-openroad-stapostpnr/*/*.sdf`) |
| RTL ↔ netlist equivalence | not done |
| IO constraints / SDC review, multi-corner timing sign-off on the real design | not done |
| Re-run on current RTL with memory attached | not done |
| SRAM macros (OpenRAM) for caches/register file | not decided |
See [08-todo](08-todo-and-open-questions.md).
