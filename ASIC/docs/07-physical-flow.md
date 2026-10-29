# 07 — Physical flow (sv2v → Yosys → LibreLane/OpenROAD → GDS)

> Verified against commit `fd2b68f`, 2026-10-29. **Bottom line: the mini profile (`MINI=1`) has a routed layout at 40 ns that passes routing DRC 0, antenna 0, LVS 0, KLayout DRC 0, full-chip Magic DRC with 0 integration errors,
> setup >= +3.27 ns and hold >= +0.27 ns in all 9 corners, now with per-corner SRAM timing: `flow/runs/place_1029_1604`** (the earlier `place_1027_2317` used a typical-corner SRAM library that was 4.7x too fast).
> See "Phase 2 closure" and "SRAM per-corner timing". Open: the SRAM `dout1` nets exceed the macro's own 27.6 fF cap limit (waiver `flow/waivers/sram_dout_cap_slew.md`), cap/fanout violations, black-box macro LVS,
> no gate-level simulation of this netlist, and the full-size profile has never been routed. The older sections are the history of how we got here and quote the run they were measured on.

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
| `VERILOG_FILES` | `dir::../../build/test/gpu_asic_converted.v` |
| `CLOCK_PORT` / `CLOCK_PERIOD` | `clk` / 40.0 ns |
| `FP_SIZING` / `DIE_AREA` / `CORE_AREA` | absolute / [0, 0, 3000, 3000] / [50, 50, 2950, 2950] (the mini profile uses a 2.4 mm die) |
| `PL_TARGET_DENSITY_PCT` | 30 |
| `PDK` | `sky130A` |
| `SYNTH_STRATEGY` | `DELAY 4` |
| `SYNTH_CLK_DRIVING_CELL` | `sky130_fd_sc_hd__clkbuf_16/X` |
| `RUN_POST_GRT_DESIGN_REPAIR` / slew % / cap % / max wire | true / 70 / 70 / 1200 um |
| `PL_RESIZER_HOLD_SLACK_MARGIN` | 0.4 ns |
| `RUN_POST_GRT_RESIZER_TIMING` / `GRT_RESIZER_HOLD_SLACK_MARGIN` | true / 0.4 ns |
| `DRT_ANTENNA_REPAIR_ITERS` / `…_MARGIN` | 8 / 25 % |
| `KLAYOUT_CONFLICT_RESOLUTION` | `OverwriteCell` |
| `ERROR_ON_MAGIC_DRC` | false |
<!-- END GENERATED: flowcfg -->
Everything else is a LibreLane default (CTS on, linter on). The SDC is the one LibreLane generates from these settings (no separate constraint file): 40 ns clock, 0.25 ns uncertainty, 8 ns input and output delays, 5% OCV derate. The three OpenRAM macros and their power connections, the met4 keep-out bands and the other flow settings are in `flow/config.yaml` below this table. `config_mini.yaml` is generated from it by `MINI=1 ./run_asic.sh` (netlist path and the 2.4 mm die only).

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

## Mini profile run (`TARGET_ASIC_MINI`, `flow/runs/floor_1022_1610`, 2026-10-22)
`MINI=1 ./run_asic.sh` builds a half-size design (2 lanes x 2 warps, shared memory 32 words, L1 8 lines, victim buffer 2; `gpu_pkg.sv`). Synthesis: **79,657 instances, 14,390 flops, 0.96 mm² cells**
(full profile: 151,502 / 24,269 / 1.80 mm²). Die 2.4 mm, placement density 0.30 (honoured; no override), 40 ns clock. First run that got through detailed routing and stream-out on a 16 GB host:

