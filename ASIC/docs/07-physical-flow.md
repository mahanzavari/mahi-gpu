# 07 — Physical flow (sv2v → Yosys → LibreLane/OpenROAD → GDS)

> Verified against commit `dadec7f` (+ uncommitted docs), 2026-10-21. **Bottom line: the one existing run is stale, incomplete, and not representative.
> Re-run after memory is attached ([L3](04-limitations.md#l3)) before quoting any number from this page.**

## How to run
```bash
cd ASIC
./run_asic.sh -a         # sv2v + quick yosys elaboration/latch audit only
./run_asic.sh -f         # ... through OpenROAD floorplan
./run_asic.sh -r         # ... through detailed routing
./run_asic.sh            # full flow
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
| `VERILOG_FILES` | `dir::../../build/test/gpu_asic_converted.v` |
| `CLOCK_PORT` / `CLOCK_PERIOD` | `clk` / 40.0 ns |
| `FP_SIZING` / `DIE_AREA` / `CORE_AREA` | absolute / [0, 0, 2500, 2500] / [50, 50, 2450, 2450] |
| `PL_TARGET_DENSITY_PCT` | 40 |
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
