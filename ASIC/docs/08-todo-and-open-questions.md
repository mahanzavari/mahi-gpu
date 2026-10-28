# 08 — Backlog and open questions

> Verified against commit `dadec7f` (+ uncommitted docs), 2026-10-21. Priority: **P0** blocks any claim about the chip; **P1** high value; **P2** later.

## Backlog
| Pri | Item | Why / done when |
|---|---|---|
| ~~P0~~ | ~~Attach memory to `gpu_asic_top`~~ — **done** (2×2 KB OpenRAM window, `make top-quick`) | [L3](04-limitations.md#l3) |
| P1 | Grow memory beyond 512+512 words (4 KB / 16 KB macros need OpenRAM to generate them) and re-validate programs > 512 words | [L15](04-limitations.md#l15) |
| P1 | Multi-corner SRAM liberty (SS/FF) before timing sign-off | [L17](04-limitations.md#l17) |
| ~~P0~~ | ~~Re-run synthesis/PnR on current RTL + memory; complete the flow~~ — **done for the mini profile** (`place_1027_2317`: LVS 0, DRC 0, XOR 0, 9-corner timing met) | [07](07-physical-flow.md) |
| P0 | **Full-size profile**: never routed; needs a rectangular die inside the 2.92 × 3.52 mm Caravel area and likely > 16 GB | [07](07-physical-flow.md) |
| P1 | Cap/fanout violations (670/561) and the 69 slow-corner pins at 1.5–1.93 ns; SRAM address pins carry a 0.04 ns library limit (artifact) | [07](07-physical-flow.md) |
| P1 | Transistor-level LVS of the OpenRAM macro and its liberty at SS/FF (needs OpenRAM); shuttle decision on the macro DRC waiver | [L17](04-limitations.md#l17), [07](07-physical-flow.md) |
| P1 | Caravel user-project wrapper, harness-level simulation, precheck | not started |
| P1 | **Phase 3 remainder.** Done: zero-delay GLS of the post-synthesis netlist (`make gls`, 200/200). Open: post-route netlist (+SDF) GLS, 4-state/X simulation (iverilog is too slow at 175k cells — consider a smaller kernel or Verilator `--x-initial` seeds), RTL↔netlist equivalence (yosys `equiv`), STA gates | catches synthesis-only divergence; reuse `tb_random.sv` + `scripts/rand_regress.py` |
| P1 | Reconvergence ([L1](04-limitations.md#l1)): `SYNC` while diverged now faults (cause 3); true join-point reconvergence is still open | `limits.py` case L1 checks the fault |
| ~~P1~~ | ~~Expose faults ([L12](04-limitations.md#l12))~~ — **done**: `STATUS[4]`, `FAULT_INFO` at `0x3000_0008`, `gpu_fault_pin` | `make limits` case L12, chip testbench |
| P1 | Port fixes B2–B4 to `src/rtl` and add the SVA/tests there, or retire `src/rtl` ([L10](04-limitations.md#l10)) | |
| P2 | Overflow detection/SVA for the call stack ([L6](04-limitations.md#l6)); consider trapping on `CALL` at depth 8 | |
| P2 | Random-test extensions: `ATOM_CAS`, multi-core, barriers with join-point reconvergence (after L1), larger programs, PMU | [L9](04-limitations.md#l9) |
| P2 | Expose PMU/DCR over Wishbone ([L13](04-limitations.md#l13)); implement or remove L2 events ([L4](04-limitations.md#l4)) | |
| P2 | Delete or port the stale legacy testbenches ([L11](04-limitations.md#l11)); make `rtl.f` include `sva/` | |
| P2 | Investigate whether the register-file FP-collision guard is reachable (mutation survivor) | [06](06-verification.md) |
| P2 | Resolve by simulation the dispatcher re-flush loop with `start` held high ([02](02-architecture.md)) | read from code only |

## Open questions
1. Target clock / sky130 tapeout shuttle and area budget (current die 2.5 mm × 2.5 mm, 25 MHz are placeholders).
2. Should the register file / caches become SRAM macros (OpenRAM) — affects floorplan and the test strategy?
3. Is `SYNC` required to work with divergence for the intended kernels (drives the L1 decision)?
4. ~~Is integer division needed in hardware?~~ Resolved: a shared iterative divider (up to 33 cycles per lane, 309 flops / 14,409 µm² on the mini profile) replaced the stub ([L2](04-limitations.md#l2)).
5. Root `README.md` still states reconvergence "correctly handles" divergence and never mentions the ASIC variant — add a pointer and a caveat? (not changed; outside `ASIC/`)