| Step | Result |
|---|---|
| Detailed routing | 76,392 → 39,382 → 36,940 → 3,181 → 94 → 27 → 14 violations in 41 min (peak 7.1 GB). After the router's antenna-repair passes: **53 violations**, all met4 (51 spacing, 2 shorts) next to the SRAM macro pins (`mem_inst.d_dout1[*]` vs VPWR near the DMEM macro's top edge). None in standard-cell logic. |
| Antenna | ~4,000 violating nets before routing repair → 2 nets |
| Post-route STA, 9 corners | hold met everywhere (worst +0.047 ns, max_ff); setup met at TT (+15.1 ns) and FF (+17.0 ns) but **fails at SS: worst -9.27 ns (max_ss_100C_1v60), 817 endpoints, TNS -1190 ns**. The OpenROAD resizer optimises one corner, so 40 ns closes at TT only; SS needs roughly 50 ns. Max-slew violations 48,540, max-cap 991 (counts across corners) |
| IR drop / power | 0.28 mV worst drop; total 41 mW (nominal) |
| Magic DRC | 12,984,273 raw error boxes, of which **12,984,243 (99.9998%) lie inside the three OpenRAM macros** and 30 are outside (all `met4.2` spacing, same macro-adjacent area). The OpenRAM macros are not clean under Magic's sky130 deck; they need waivers or a macro-aware deck, not a logic fix |
| KLayout XOR (Magic vs KLayout GDS) | 10,814,649 differences (deferred); not yet attributed, suspected macro handling since the memory-less run was XOR-clean |
| KLayout render and KLayout DRC | **abort**: the Magic GDS has 13 top-level cells (unreferenced OpenRAM sub-cells), KLayout wants one. The KLayout-written GDS has a single top cell |
| LVS, final timing checkers | not reached |

Next: set the clock for the SS corner (~50-52 ns), keep met4 straps away from the macro pins (macro halo / PDN settings), post-process the Magic GDS to one top cell (or run KLayout DRC on the KLayout GDS), provide macro SPICE for LVS, and decide how to treat OpenRAM macro DRC (waiver).

## OpenRAM macros in signoff: what is intrinsic and what is ours (2026-10-22)
Measured on `floor_1022_1610`, before changing anything:
- **KLayout XOR (Magic vs KLayout GDS): all 10,814,649 differences lie inside the three macro boxes; none outside.** The standard cells and routing are identical between the two stream-outs; only how each tool writes the macro content differs.
- **Magic DRC of the macro alone** (`make macro-drc`; Magic 8.3.623, `drc(full)`): 5,579,811 boxes, 32 rule types (largest: diff/tap.9 N-diffusion to N-well spacing, li.1 local-interconnect width, licon.8, poly.8, diff/tap.1, licon.5a).
  In the chip the same rules fire with the same proportions (about 0.78x the standalone count per rule; Magic counts hierarchical errors per placement, so the absolute totals are not directly comparable). The rule list is committed in
  `flow/waivers/openram_2kb_macro_drc_rules.txt`.
- **Integration errors = the only rule that fires in the chip but not on the macro alone: Metal4 spacing < 60 (met4.2), 34 raw boxes, all at macro boundaries** (`make drc-waiver RUN=...`, `scripts/drc_waiver.py`;
  waives a box only if its rule is in the macro list AND it lies inside a macro box). This is the same met4 problem the router reports (53 violations: macro data pins vs VPWR).
- The macro-intrinsic errors still make the chip not "DRC clean" under Magic's deck: whether a shuttle accepts OpenRAM sky130 macros with these errors is a question for the shuttle operator, not something this repo can settle.

## The met4 boundary errors: cause and fix (2026-10-22/23)
**Cause (measured, not assumed).** The macros' signal pins are 0.38 x 1.06 um met4 rectangles on the top/bottom edges (35 on top, 72 on bottom, 5.44 um pitch) and the router reaches them with ~7 um met4 stubs.
The power grid's vertical met4 straps (VPWR/VGND pairs, 1.6 um wide, 1.7 um apart, every 153.6 um) ran **right up to the macro edge** and some stubs ended 0.12 um from a strap (met4.2 needs 0.30 um).
That is all 53 router violations (51 spacing + 2 shorts, on `d_dout1`, `p_dout1`, `din0` nets vs VPWR/VGND) and the 34 Magic met4.2 boxes. `PDN_*_HALO`/`FP_MACRO_*_HALO` = 10 um did not prevent it.
**Shifting the macros cannot fix it:** with pins spanning ~510 um (top) and ~540 um (bottom) and a 153.6 um strap pitch, 3-4 strap pairs always fall among pins that are 5.44 um apart (a pair plus clearance needs ~6.3 um); a sweep of macro x-origins found none that clears every pin.
**Fix:** `PDN_OBSTRUCTIONS` in `flow/config.yaml` - 12 um met4 keep-out bands above and below each macro (only while the PDN is generated). Dry run (`TO_STEP=Odb.RemovePDNObstructions MINI=1 ./run_asic.sh -F <run>`):
strap ends moved from exactly the macro edge to 12.3 um away on all six pin edges (e.g. 496.5 -> 508.8, 1016.5 -> 1028.8, 600 -> 587.7); straps in the 103 um channels between macros remain (79 um long). Whether this clears the router/Magic errors is **not yet verified** (needs the full run).

