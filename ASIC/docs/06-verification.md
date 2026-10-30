# 06 — Verification stack

> Verified against commit `dadec7f` (+ uncommitted docs), 2026-10-21. Simulator: **Verilator 5.046** (primary). iverilog is only used by the legacy `make sim`.

## Layers
| Layer | What | Where | Run |
|---|---|---|---|
| Lint | `verilator --lint-only -Wall` on sim/asic/fpga profiles; new warning classes fail (10 baseline classes waived) | `Makefile: lint`, `LINT_WAIVE` | `make lint` |
| Unit tests | `alu`(×2 configs), `decoder`, `pc`, `registers`, `fp32_fma`, `dcache`, `l2_cache`(+VWB) — self-checking, random + corner vectors | `src/tb/unit/tb_*.sv` | `make unit` / `make unit-<name>` |
| System tests | `tb_asic_call_ret_branch` (NZP, nested CALL/RET, divergence, ASIC profile); `tb_matmul` (2 cores, 5×5, CALL/RET, DIV; **default profile + `USE_COMB_DIV`**) | `src/tb/ISA`, `src/tb/kernels` | `make verify-asic`, `make verify-matmul` |
| SVA | bound checkers: issue/fetch PC match, no dropped instruction, stack-pointer discipline, NZP update, divergence-stack bound, LSU strobe, fetcher overlap, VWB no-drop/hold | `src/rtl/sva/*.sv` (+`bind_<module>.sv`) | enabled (`--assert`) in all unit/system/random builds |
| Gate level (zero delay) | The Yosys netlist of `gpu_asic_top` (`06-yosys-synthesis/gpu_asic_top.nl.v`) run in Verilator with cell models generated from the liberty file (`gen_cell_models.py`; 74 combinational cells truth-table-checked against the PDK's own models with iverilog) and the real OpenRAM model; same `tb_asic_top` + `top_regress.py` (at the time with `MAHI_NO_DIV=1` in the golden model because synthesis stubbed DIV/MOD; L2 is now fixed, so this result predates `divider.sv` and must be re-run). Flops start random. **200 seeds / 400 kernel runs: 0 mismatches**, identical cycle counts to RTL. Caveats: *pre-placement* netlist (not post-route), no delays/SDF, 2-state (no X propagation), first run showed 28/40 mismatches that were entirely the DIV/MOD stub | `scripts/gen_cell_models.py`, Makefile `gls` | `make gls` (~15 min build, 3 GB) |
| Chip SVA | `memsub_sva` (host/GPU port exclusivity, ready/valid hold-and-release, no spontaneous ready) and `top_sva` (single-cycle ack, host never reaches SRAM while running/resetting), bound by `bind_top.sv`. Mutation check: three arbiter/blocking mutants each fire a distinct assertion | `src/rtl/sva/top_sva.sv`, `bind_top.sv` | runs inside `make top-quick` |
| Chip level | `tb_asic_top.sv`: loads PMEM/DMEM over Wishbone, starts, polls, reads back, soft-resets and runs a second program; directed window/byte-strobe/blocked-access checks plus corner cases (zero byte-enable, aborted cycles, status W1C, start+soft-reset together, write during soft reset, hard reset mid-run); `top_regress.py` compares both runs with the golden model (`GEN_STRIDE=32`) | `src/tb/top/`, `scripts/top_regress.py` | `make top-quick`; `make top-macro` repeats it against the real OpenRAM model (3 ns read delay, negedge write) |
| Golden model + random regression | Python ISA interpreter (`isa.py`, FP bit-exact), constrained-random generator (`gen.py`), runner (`rand_regress.py`), TB with random memory latency (`tb_random.sv`) | `scripts/`, `src/tb/random/` | `make rand N=200 LAT=6`, `make rand-quick` |
| Limitation characterization | one program per documented limitation | `scripts/limits.py` | `make limits` |
| Docs consistency | generated tables / citations / static patterns | `scripts/docs_check.py` | `make docs-check` |

`make verify` = lint + unit + `verify-asic` + `verify-matmul` + `rand-quick` + `top-quick` + `limits` + `docs-check` (several minutes, mostly Verilator compiles).

## What the random regression covers
Integer ALU (incl. MAC, DIV/MOD, bit ops), CMP/BR with **divergent** control flow (if/else, loops with per-thread trip counts), nested CALL/RET (acyclic,
no loops in callees), global LDR/STR (input region, private region, data-dependent addresses), floating point (`FADD/FSUB/FMUL/FMA`),
`ATOM_ADD` on 8 counters, shared memory (`LDSH/STSH`, banked) with `SYNC` barriers (phases W/R; warp-imbalance loops), full register and memory
dump compared bit-for-bit. 1 core × 2 warps × 4 lanes (ASIC profile). Latency: random per access, `+lat=N`.
*Uniform mode*: programs that use shared memory/`SYNC` use warp-uniform control flow because of [L1](04-limitations.md#l1).
Failing seeds are kept in `build/rand/fail/seed_N/` (`prog.hex`, `dmem.hex`, `expect.hex`, `out.hex`, `run.log`); replay with
`build/rand/rand_tb +prog=… +dmem=… +out=… +lat=… +seed=…`.

## Evidence the tests can fail (mutation sweeps)
Faults injected into copies of the RTL; all of these are *killed* unless noted.
| Fault | Caught by |
|---|---|
| old `pc.sv` (B1) | `unit-pc`, `verify-asic`, SVA `a_nzp_update`, random 98/100 |
| ID-latch (B2) reverted | `verify-asic`, SVA, random 92–95/100 |
| fetcher PC match removed (B3) | `verify-matmul`, SVA, random 98–100/100 |
| L2 push gating removed (B4) | `unit-l2_cache`, SVA, random 100/100 |
| ALU: overflow flag, CLZ, SHR carry, MIN signedness, MOD→DIV | `unit-alu` |
| decoder: CALL pc_mux, STR rt slot, imm sign-extend | `unit-decoder` |
| registers: FP>LSU priority, r30/31 write-protect, forwarding warp check | `unit-registers` |
| FMA: exponent +1/+2, FSUB sign, sign flip | `unit-fp32_fma` |
| LSU atomic add, shared-write data lane | random 55/100, 21/100 |
| barrier released after first warp | random 18/200 (needed warp-imbalance loops; 0/100 before) |
| **Survivors** | FMA alignment threshold 72→40 (effect below the 24-bit truncation, unobservable); `>=`→`>` in FMA cancel (equivalent); register-file FP-collision guard removal (0/100 — scoreboard likely prevents the collision; unverified) |

## Final-layout checks (mini profile, `flow/runs/place_1029_1604`, 2026-10-30)
| Check | Command | Result |
|---|---|---|
| Zero-delay gate-level simulation of the **routed** netlist (`final/nl`, 205k cells; fill/tap cells get empty models) | `make MINI=1 gls GLS_NETLIST=<run>/final/nl/gpu_asic_top.nl.v` | 24/24 random seeds match the golden model (two programs each, soft reset between) |
| Formal equivalence, synthesized netlist (`mini_1027_0945`) vs routed netlist | `make MINI=1 equiv EQ_SYNTH=... EQ_ROUTED=...` | **92,836 of 92,836 matched nets proven equal**, 0 unproven (Yosys `equiv_make`/`equiv_simple`/`equiv_induct`; 65 min, 8.7 GB) |
| Transistor-level LVS of the OpenRAM macro (Magic extraction of the GDS vs the PDK's `sky130_sram_macros` SPICE) | `make MINI=1 macro-lvs` | **circuits match uniquely**: 173,119 devices and 36,613 nets on both sides |

How to read them:
- The equivalence check proves that placement, clock-tree synthesis, resizing, hold fixing and antenna insertion changed no logic. Nets that exist only in the routed netlist (38,818 of 134,585) are made private by `scripts/hide_new_nets.py`, so every net of the synthesized netlist is matched. The SRAM macro is the same deterministic stand-in on both sides (`scripts/equiv/sram_equiv_standin.v`), so the check covers the logic around it, not the macro. eqy was tried first; its partitioner did not converge at this size.
- RTL to synthesized netlist is **not** proven formally. It is covered by simulation: the gate-level runs above and the earlier 200/200 on the synthesized netlist.
- Macro LVS: 5 leaf cells (write driver, sense amplifier and others) mismatch on their own because a supply is split inside the cell and joined only in the parent; Netgen flattens them and the macro matches. Netgen also lists 345,096 "property errors"; every one is the same value in metres (extracted) vs microns (reference), checked by script, so device sizes match too.
- Not done: gate-level simulation with SDF delays.

## Blind spots (what is *not* verified)
RTL-to-netlist formal equivalence (simulation only, see above); gate-level simulation with SDF delays; timing; `ATOM_CAS`; multi-core random; barriers after divergence ([L1](04-limitations.md#l1));
fault reporting ([L12](04-limitations.md#l12)); AXI wrapper (`gpu_axi4_adaptor`, `axi4_adaptor` — not in the ASIC top); `gpu_asic_top` Wishbone corner cases beyond the directed checks in `tb_asic_top.sv` (back-to-back masters, aborted cycles);
PMU counters; programs larger than 4 K words; the FP model is a *port of the RTL* so arithmetic design errors are only caught by `tb_fp32_fma` (tolerance check).

## Gotchas (each cost real time)
1. **Verilator static variables.** Declarations like `int x = …;` inside always/loop bodies are static. Hoist `integer` to module scope; do **not** use `automatic` (iverilog rejects it).
2. **`$bitstoshortreal` is unreliable in Verilator** — decode IEEE fields manually.
3. **`tb_matmul` needs the default profile** (do not pass `-DTARGET_ASIC=1`: the ASIC widths break its 32-bit address assumptions) and `-DUSE_COMB_DIV=1`.
4. **`-DSYNTHESIS=1`** silences the RTL's per-instruction `$display` (the random build uses it); without it a failing run prints GBs. The runner keeps only the head/tail of each log.
5. **Disk**: each Verilator build is 100–250 MB; the mutation sweeps run one at a time and delete their directories. `/tmp` is tmpfs.
6. `gpu_pkg.sv` must be first; `rtl.f` holds the canonical order (note: `rtl.f` lacks the `sva/` files).
7. Divergent programs print nothing special — use `make verify-asic-trace` (`MEM_TRACE`) for scheduler/fetch/L2 traces; `-DSHM_TRACE=1` for shared memory.
