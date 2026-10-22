# mahi-gpu — ASIC variant: documentation

> **Verified against commit `dadec7f` (2026-10-21).** Every claim here cites a file/line or a command;
> if a page disagrees with the code, the code wins — then fix the page (`make docs-check` catches common drift).

This folder documents **only the ASIC part** (`ASIC/`): the sky130 retargeting of the mahi-gpu SIMT core,
its verification stack, its physical-design run, and — most importantly for later review — what is
**known not to work or not to be proven** ([04-limitations](04-limitations.md)).
The generic architecture/ISA description lives in the repo-root [`README.md`](../../README.md); these pages
cover what is *different or specific* in the ASIC variant and link there instead of copying.

## Read in this order
| # | Page | Read it to… |
|---|---|---|
| 1 | [01-overview](01-overview.md) | understand what the ASIC variant is and exactly how it differs from `src/rtl` |
| 2 | [02-architecture](02-architecture.md) | see the ASIC profile (sizes), block/pipeline/memory diagrams, top-level pins and address map |
| 3 | [03-isa](03-isa.md) | know the instruction semantics *as implemented* (incl. quirks) |
| 4 | [04-limitations](04-limitations.md) | **know what not to trust** (limitation register, IDs `L1…`) |
| 5 | [05-bug-log](05-bug-log.md) | see the 4 bugs found/fixed, with the test + assertion that now guards each |
| 6 | [06-verification](06-verification.md) | run/extend the verification stack; know its blind spots |
| 7 | [07-physical-flow](07-physical-flow.md) | reproduce the LibreLane run; know why its numbers are **not yet meaningful** |
| 8 | [08-todo](08-todo-and-open-questions.md) | pick the next work item |
| ✓ | [CHECKLIST](CHECKLIST.md) | re-audit everything in ~15 minutes |

## Status at a glance
| Area | Status | Evidence / where |
|---|---|---|
| RTL port (`ASIC/src/rtl`) | Functionally working on the ASIC profile; 4 port-era/latent bugs fixed **in ASIC copy only** | [05-bug-log](05-bug-log.md), [L10](04-limitations.md#l10) |
| Unit tests (7 modules) | Pass; mutation-checked | `make unit` — [06-verification](06-verification.md) |
| System tests | `verify-asic` (NZP/CALL/RET), `verify-matmul` (2-core 5×5) pass | `make verify-asic verify-matmul` |
| SVA assertions | 6 checker modules bound, silent on current design, each shown to fire on its historical bug | `src/rtl/sva/` |
| Random regression vs Python model | 22,800 runs (3 campaigns on the pre-SRAM-L2 RTL, 2 on the current RTL; int/FP/shared mem/barriers/atomics, latency 0–40), 0 mismatches | `make rand` |
| **Chip-level regression** (`gpu_asic_top` over Wishbone, 2 kernels/seed with soft reset) | `make top-quick` = 40 seeds; see [06](06-verification.md) | `make top-quick` |
| **Barrier (`SYNC`) after divergence** | **Not supported** (no join-point reconvergence) | [L1](04-limitations.md#l1) |
| **Chip top (`gpu_asic_top`)** | Wishbone-loadable 2×2 KB SRAM window; random kernels run end-to-end over the pins (`make top-quick`) | [L15](04-limitations.md#l15), [L16](04-limitations.md#l16) |
| Physical flow (LibreLane → GDS) | Completed once, **on stale RTL and an almost-empty netlist** | [07-physical-flow](07-physical-flow.md) |
| Gate-level sim / equivalence / LVS / timing sign-off | **Not done** | [08-todo](08-todo-and-open-questions.md) |

## Quick start
```bash
cd ASIC
make verify          # lint (3 profiles) + 7 unit tests + system tests + short random run + limits + docs-check
make limits          # characterization tests: each documented limitation must still behave as documented
make docs-check      # generated tables, citations, links and static RTL facts still match the docs
make rand N=200 LAT=6   # constrained-random programs vs the Python golden model
./run_asic.sh -a     # sv2v + yosys synthesis check only (needs the LibreLane venv)
```