## Mini profile: closure run (`flow/runs/d4_full`, 2026-10-23) - setup, hold, DRC and LVS clean
Changes against the earlier mini run (`floor_1022_1610`), each found from evidence: (1) **`PDN_MACRO_CONNECTIONS` named the wrong design nets** (`vccd1 vssd1`; this design's are `VPWR VGND`), so all three macros were *unpowered* in the layout
(`PDN-0231` warning in every run since the macros were added; LVS: 4 macro power nets unmatched). Fixed: `<inst> VPWR VGND vccd1 vssd1`; the grid now has vias inside each macro (8/12/12). (2) 12 um met4 PDN keep-out bands at the macro pin edges (previous section).
(3) **`SYNTH_STRATEGY: "DELAY 4"`** (was `AREA 0`): pre-placement STA of the five DELAY netlists at the 40 ns clock gave -173..-196 ns (DELAY 0-3, unbuffered) vs +12.4 ns at the slow corner for DELAY 4 (AREA 0: -63.6 ns); DELAY 4 costs +7.8% area, +14.6% cells (91,300 vs 79,657).
Clock stays **40 ns**. Tried and reverted: banning delay cells (`EXTRA_EXCLUDED_CELLS`) made slow-corner setup worse (-9.27 -> -10.82 ns) and broke hold (45 violations).

| Check | Result |
|---|---|
| Detailed routing | 9,812 -> 655 -> 104 -> **0** violations in 4 passes (55 min incl. antenna repair, ~8.7 GB) |
| Antenna | 2 nets / 2 pins |
| Setup, 9 corners | **all pass**, worst +4.07 ns (max_ss_100C_1v60); typical +15.5, fast +16.7 |
| Hold, 9 corners | **all pass**, worst +0.025 ns (max_ff_n40C_1v95) - little margin |
| LVS (macros as black boxes) | **0 errors** (was 5) |
| Magic DRC on the Magic GDS that contains the macros (`scripts/macro_drc.tcl`) | 12,986,123 raw boxes, all inside macros and all in rules that also fire on the standalone OpenRAM macro; **0 integration errors** (`scripts/drc_waiver.py`) |
| Flow's own Magic / KLayout DRC | 0 / 0, **but vacuous for the macros**: they read the KLayout GDS, in which the macros are empty cells (0 shapes). The flow's Magic-GDS is the one with macro content (301 cells, 13 top-level cells) |
| KLayout XOR | 10.8M differences = exactly the missing macro content in the KLayout GDS (all inside macro boxes); not a layout error |
| IR drop / power | 0.5 mV worst / 38 mW |

**Still open:**
- **Max-slew / max-cap / max-fanout violations** in the post-route STA (the flow's own checkers fail them in the min/max RC corners and ignore the nominal ones): `MAX_TRANSITION_CONSTRAINT` is 0.75 ns; at the slow corner 30,058 pins exceed it (9,118 > 1.0 ns, 1,135 > 1.5 ns, 298 > 2.0 ns; worst is the clock-root buffer input at 2.8 ns), 4,138 at typical, 572 at fast; 618 cap and 369 fanout violations.
  60 of the slew violators are macro address pins with a 0.04 ns limit in the OpenRAM liberty (an artifact). The resizer repairs at the nominal corner only.
- The deliverable GDS with macros is `final/mag_gds` (Magic's); `final/gds` (KLayout's) lacks the macro layout. Macro internals are not LVS-checked (black box) and the macro SPICE/timing views are typical-corner only (L17).
- Not done: post-route gate-level simulation with the SDF, RTL-vs-netlist equivalence, a full-size (non-mini) run, whether a shuttle accepts the macro DRC waiver, margin on hold.

## Slew / cap clean-up, experiment A (`flow/runs/slew_a`, 2026-10-24)
**Why the violations exist.** Placement-stage repair and the post-CTS timing repair work on the typical corner with pre-route wire estimates; after routing the same pins are seen at 9 corners. Post-route slew violations at `d4_full`:
nominal typical 2,581, nominal slow 24,576, worst (max RC, slow) 30,058, against the flow's `MAX_TRANSITION_CONSTRAINT` of **0.75 ns** (the library's own limit is 1.5 ns, which is only exceeded by 1,135 pins at the worst corner).
Cap violations (618) are mild (median 1.24x the cell limit), fanout (369, limit 10) median 12.
**Experiment.** Resume `d4_full` at global routing with `RUN_POST_GRT_DESIGN_REPAIR: true`, `GRT_DESIGN_REPAIR_MAX_SLEW_PCT: 55`, `GRT_DESIGN_REPAIR_MAX_CAP_PCT: 40` (repair with real route estimates, limits tightened so the typical-corner target is 0.34 ns), stop after post-route STA.
The repair found 10,479 slew / 248 cap violations, resized 4,261 cells and inserted 1,946 buffers; detailed routing then converged to 0 violations (61 -> 3 -> 3 -> 0).

| | baseline `d4_full` | experiment A |
|---|---|---|
| Routing DRC / antenna nets | 0 / 2 | 0 / 3 |
| Setup worst / hold worst (ns) | +4.07 / +0.025 | +4.58 / +0.035 |
| Slew violations: worst corner / nominal slow / nominal typical | 30,058 / 24,576 / 2,581 | 17,958 / 12,829 / 1,351 |
| Slow-corner pins > 1.0 / > 1.5 / > 2.0 ns | 9,118 / 1,135 / 298 | 4,102 / 428 / 125 |
| Cap / fanout violations | 618 / 369 | 576 / 382 |

Of the 428 remaining slow-corner pins beyond the library range, 280 are antenna-diode pins (they carry their net's slew), 146 are logic pins and 2 are the clock-root buffer inputs (2.8 ns; the `clk` port net is also 0.384 pF against a 0.2 pF limit).
**Takeaway:** margins halve the slew violations without hurting routing or timing, but the repair still targets one corner, so clearing the slow corner against 0.75 ns needs a much larger margin (the slow corner is ~2.4x slower), more buffers, or judging it against the 1.5 ns library limit.
Not re-run for this experiment: LVS and DRC signoff (the netlist changed by ~1.9k buffers). The committed `flow/config.yaml` is unchanged.

## Phase 2 closure (`flow/runs/place_1027_2317`, 2026-10-27/28) - the mini layout passes every signoff check available here
Three routed runs took the mini layout from `d4_full` to this state; all use the RTL with the divider, the fault registers and the `SYNC` rule ([04-limitations](04-limitations.md) L1, L2, L12).
Runs 2 and 3 started at global placement from the previous run (`./run_asic.sh -P <run>`), about 3 h each.

| Run | What changed | Result |
|---|---|---|
| 1 `mini_1027_0945` | whole flow: clock source modelled as `clkbuf_16`, post-routing slew/cap repair (margins 70/55), post-CTS hold margin 0.25 ns, antenna repair 5 rounds at 25%, `KLAYOUT_CONFLICT_RESOLUTION: OverwriteCell`, Magic DRC non-fatal | antenna 0, XOR 0, routing DRC 0; slew 30,058 -> 6,576; hold unchanged at +0.027 ns; cap/fanout up (717/577); 162 pins above 2 ns |
| 2 `place_1027_1754` | hold margin 0.4 ns, `GRT_DESIGN_REPAIR_MAX_WIRE_LENGTH: 1200`, cap margin 70% | no pin above 2 ns (worst 1.92 ns); hold still +0.032 ns; ended with 1 routing DRC error and 1 antenna net |
| 3 `place_1027_2317` | `RUN_POST_GRT_RESIZER_TIMING` with `GRT_RESIZER_HOLD_SLACK_MARGIN: 0.4`; antenna repair up to 8 rounds | hold +0.265 ns; routing DRC 0, antenna 0 |

| Check | Final layout | `d4_full` |
|---|---|---|
| Routing DRC / antenna nets | 0 / 0 | 0 / 2 |
| LVS (macros as black boxes) | 0 errors | 0 |
| KLayout XOR, Magic vs KLayout GDS | 0 differences | 10,813,574 |
| KLayout DRC (the GDS now contains the SRAM layout) | 0 | 0, but the macros were empty |
| Magic DRC, full chip, `make signoff-drc RUN=...` | 12,984,239 boxes, all inside the macros and in rules the standalone macro also violates; **0 integration errors** | same |
| Setup, worst of 9 corners | +3.30 ns (max_ss) | +4.07 ns |
| Hold, worst of 9 corners | +0.265 ns (max_ff) | +0.025 ns |
| Slew violations, slow corner (max_ss) | 6,113; none above 2 ns, 69 above 1.5 ns, worst 1.93 ns | 30,058; 298 above 2 ns, 1,135 above 1.5 ns, worst 2.80 ns |
| Clock-root input slew, slow corner | 0.98 ns | 2.80 ns |
| Cap / fanout violations (flow metric) | 670 / 561 | 618 / 369 |
| Standard cells, area | 205,835, 1.61 mm2 | 182,478, 1.37 mm2 |
| Total power (vectorless) | 39.5 mW | 38.2 mW |

The reference layout predates the divider, so part of the area difference is RTL (+3.6% at synthesis); the rest is delay cells for hold, buffers for slew and 7,578 antenna diodes (5,124 before).

**GDS: why the macros were empty (#3).** `stream_out.py` (KLayout stream-out) clears every cell, re-reads the cell GDS files, and with the default conflict policy `RenameCell` the re-read SRAM went into a renamed cell that the top cell does not reference; only the referenced hierarchy is written out.
`KLAYOUT_CONFLICT_RESOLUTION: OverwriteCell` writes it into the referenced cell: the SRAM cell has its 23,029 shapes and 7,357 child instances, the file has one top cell, and the XOR against Magic's GDS is 0.
Verified offline first by replaying the 7 s step on a finished run's DEF (the `RenameCell` replay matched the flow's file byte for byte). Consequence: the flow's Magic DRC now sees the SRAM's own violations, so `ERROR_ON_MAGIC_DRC` is false and the DRC verdict is `make signoff-drc`; KLayout's DRC deck reports 0 on the standalone macro and on the full chip, so its error check stays on.

**Clock root (#5).** The SDC drove `clk` with the same weak `inv_2` model as every data input (`SYNTH_CLK_DRIVING_CELL` unset). `sky130_fd_sc_hd__clkbuf_16/X` models the clock source as a clock buffer (in Caravel it comes from the management SoC's clock network).
Root-buffer input slew at the slow corner 2.80 -> 0.85 / 1.02 / 0.98 ns in the three runs; worst hold-side clock skew 1.08 -> 0.90 / 0.93 / 0.94 ns. The routed `clk` port net is still about 0.36 pF against the flow's blanket 0.2 pF limit (a property of the wire, not of the modelled driver).
This is an input-drive assumption: check it against the real harness before tape-out.

**Slew / cap / fanout (#4).** Post-routing design repair with margins 70/70 cut the slow-corner slew count five-fold. Batch 1 had a new tail (162 pins above 2 ns, one at 5.4 ns), all antenna-diode pins on a few very long nets; the 1,200 um wire-length cap in the repair removed them.
Cap and fanout did not improve: in batch 1, 460 of the cap violators sit on buffers the repair itself inserted (names `wire...`, `max_cap...`), median 1.26x the limit, because the final routed wires are longer than the global-route estimate the repair worked from. Not fixed.
The 60 SRAM address pins with a 0.04 ns max-transition in the OpenRAM liberty always violate; they are a model artifact (see "Not done").

**Hold (#11) - the margin setting was not the lever.** The expectation was that a bigger post-CTS hold margin would lift the fast corner. It did not: margin 0.1 / 0.25 / 0.4 ns gave +0.025 / +0.027 / +0.032 ns at max_ff, and the worst endpoint (`_162047_`, an FPU pipeline register: flop, one hold cell, flop) was the same each time.
Per endpoint the fast corner is 0.158 to 0.379 ns (median 0.311) below the typical corner the repair works at (944 endpoints common to both corners' worst-1000 lists): the clock uncertainty (0.25 ns), the library hold time (0.064 ns) and the derate-induced clock skew do not shrink at the fast corner, while hold cells do.
Root cause, from counting hold cells by type: the post-CTS repair placed 21,102 `dlygate4sd3_1` delay gates; the **post-global-route design repair then resized about 960 of them into `buf_1`/`buf_2`/larger buffers** (likely because their weak outputs violated slew/cap), removing most of their delay, and nothing repaired hold afterwards.
Fix: run the timing repair again after the slew repair, `RUN_POST_GRT_RESIZER_TIMING: true` with `GRT_RESIZER_HOLD_SLACK_MARGIN: 0.4` (an experimental LibreLane step; it completed here). Hold is now >= +0.265 ns in all nine corners. +0.265 ns is measured after the 0.25 ns uncertainty, the derate and the CRPR term.

**Antennas (#12).** Rounds of the router's repair loop (violating nets after each): `d4_full` 1,325 -> 178 -> 15 -> 2 left; batch 1 1,760 -> 242 -> 35 -> 2 -> 1 -> 0; batch 2 1,747 -> 235 -> 27 -> 3 -> 1 and the last diode left a 1-box met1 short against VGND at the round cap (1 DRC error, 1 antenna net); batch 3 1,806 -> 236 -> 32 -> 1 -> 0 after 4 rounds.
The loop's last step is chaotic: raising the cap to 8 rounds was insurance, not what made batch 3 converge. Diodes cost slew on the long nets they sit on.

## SRAM per-corner timing (#6, `flow/runs/place_1029_1604`, 2026-10-29)
The OpenRAM liberty shipped for `sky130_sram_2kbyte_1rw1r_32x512_8` exists only at TT (`nominal_corner_only = True`) and was used for all nine STA corners. OpenRAM v1.2.50 was installed outside the repository
and the macro was characterised at TT 1.80 V/25 C, SS 1.60 V/100 C and FF 1.95 V/-40 C (`scripts/openram_corners.sh --parallel`, config `flow/openram/sky130_sram_2kbyte_1rw1r_32x512_8_corners.py`; one full-array ngspice run per step,
20.5 h for FF, 24 h for TT, 28.7 h for SS on three cores). The libraries are tracked in `flow/openram/libs/`, copied by `run_asic.sh`, and mapped per corner in `config.yaml` (`*_tt_025C_1v80`, `*_ss_100C_1v60`, `*_ff_n40C_1v95`).

| | shipped "TT" | regenerated TT | SS | FF |
|---|---|---|---|---|
| clk to dout, typical row | 0.38 ns | 1.81 ns | 3.06 ns | 1.19 ns |
| minimum period | 1.96 ns | 5.31 ns | 10.0 ns | 3.30 ns |
| address setup | 0.103 ns | 0.090 ns | 0.188 ns | 0.066 ns |

The shipped numbers were optimistic (the minimum period is exactly twice the 0.978 ns pulse width, and the clock-to-output table has identical rows). The corner ordering FF < TT < SS is now physical.

Run `place_1029_1604` (`./run_asic.sh -P flow/runs/mini_1027_0945`, same configuration as `place_1027_2317` plus the real libraries; an STA-only pass on the old layout, `-T`, first showed the effect):

| Check | `place_1027_2317` (old lib) | `place_1029_1604` (real libs) |
|---|---|---|
| Routing DRC / antenna nets / LVS / KLayout DRC | 0 / 0 / 0 / 0 | 0 / 0 / 0 / 0 |
| Magic DRC, full chip | 12,984,239 boxes, 0 integration errors | 12,984,239 boxes, **0 integration errors** |
| XOR, Magic vs KLayout GDS | 0 | 20 (all on layer 235/4, `prBoundary.boundary`, a cell-boundary marker, not a mask layer) |
| Setup, worst (max_ss) | +3.299 ns | +3.274 ns |
| Hold, worst (max_ff) | +0.265 ns | +0.271 ns |
| Setup at nom TT / FF | +16.0 / +17.0 ns | +13.7 / +15.8 ns |
| Slew violations, max_ss | 6,113 (69 above 1.5 ns, none above 2 ns) | 6,300 (278 above 1.5 ns, 128 above 2 ns, worst 6.0 ns) |
| Cap / fanout violations | 670 / 561 | 642 / 524 |
| Standard cells, area / power | 205,835, 1.61 mm2 / 39.5 mW | 205,333, 1.61 mm2 / 39.9 mW |

Timing still passes: the worst setup path at SS does not go through the SRAM, and the SRAM read paths have slack. What got worse is slew and cap on the SRAM read-port outputs.
**Cause (measured on the routed layout).** The OpenRAM liberty gives `dout` a `max_capacitance` of 27.6 fF (2.05 ns output slew at that load). After detailed routing 36 pins at TT and 39 at SS exceed it (`d_dout1[17]` 69 fF, `d_dout1[10]` 66 fF, `p_dout1[17]` 40 fF),
and the slew at 70 fF is extrapolated to about 6 ns. The pin plus buffer load is about 6 fF; the rest is wire (33-63 fF) because the detailed router detours: the global-route guide for `d_dout1[10]` runs from the macro pin at x=345 um west to x=193 um and back to loads at x=279-312 um (the net's bounding box in the OpenROAD Inspector is 192 to 349 um, which agrees).
Global-route overflow is 0 and met3 usage is 15%, so congestion alone does not explain it. The post-global-route repair buffered these nets but works from the global-route estimate, and nothing repairs after detailed routing.
Not fixed; recorded as a waiver in `flow/waivers/sram_dout_cap_slew.md`. Candidates (untried): an explicit buffer at each `dout1` pin in the SRAM wrapper, a macro placement halo (`PL_MACRO_HALO`; key not verified for this LibreLane version), a repair step after detailed routing.
The 20 XOR differences make the flow exit with a deferred error (exit code 2); the physical checks are clean.

## Die map (colour by block)
`make die-map RUN=<routed run dir> NETLIST=<06-yosys-synthesis/gpu_asic_top.nl.v>` (script `scripts/die_map.py`, needs only numpy + Pillow) writes
`docs/figures/die_map.png` (every standard cell coloured by block) and `docs/figures/die_regions.png` (flat, outlined block regions in the style of vendor die shots)
from the routed DEF. The synthesized netlist is flat, so the block of each cell is **inferred**: flip-flops are seeded from the hierarchical net names Yosys kept, the other logic takes
the majority label of its netlist neighbours, and cells added after synthesis (repair buffers, clock tree, diodes, taps) are grey tones. ALU/decoder logic has no registers to seed it and is
absorbed by its neighbours. The committed figures are the mini-profile run `floor_1022_1610` (2.4 x 2.4 mm): register files ~21% of cell area, FP32 FMA units 8%, core pipeline 9%; timing-repair buffers
are 21.5% of cell area (32k cells) and taps 5.4%.

## Not done (sign-off gaps)
| Item | Status |
|---|---|
| Flow completion on the mini profile (DRC, LVS, XOR, final metrics) | done (`place_1029_1604`; `place_1027_2317` before the SRAM libraries) |
| Cap / fanout violations (642 / 524), SRAM `dout1` pins above the macro's 27.6 fF limit, 128 slow-corner pins above 2 ns | open; waiver in `flow/waivers/sram_dout_cap_slew.md`; fixes untried (see "SRAM per-corner timing") |
| SRAM timing at SS/FF | done 2026-10-29 (OpenRAM TT/SS/FF, `flow/openram/libs/`) |
| Transistor-level LVS of the macro | not done: the macros are compared at their pins; the PDK has `libs.ref/sky130_sram_macros/spice/sky130_sram_2kbyte_1rw1r_32x512_8.spice` to use |
| Whether a shuttle accepts the OpenRAM macro DRC waiver | not decided; evidence is `make macro-drc`, `make signoff-drc`, `flow/waivers/openram_2kb_macro_drc_rules.txt` |
| Gate-level simulation of this netlist (zero delay, then with SDF; SDFs are in `28-openroad-stapostpnr/*/*.sdf`), RTL <-> netlist equivalence | not done (the old zero-delay GLS predates the divider, see [06](06-verification.md)) |
| Full-size (non-mini) profile | never routed; needs a rectangular die that fits a 2.92 x 3.52 mm Caravel user area and probably more than 16 GB |
| Caravel wrapper, harness-level simulation, precheck | not started |
See [08-todo](08-todo-and-open-questions.md).
