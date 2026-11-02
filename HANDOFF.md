# mahi-gpu: session handoff

**Written:** 2026-11-02, at the end of a long Claude Code session on the Fedora workstation.
**Purpose:** let a fresh session, on Windows with Vivado or anywhere else, continue without the old conversation.

**For the next session:** read this whole file first. Then check the repo state (section 3), the standing rules
(section 5), and the open work (section 9). The user's next goal is **the FPGA**: section 9.1.

---

## Contents
1. [The project in one page](#1-the-project-in-one-page)
2. [Repository map](#2-repository-map)
3. [Current state (as of this handoff)](#3-current-state-as-of-this-handoff)
4. [History: what has been done](#4-history-what-has-been-done)
5. [Standing rules and user preferences](#5-standing-rules-and-user-preferences)
6. [Hard-won technical knowledge (gotchas)](#6-hard-won-technical-knowledge-gotchas)
7. [Tooling reference](#7-tooling-reference)
8. [Measurements and findings (latest)](#8-measurements-and-findings-latest)
9. [Open work, prioritized](#9-open-work-prioritized)
10. [Moving to Windows](#10-moving-to-windows)
11. [Local-only items that git does not carry](#11-local-only-items-that-git-does-not-carry)

---

## 1. The project in one page

**mahi-gpu** is a GPGPU written from scratch in SystemVerilog by the user (GitHub `mahanzavari/mahi-gpu`). It is a
learning and research platform for GPU microarchitecture: a custom 32-bit ISA (opcodes 0–36), SIMT warps with a
divergence stack, a 5-stage pipeline, a pipelined FP32 FMA, L1 I/D caches, a unified L2 with a victim write buffer,
banked shared memory, atomics, faults, a PMU, a DCR, and AXI4 / Wishbone host interfaces.

There are two RTL trees:
- **`FPGA/src/rtl/`** (until 2026-11-03 at the root as `src/rtl/`) was the original design described by the root
  `README.md`, with the full operand-forwarding network. On 2026-11-03 (branch `fpga/src-sync`) it was moved under
  `FPGA/` and re-synced as a byte-identical copy of `ASIC/src/rtl/`; `make docs-check` fails if the two drift apart.
  Its testbenches (`FPGA/src/tb/`) were moved but **not** synced.
- **`ASIC/src/rtl/`** is the maintained, verified tree used for silicon and FPGA. Before the sync it had diverged from the
  original tree:
  - **Front end and hazards:** single-cycle fetch and an issue-time scoreboard in place of forwarding.
  - **Functional fixes:**
    - a shared iterative divider;
    - faults visible to the host;
    - SYNC-while-diverged raises a fault;
    - fixes B2–B4 (L10, resolved by the sync).
  - **Chip top:** the `gpu_asic_top` Wishbone chip top, with 3 OpenRAM SRAMs.

**Profiles** (`ASIC/src/rtl/include/gpu_pkg.sv`, selected by defines):

| Profile | Define | Cores × warps × lanes | Notes |
|---|---|---|---|
| ASIC mini | `TARGET_ASIC` + `TARGET_ASIC_MINI` | 1 × 2 × 2 | the only profile with a routed layout; 8-line L1s, 32-word shared memory |
| ASIC full | `TARGET_ASIC` | 1 × 2 × 4 | synthesizes (226,744 cells); its place and route does not fit a 16 GB machine |
| FPGA | `TARGET_FPGA` | 2 × 4 × 4 | block-RAM sized (64K-word program/data spaces, 256-line L2, 256-word shared memory); lint-clean, **never built for a board** |
| Simulation (default) | none | 2 × 4 × 4 | 32-bit address spaces |

`SIM_WARPS=N` (Makefile, simulation only) overrides the warps per core for the ASIC profiles. It is **never** used by
the physical flow.

**Silicon status (sky130, mini profile):**
- **Signoff:** RTL to GDS with LibreLane/OpenROAD. All 9 PVT corners close at 40 ns (25 MHz). Routing DRC, LVS and
  antenna are 0.
- **Extra checks:** GLS of the routed netlist, synthesized-vs-routed equivalence, and macro transistor-level LVS.
- **Not taped out.** Caravel integration was tried and then **dropped by the user** (section 5).

---

## 2. Repository map

| Path | What |
|---|---|
| `README.md` | top-level description (die shot at the top, "Silicon (ASIC) and FPGA targets" section) |
| `FPGA/src/rtl/`, `FPGA/src/tb/` | synced copy of `ASIC/src/rtl` (since 2026-11-03), and the original testbenches |
| `assembler/assembler.py` | **an existing 125-line text assembler** (opcodes 0–36, labels) with kernels in `assembler/kernels/*.asm`; a starting point for the compiler work |
| `FPGA/` | `src/` only; no FPGA build flow exists yet |
| `ASIC/Makefile` | all verification and analysis targets (section 7) |
| `ASIC/run_asic.sh` | runs the LibreLane flow (`MINI=1`, resume options) |
| `ASIC/src/rtl/` | maintained RTL; `include/gpu_pkg.sv` holds the profiles; `sva/` holds assertions and binds |
| `ASIC/src/tb/` | testbenches: `random/tb_random.sv` (prog/dmem hex in, `TB_DONE cycles=N`), `top/tb_asic_top.sv` (chip-level over Wishbone), `unit/`, `kernels/tb_matmul.sv` |
| `ASIC/scripts/` | `gen.py` (random program generator), `isa.py` (golden model and encoders), `rand_regress.py`, `top_regress.py`, `limits.py`, `docs_check.py`, analysis tools (`die_map.py`, `die_blocks.py`, `congestion_map.py`, `timing_map.py` + `sta_dump.tcl`, `block_wiring.py`, `die_shot_render.py` + `die_shot_annotate.py`), signoff helpers (`drc_waiver.py`, `macro_drc.tcl`, `macro_lvs_ext.tcl`, `equiv/`, `hide_new_nets.py`), OpenRAM (`openram_corners.sh`) |
| `ASIC/flow/config.yaml` | LibreLane config, heavily commented with the reason for every setting; `config_mini.yaml` is **generated** by `run_asic.sh` |
| `ASIC/flow/macros/`, `ASIC/flow/openram/libs/` | OpenRAM `sky130_sram_2kbyte_1rw1r_32x512_8`: LEF/GDS and re-characterized TT/SS/FF liberties |
| `ASIC/flow/waivers/` | SRAM `dout1` cap/slew waiver, macro DRC rule list |
| `ASIC/flow/runs/` | **local only** (git-ignored): run directories (section 3) |
| `ASIC/caravel/` | the paused Caravel wrapper work |
| `ASIC/docs/` | 01 overview, 02 architecture, 03 ISA, 04 limitations (L1–L17), 05 bug log, 06 verification, 07 physical flow, 08 to-do, `CHECKLIST.md`, `datasheet/` (LaTeX + PDF), `figures/` (die map, regions, blocks, **die_shot.jpg**) |
| `ASIC/OPEN_PROBLEMS.md` | **untracked**; the user's working notes from 2026-10-26, partly outdated (section 9.7 has the update) |
| `ASIC/notes/` | **excluded from git** (`.git/info/exclude`): `gpu-hazards-and-open-pdks.md` (GPU hazard research, open-PDK runtime estimates) and `measurements/` (section 8) |

---

## 3. Current state (as of this handoff)

**Git**
- `main` = `origin/main` = `rtl/fwd-precompute` = `origin/rtl/fwd-precompute`: all in sync at the commit that adds
  this file (the README forwarding note `21d8e93` is just before it). Nothing is unpushed. The Fedora checkout is on `main`.
- Other branches: `ASIC` (merged earlier), `FU`, `librelane/route/shrinkDesign`.
- Working tree:
  - `.gitignore` is modified (the user's `tmp-images/` line). **Not mine, leave it.**
  - `ASIC/OPEN_PROBLEMS.md` is untracked.

**Reference layout: `ASIC/flow/runs/mini_1102_0724`** (scoreboard RTL, per-bank host read registers, L2 macro at y=1200)

| Metric | Value |
|---|---|
| Setup worst slack | **+7.71 ns** at max_ss_100C_1v60 (SS +7.7, TT +13.3, FF +15.5) |
| Hold worst slack | **+0.36 ns** (fast corner) |
| Routing DRC / KLayout DRC / LVS / antenna | 0 / 0 / 0 / 0 |
| Magic DRC | about 13M boxes, all inside the OpenRAM macros (known; the verdict comes from `make signoff-drc`, not run on this layout yet) |
| Slew / cap / fanout violations (flow count, 0.75 ns slew target) | 6,223 / 855 / 595 pins (see section 8 for what is real) |
| Wirelength / power | 9.29 m / about 40 mW |
| Rough Fmax at SS | about 32 MHz, limited by core paths (SRAM reads would allow about 40 MHz) |
| Run time | about 8.4 h of step time: detailed routing 3 h, Magic DRC 1.7 h, KLayout DRC 1 h |

Other runs (local):
- `place_1029_1604`: old RTL, the previously signed-off layout (setup +3.27 ns, hold +0.27).
- `mini_1031_2044`: scoreboard RTL, **failed setup −0.47 ns** on one SRAM read net.
- `mini_1101_1057`: host-read fix, **214 routing DRC errors** in the 104 µm DMEM–L2 channel.
- `mini_1027_0945`, `mini_1031_2024`: earlier partial runs.

---

## 4. History: what has been done

### Before this session (from the commit log)
- **ASIC branch setup.** Memory-aware docs and the flow config. The mini "physical bring-up" profile was added so
  place and route fits 16 GB.
- **First clean mini layout** at 40 ns:
  - macro power-net fix (`PDN_MACRO_CONNECTIONS`);
  - `SYNTH_STRATEGY: DELAY 4` (the default AREA mapping failed the slow corner by about −10 ns);
  - met4 strap keep-out bands so the power straps stay off the macro pin edges.
- **Analysis tools:** `die_map.py` and `die_blocks.py`.
- **Phase 2 RTL fixes:**
  - a shared radix-2 iterative divider (L2 resolved);
  - visible faults (`STATUS[4]`, `FAULT_INFO`, `gpu_fault_pin`; L12 resolved);
  - SYNC-while-diverged raises fault cause 3 (L1 enforced, not fixed).
- **Phase 2 physical fixes:**
  - **Clock root:** the clock input is modelled as a `clkbuf_16` driver.
  - **Slew/cap:** post-global-route repair with 70% margins.
  - **Hold:** a 0.4 ns margin, plus timing repair rerun after the slew repair, because slew repair was converting hold
    delay cells into buffers.
  - **Antennas:** more antenna repair iterations.
- **GDS fixes:**
  - `KLAYOUT_CONFLICT_RESOLUTION: OverwriteCell` makes the KLayout GDS contain the macros;
  - KLayout is the primary GDS;
  - Magic DRC is non-fatal; the verdict comes from `make signoff-drc` with waivers.

### This session (2026-10-26 → 2026-11-02), in order
1. **OpenRAM characterization at TT/SS/FF** (`openram_corners.sh`). The shipped TT liberty was **4.7× too fast**: 0.38
   ns clock-to-output vs 1.81 ns re-characterized. The per-corner libs are wired into `config.yaml` (`MACROS.lib`).
   - **Why SRAM reads are half-cycle paths:** `dout` launches on the falling edge.
   - **Known output-drive problem:** the `dout1` nets exceed the macro's own 27.6 fF max-cap, and slew reaches up to
     6 ns. This is waived in `flow/waivers/` (limitation L17).
2. **Signoff on `place_1029_1604`:**
   - full-chip Magic DRC: 0 integration errors after waivers;
   - gate-level simulation of the routed netlist: 24/24;
   - Yosys equivalence, synthesized vs routed: 92,836 of 92,836 nets;
   - macro transistor-level LVS (Magic + Netgen): circuits match uniquely, 173,119 devices.
3. **Merge to `main`** (`1da402c`).
4. **Caravel integration:**
   - **What was built:** `gpu_caravel_top`, wrapper RTL, Caravel SDC/pin DEF, a `CARAVEL=1` flat-wrapper flow.
   - **Why it stopped:**
     - the macro-first approach failed on SRAM met4 power pins (PDN-0232/0233);
     - the flat wrapper run sat 24 h in the resizer at 12–13.6 GB RAM, deep in swap.
   - **The user killed it and decided: no Caravel for now.** The artefacts remain in `ASIC/caravel/`.
5. **Critical-path analysis** (docs/07): the operand-forwarding compare from `wb_rd` dominated, plus the SRAM
   half-cycle reads.
6. **Branch `rtl/fwd-precompute`**: RTL reworked to take forwarding off the critical path.
   - **First attempt (superseded):** precompute the forwarding compares one cycle early (`8ac26ea`).
   - **Single-cycle fetch on I-cache hits** (`a0ba9b7`). The fetcher is a pass-through; the I-cache answers hits
     combinationally.
   - **`SIM_WARPS=N`**, simulation only (`343a76d`).
   - **Issue-time scoreboard; forwarding network removed** (`543479a`), the way real GPUs avoid forwarding:
     - **The rule:** a warp is held at issue while a same-warp instruction in decode or execute will write one of its
       sources. Results from the memory stage reach decode through the register file's write-through.
     - **Serializing instructions** (branches, calls, memory, FP, DIV) block only their own warp while in decode or
       execute.
     - **Safety check:** a `MAHI_SIM_CHECKS` assertion that forwarding is never needed.
     - **Result:** 1.23–1.32× fewer cycles.
   - **Research notes** on how NVIDIA, AMD and Intel handle hazards, and open-PDK runtime estimates, written to the
     untracked `ASIC/notes/gpu-hazards-and-open-pdks.md`.
7. **Datasheet** (`44db125`): pinout, packaging (Caravel QFN-64 / WCSP / bare die, to confirm with ChipFoundry) and a
   Caravel section (paused), re-synced with the new RTL.
8. **Layout of the new RTL `mini_1031_2044` failed setup at −0.47 ns.** The cause was the Wishbone readback register
   `wb_dat_o <= h_bank ? d_dout1 : p_dout1`. It was placed between the two macros, 434 µm from DMEM's pins, so the
   `dout1[12]` net reached 0.218 pF.
   - **Fix** (`4622bde`, user picked "option A"): register the host read data per SRAM bank before the bank select,
     and add state `H_DATA`. Host memory reads now ack in 4 cycles (CSR 1, memory write 2). Docs and datasheet updated.
9. **`mini_1101_1057` met timing (+6.29 ns) but had 214 routing DRC errors.**
   - **Cause:** the 104 µm channel between DMEM's top and the L2 macro's bottom.
   - **Fix** (`92041b7`): L2 macro moved from y=1120 to y=1200, giving a 184 µm channel.
   - **Result:** `mini_1102_0724` routed clean (section 3).
10. **New analysis tools** (`2339e84`, `713c56a`, documented in docs/07 "Analysis maps"):
    - `make congestion-map`: global-route track use per gcell, from `after_grt.guide`;
    - `make timing-map`: OpenSTA dump, slack map, worst paths drawn through their cells, violators grouped by net and
      driver;
    - `make block-wiring`: a net-count matrix and the placed wire between blocks;
    - `make die-shot`: a KLayout die-photo render with block regions labelled.
11. **Docs and README:**
    - die figures regenerated from `mini_1102_0724` (`08630f0`);
    - `ASIC/docs/figures/die_shot.jpg`;
    - README: die shot at the top and an ASIC/FPGA section (`a6bb568`, merged to `main` as `5236368`), plus the
      forwarding-difference note (`21d8e93`, unpushed).
12. **Floorplan review:** the issues found and the v2 plan, now **on hold**, are in section 9.6.
13. **Research questions** answered in conversation, summarized in sections 9.2–9.5:
    - which modern GPU features apply to mahi;
    - research opportunities (open SRAM accuracy, register files on open PDKs, small SIMT microarchitecture, GPU
      fuzzing/formal, GPU security, open-flow physical design, DFT, AI-assisted design);
    - detailed designs for the "top picks";
    - how to build a compiler.
14. **Performance and area measurements** (section 8). They changed the top pick: the store path dominates.

---

## 5. Standing rules and user preferences

**Workflow**
- **One heavy job at a time.** The Fedora box has 16 GB RAM and 20 threads.
  - **Peak memory:** OpenROAD detailed routing 8–11 GB, KLayout DRC about 6.5 GB, Magic DRC about 5.5 GB, Verilator
    builds 1–3 GB.
  - **Never** run Magic/KLayout DRC, Verilator regressions or STA alongside a flow that is routing.
  - **If a step dies without an error:** check `journalctl -k | grep "Killed process"`.
- **Long runs:** launch them in the background with a watcher that alerts on low memory. A full mini run takes 5–8.5 h.
- **Pushing:** push or merge only when the user asks. They usually say "push" and "merge to main and push main".
  Merges into `main` are done as `--no-ff` merge commits, in a temporary worktree so the user's checkout is untouched.
- **Commit messages:** end with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.

**Files**
- **Never commit:**
  - `ASIC/OPEN_PROBLEMS.md`;
  - the user's `.gitignore` edits;
  - anything in `ASIC/notes/` (it must stay untracked; it is excluded via `.git/info/exclude`).
- **Docs must stay in sync with the RTL.** `make docs-check` verifies generated tables, `file:line` citations, links and
  static RTL facts, and `make verify` includes it. After RTL edits, line citations in the docs often need remapping.

**Decisions**
- **No Caravel integration for now** (the user's decision).
- **`SIM_WARPS`** is for simulation and experiments only, never place-and-route or signoff.
- **Floorplan v2** is planned but **on hold** ("keep that for now").

**How the user likes to work**
- Concise reports with tables.
- The reason for every change ("state why").
- Honest status, including failures.
- Pictures they can view: they like the die shots and maps.

---

## 6. Hard-won technical knowledge (gotchas)

**Flow, PDK and tools**
- **PDK version.** LibreLane 3.0.16 uses sky130A **`8afc834`**:
  `~/.ciel/ciel/sky130/versions/8afc8346a57fe1ab7934ba5a6056ea8b43078e71/sky130A`. `~/.ciel/sky130A` points elsewhere
  (`0fe599b`). Standalone Magic/KLayout runs must use the 8afc834 tree (Makefile `PDK_VER`/`PDK_DIR`).
- **`PDN_MACRO_CONNECTIONS` format:** `<inst> VPWR VGND vccd1 vssd1`. A wrong net name silently leaves macros unpowered
  (a PDN-0231 warning only; LVS catches it).
- **KLayout GDS** needs `KLAYOUT_CONFLICT_RESOLUTION: OverwriteCell`, or the macros come out empty.
- **Resume semantics.** `librelane --last-run --from X` starts from the latest state; use `--with-initial-state`.
  `run_asic.sh -P` resumes placement from a run's `27-odb-applydeftemplate`; `-T` resumes STA; `TO_STEP=` stops early.
- **Docker** needs `DOCKER_CONTEXT=default` (set in `run_asic.sh`). Files written by a container without
  `-u $(id -u):$(id -g)` are root-owned; the Makefile targets pass `-u`.
- **Tools inside the LibreLane image:**
  - `openroad`, `klayout`, `magic`, `netgen` are on `PATH`;
  - standalone OpenSTA is `$(ls -d /nix/store/*-opensta/bin/sta)`, not on `PATH`;
  - KLayout batch rendering needs `QT_QPA_PLATFORM=offscreen` and a writable `HOME`.
- **Synthesis:** the flow synthesizes `sv2v`-converted Verilog. `sv2v` is in `~/.local/bin`; Yosys and Verilator are
  system-wide.
- **Getting a make target's full command:** `make -n` prints recipes with backslash continuations. Join them with
  `sed -e ':a' -e '/\\$/N; s/\\\n//; ta'`.
- **Magic stream-out** logs "Error while reading cell" on every run. It is harmless and known.

**OpenRAM macro (`sky130_sram_2kbyte_1rw1r_32x512_8`)**
- **Size:** 683.1 × 416.54 µm.
- **Pins:**
  - **port 1 (read):** `dout1`/`addr1[0,1]` on the **top** edge, `addr1[2:6]`/`csb1` on the right edge, `clk1` top-right;
  - **port 0 (read/write):** `din0`/`dout0`/`wmask0` on the **bottom** edge, `addr0[2:8]`/`clk0`/`csb0`/`web0` on the
    **left** edge.

  Flipping the macro does not help; it needs routing room on every side.
- **Timing:** reads are half-cycle paths (dout launches on the falling edge), and the output pins drive weakly. Keep
  their consumers close: that was the −0.47 ns failure.
- **DRC:** not clean under Magic (about 5.6M errors per macro). KLayout's sky130 deck reports 0. The DRC verdict comes
  from `make signoff-drc` with `flow/waivers/`.

**Simulation and verification**
- **Every build defines `SYNTHESIS`,** so `ifndef SYNTHESIS` checks never compiled. Sim-only checks use
  `MAHI_SIM_CHECKS`.
- **Regression setup:** `rand_regress.py` uses `profile_cfg.py`, configured through the env vars `MAHI_THREADS`,
  `MAHI_LANES`, `MAHI_SHARED` and `GEN_STRIDE`. `make MINI=1` or `SIM_WARPS` export them. With more threads, use
  `GEN_STRIDE=32`.
- **Log helper quirk:** `bounded_run` keeps the head and tail of a log, so short logs appear **twice**. Deduplicate
  before counting lines.
- **`pkill -f` can match your own shell.** Kill by PID or with `docker kill`.

**Design quirks** that matter for software/compilers (docs/03, docs/04):
- `CMP` is unsigned (L5).
- A branch before any `CMP` is never taken (NZP resets to 0).
- No ALU immediates; `CONST` is 16-bit sign-extended, plus `LUI`.
- Branch targets are absolute.
- The call stack is 8 deep and wraps (L6).
- FP is not IEEE: truncation, flush-to-zero, no NaN/Inf (L8).
- On-chip memory is 512 + 512 words (L15).
- The host can't access memory while the GPU runs (L16).
- Registers 29/30/31 are block id, thread count and thread id.

---

## 7. Tooling reference

All commands run from `ASIC/`.

| Command | What |
|---|---|
| `make verify` | lint, unit tests, `verify-asic`, matmul, `rand-quick`, `top-quick`, `limits`, `docs-check` (full profile) |
| `make MINI=1 top-quick rand-quick` | mini-profile chip-level and random regressions |
| `make top-macro` | chip test against the real OpenRAM behavioural model |
| `make SIM_WARPS=4 rand-quick` | more warps, simulation only (build dirs `build_w4`, `build_mini_w4`, ...) |
| `make lint` | Verilator lint of the sim/ASIC/FPGA profiles plus the tops |
| `make docs-check` | doc consistency |
| `MINI=1 ./run_asic.sh` | full mini flow into `flow/runs/mini_<date>` (5–8.5 h) |
| `make signoff-drc RUN=...` | full-GDS Magic DRC with waivers |
| `make gls`, `make equiv`, `make macro-lvs`, `make macro-drc` | gate-level sim, equivalence, macro LVS/DRC |
| `make die-map RUN= NETLIST=` | colour-by-block map (writes `docs/figures/die_map.png`, `die_regions.png`) |
| `make congestion-map RUN=` | `RUN/congestion.png` (needs a run past global routing; useful about 1.3 h into a run) |
| `make timing-map RUN= [CORNER_LIB= SRAM_CORNER= SPEF_CORNER=]` | `RUN/analysis/slack_*.png`, `violators_*.png` (OpenSTA in Docker, about 1 min) |
| `make block-wiring RUN= [NETLIST=]` | `RUN/analysis/wiring_matrix.png`, `wiring_map.png` |
| `make die-shot RUN= [OUT=docs/figures/die_shot.jpg]` | die-photo render with labelled regions (about 30 s) |

---

## 8. Measurements and findings (latest)

Scripts and raw JSON are saved locally in `ASIC/notes/measurements/` (untracked):
- `perf_driver.py`: golden-model trace hook (load-to-use distances, op mix) plus Verilator cycle counts;
- `probes.sv`: sim-only `bind` counters on the scheduler, LSU and D-cache;
- `run_all.sh`: builds and runs all configs;
- `rf_variants.v`: clock-gated and latch register files.

All 600 measured runs matched the golden model.

**Throughput** (random programs, 60 seeds, thread-instructions per cycle at memory latency 0):

| | 2 warps | 4 warps | 8 warps |
|---|---|---|---|
| mini (2 lanes) | 0.316 | 0.350 (+11%) | 0.402 (+27%) |
| full (4 lanes) | 0.380 | 0.462 (+22%) | — |

**Where cycles go** (probes):

| | mini | full |
|---|---|---|
| a warp parked on memory | 69% | 80% |
| LSU busy | 64% | 77% |
| LSU cycles per transaction | 11.4 | 11.4 |

- **Stores are 61–65% of transactions** and cost **10.5 cycles each.** The D-cache (`dcache.sv`) is **write-through,
  no-write-allocate and blocking**: each store waits in `WAITING_WRITE` for L2 to accept it, while the warp is parked
  in `WAITING_MEM`.
- **Reads** take 6.4 cycles, with an 81% hit rate.
- **LSU busy time by state:** WAIT_WRITE 50%, WAIT_READ 18%, ATOMIC_WAIT_WRITE 13.5%.
- **Ceiling:** latency hiding alone (more warps, non-blocking loads) can gain at most 1.3–1.56×.

**Load-to-use distance** (15,296 loads):
- **First data use:** 23% immediately, 55% nine or more instructions later.
- **But a memory op usually comes first:** 52% hit another memory operation within 2 instructions. With one memory
  operation in flight per warp, the median overlap is 2–4 instructions.
- **matmul:** 0 for all 250 loads (`LDR r8; LDR r9; MUL`).

**Register file area per lane** (Yosys with sky130 hd, same script for all three):

| | 2 warps | 4 warps |
|---|---|---|
| today | 119.5k µm² | 239.3k µm² |
| clock-gated words + one write bus | 83.7k µm² (−30%) | 164.5k µm² |
| latch storage | 75.6k µm² (−37%) | 146.5k µm² |

- **Read ports dominate now:** the three read ports are about 60% of the latch version, so 2 read ports is the next
  lever.
- **Flow-netlist register file:** in the flow's netlist it is 25,209 cells, about 0.31 mm² for 2 lanes. Storage
  flip-flops are only 29% of that; per-bit write logic and read muxes are the rest.

**Physical findings on `mini_1102_0724`:**
- **Real slew violations against the 1.5 ns library limit:** 36 `mux4_2` write-data selects feeding SRAM `din0`, up to
  2.13 ns. Each is about 1 mm of unbuffered wire, under the 1200 µm repair limit. 28 feed DMEM and 8 feed L2.
- **Clock root still overloaded:**
  - **Clock port:** the `clk` pin landed at the die corner (0, 2341), so the `clk` port drives 0.407 pF (limit 0.2).
  - **Macro clock branch:** `clkbuf_1_0_0_clk` is at 0.426 pF.
  - **Count:** 241 clock nets break the capacitance limit.
- **IO pins are unconstrained,** so they move between runs. In `mini_1101_1057`, 92 of the 108 pins sat on the left
  edge at y = 495–619, inside the PMEM–DMEM gap.
- **DMEM and L2 SRAM ports share one address net** (`d_a0 == d_a1`; L2 `addr0/addr1 = waddr`):
  - **Cost:** DMEM port-1 address branches average 516 µm, vs 26 µm for PMEM's separately driven port 1.
  - **Pin side matters too:** PMEM port 0 averages 511 µm, because its pins face the die edge.
- **Block wiring:** load/store unit ↔ register files is the most wire (334 mm), then pipeline ↔ load/store unit
  (298 mm, centroids 1.76 mm apart). Each SRAM uses its top and bottom pin edges about equally.

---

## 9. Open work, prioritized

### 9.1 FPGA (the user's next goal)
**Why:** an FPGA runs about 100–1000× faster than Verilator. Uses:
- hardware-accelerated random regression (millions of programs);
- architecture sweeps on real kernels using the PMU;
- pre-silicon validation of the exact `TARGET_ASIC_MINI` RTL through Wishbone, with block RAM in place of OpenRAM;
- a target for the compiler and runtime;
- a demo soft GPU on a Zynq;
- FPGA-specific research.

**Steps:**
1. **Resource estimate, no board needed:**
   - synthesize `TARGET_FPGA` (and the ASIC profiles) with Yosys for xc7 (`synth_xilinx`), UltraScale+, and ECP5
     (`synth_ecp5`);
   - or use Vivado `synth_design` now that it is available.

   This gives LUT, flip-flop, block RAM and DSP counts.
2. **Pick a board:**
   - PYNQ-Z2 / Zybo Z7-20 (xc7z020: 53k LUT, 140 BRAM36, 220 DSP);
   - Kria KV260 (117k LUT, 144 BRAM + 64 URAM);
   - ECP5-85 boards for a fully open toolchain.

   **Ask the user which board they have.**
3. **FPGA adaptations:**
   - `mahi_sram` and the cache arrays inferred as block RAM;
   - the register file in LUT-RAM (replicated for its 3 read ports);
   - FMA on DSPs;
   - a clock/reset wrapper and XDC constraints (the design targets 40 ns, so 25–50 MHz should be easy);
   - a host path: AXI (`gpu_axi_wrapper`) to the Zynq PS, or a UART-to-Wishbone bridge.
4. **Host software:** Python (PYNQ or UART) loads `prog.hex`, starts the GPU, polls status, reads memory and PMU
   counters. Reuse `gen.py`/`isa.py` for a hardware regression.
5. **Use it:** large random campaigns, then warp/lane/cache sweeps and the write-buffer experiment.

### 9.2 Microarchitecture, re-prioritized by the section 8 measurements
1. **D-cache write buffer plus posted stores. New top pick.**
   - acknowledge a store once it's queued, and drain it to L2 in the background;
   - don't park the warp on stores;
   - loads must check the buffer for a pending store to the same block.

   Rough estimate: 25–35% fewer cycles on the random programs. Prototype it in simulation first.
2. **Join-point reconvergence (closes L1).**
   - add a reconvergence-PC field per stack entry, plus a current RPC per warp;
   - give the join point through a new instruction (for example `SSY`), or put a 7-bit forward offset in `BR`'s unused
     bits [22:16];
   - on divergence push `{J, full mask}`, then `{target_b, mask_b, rpc=J}`; pop when the running group's next PC == RPC;
   - grow the stack to 6–7 entries.

   This fixes SYNC after divergence and runs the code after a divergence once instead of once per group.
3. **Non-blocking loads.**
   - add per-warp pending bits, checked at **issue**, not in decode, so other warps keep issuing;
   - check RAW and WAW;
   - SYNC and kernel completion wait for outstanding memory.

   It only pays with 2+ loads in flight per warp and compiler load scheduling.
4. **Denser register file.**
   - per-word clock gating and one write bus (−30%), then latches (−37%), then 2 read ports;
   - don't store r29–r31;
   - reset of r0–r28 can only be dropped if the generator/golden model (which zero-initializes) stops relying on it.

   It pays for more warps, but more warps only helps once the memory path is fixed.
5. **Cheaper items:**
   - I-cache next-line prefetch;
   - warp shuffle/vote;
   - clock gating;
   - fixing the PMU gaps (L4 L2 events are 0; L13 counters unreachable from the pins).

### 9.3 Compiler
- **Stage 1: assembler.** Extend or replace `assembler/assembler.py`:
  - pseudo-instructions: `LI` (`LUI` + `OR`), `MOV`, `JMP` (needs a `CMP` first because of L5);
  - output in the `prog.hex` format of `tb_random`;
  - check its output against `isa.py`.
- **Stage 2: kernel compiler.**
  - **Front end:** Python-subset kernels via Python's `ast` module, or a C/CUDA-like subset via `pycparser`.
  - **Middle end:** IR, then instruction selection, then linear-scan register allocation over 29 registers, spilling to
    per-thread DMEM.
  - **Control flow:** structured control flow, with divergence analysis that rejects `__syncthreads` in divergent code
    and emits join points.
  - **Performance passes:** coalesced data layout (lane i accesses base + i, so stores merge) and early loads.
- **Stage 3, only if the project goes long-term:** an LLVM back end.
- **Testing:** compile, then run in `isa.py` and in Verilator, and compare against a Python reference. This also gives
  real benchmark kernels for re-running section 8.

### 9.4 Research directions (best bets)
1. **OpenRAM model accuracy study.** Data in hand: the 4.7× TT optimism, plus the output-drive limits.
2. **Register-file styles on open PDKs.**
3. **Scoreboard vs forwarding vs compiler stall counts** in small SIMT cores. Data in hand.
4. **SIMT vs RISC-V vector (RVV) at equal area.**

**Venues:** WOSET, OSDA, CARRV, Latch-Up, IEEE CAL, student research competitions.

### 9.5 Physical/signoff to-do for `mini_1102_0724`
- Run `make signoff-drc RUN=flow/runs/mini_1102_0724`; not done yet for this layout.
- Optionally re-run GLS and equivalence on this netlist; they were done on `place_1029_1604`.
- Update docs/07 and the datasheet physical chapter with the `mini_1102_0724` numbers. They still describe
  `place_1029_1604`.

### 9.6 Floorplan v2 (planned, ON HOLD)
Config only, no RTL change. Each change, with its reason:
1. **Move the macros** to PMEM (200, 200), DMEM (200, 840), L2 (200, 1480); order unchanged. This gives a 150 µm
   clearance on the left and bottom pin edges (now 30 µm) and about 220 µm channels.
2. **Move `PDN_OBSTRUCTIONS`** with them (12 µm bands above and below each macro).
3. **Widen the macro halo:** `FP_MACRO_HORIZONTAL/VERTICAL_HALO` 10 → 20 (the cut-rows halo), to free the macro
   corners.
4. **Add an `IO_PIN_ORDER_CFG`:**
   - the Wishbone bus on the left edge, spread over y ≈ 250–1850;
   - `clk` at the middle of the bottom edge;
   - `reset`, done and fault next to the bus.

   This fixes the clock-port load and keeps runs reproducible. (The user may prefer the Wishbone pins on the bottom
   edge; ask.)
5. **`CTS_CLK_MAX_WIRE_LENGTH` 0 → 500,** so CTS buffers long clock wires (241 clock-tree cap violations).
6. **`GRT_DESIGN_REPAIR_MAX_WIRE_LENGTH` 1200 → 600,** for the 36 `din0` write-data nets. Cost: up to about 2.7k more
   buffered nets.

**Success criteria:**
- **Routing:** 0 detailed-routing violations, 0 global-route overflow, and fewer than 25 congestion blocks above 80%.
- **Clock:** the `clk` port under 0.2 pF, and far fewer than 241 clock nets over the cap limit.
- **Slew:** no non-SRAM pin above 1.5 ns at SS.
- **Address wires:** PMEM port-0 address nets under about 200 µm.
- **Timing:** setup at least +7 ns, hold at least +0.3 ns.

**How to run it:** check `make congestion-map` about 1.3 h in, and kill the run early if it is bad.
**Optional RTL follow-up:** separate per-port address drivers with `(* keep *)`, or use one SRAM port for both reads
and writes.

### 9.7 Update to `ASIC/OPEN_PROBLEMS.md` (2026-10-26 snapshot)
**Resolved:**

| # | Item | Resolution |
|---|---|---|
| #3 | KLayout GDS | now contains the macros |
| #6 | macro timing and LVS | per-corner SRAM timing; macro LVS done |
| #7 | gate-level sim, equivalence | done on `place_1029_1604` |
| #9 | faults invisible (L12) | resolved |
| #10 | DIV/MOD return 0 (L2) | resolved |
| #12 | antennas | now 0 |
| #13 | deep forwarding logic | forwarding removed |
| #20 | merge to main | merged and pushed |

**Partly resolved:**
- **#5 clock root:** improved, but the pin placement still overloads it.
- **#11 hold margin:** +0.36 ns now.
- **#4 slew/cap/fanout:** now understood (section 8).
- **#2 macro DRC:** waived, but a shuttle must accept the waiver.

**Still open:**
- **#1 full-profile layout:** does not fit a 16 GB machine.
- **#8 reconvergence (L1):** fault only, no join-point reconvergence yet.
- **#14 memory size (L15/L16).**
- **#15/#16 test coverage:** gaps remain for the mini profile.

---

## 10. Moving to Windows

The repo's tools are Linux tools (make, Verilator, sv2v, Yosys, Docker + LibreLane), so **use WSL2**:
1. **Install WSL2 and Ubuntu.** Install `git make python3 verilator yosys iverilog`. Get `sv2v` (release binary) and
   Docker (Docker Desktop with WSL integration). Only the physical flow needs Docker.
2. **Clone inside the Linux filesystem**, for example `~/Projects/mahi-gpu`, not under `/mnt/c`. Check out
   `rtl/fwd-precompute` or `main`.
3. **Run Claude Code in WSL** on that folder, from the desktop app or the CLI. Start with "read HANDOFF.md and
   continue with 9.1 step 1".
4. **Call Windows Vivado from WSL** in batch mode:
   `/mnt/c/Xilinx/Vivado/<version>/bin/vivado.bat -mode batch -source build.tcl`.
   Program the board with Vivado Hardware Manager or `hw_server` on Windows. Keep Vivado project and output
   directories in a Windows-visible path if the GUI should open them.
5. **If Git Bash is used instead of WSL:** run `git config --global core.autocrlf false` **before cloning**, so
   `.hex`/`.sh` files keep LF line endings.
6. **Memory notes.** The two auto-memory notes from this machine are folded into sections 5 and 6:
   `host-memory-limits`, `librelane-flow-gotchas`. Re-check the RAM size of the Windows machine before running the
   physical flow there.

---

## 11. Local-only items that git does not carry
Copy these by hand if needed:

| Item | Where | Notes |
|---|---|---|
| Run directories | `ASIC/flow/runs/` (several GB) | `mini_1102_0724` is the reference; regenerable with `MINI=1 ./run_asic.sh` |
| Measurement scripts and results | `ASIC/notes/measurements/` | section 8 |
| Research notes | `ASIC/notes/gpu-hazards-and-open-pdks.md` | GPU hazards, open-PDK runtime estimates |
| Working notes | `ASIC/OPEN_PROBLEMS.md` | untracked by choice |
| This file | `HANDOFF.md` | untracked unless the user decides to commit it |
| LibreLane setup | `~/eda/librelane/.venv`, `~/.ciel` (PDK `8afc834`) | reinstall on the new machine |
