# Re-audit checklist (~15 minutes of work, a few more of waiting)

> Run from `ASIC/`. "Expected" lines are what a healthy tree prints. If something differs, either the design or the docs changed:
> find the page named in the last column and update it (or fix the design).

| # | Command | Expected | Page |
|---|---|---|---|
| 1 | `git rev-parse --short HEAD; git status --short` | note the commit; docs say `dadec7f` — update the header lines if newer | all |
| 2 | `make docs-check` | `docs-check: OK` (tables, citations and static patterns match code) | all |
| 3 | `make lint` | `lint OK (sim/asic/fpga)` | 06 |
| 4 | `make unit` | 7 × `tb_*: ALL PASSED` (+ `tb_alu` twice) | 06 |
| 5 | `make verify-asic` | `ALL 8 THREADS PASSED` | 06 |
| 6 | `make verify-matmul` | `MATMUL DIVERGENCE AND CALL/RET STACK TESTS PASSED!` | 06 |
| 7 | `make rand-quick` | `test_model: PASSED`, `40 seeds (lat<= 6): PASS=40` | 06 |
| 8 | `make rand N=300 LAT=10` | `300 seeds (lat<= 10): PASS=300` | 06 |
| 9 | `make limits` | 6 cases (L1, L5, L6, L8, L12, L14), all `PASS (limitation present)` — a FAIL means a limitation changed | 04 |
| 13 | `make datasheet` | builds `docs/datasheet/mahi-gpu-datasheet.pdf` (21 pages) with no LaTeX errors | datasheet |
| 10 | `grep dfxtp flow/runs/*/06-yosys-synthesis/reports/stat.rpt; ls flow/runs/*/final` | `854 … dfxtp_2` (old run) and *no* `final/` — until the flow is re-run | 07 |
| 11 | `grep -c vwb_can_push ../src/rtl/l2_cache.sv; grep -c fetched_pc ../src/rtl/core.sv ../src/rtl/fetcher.sv` | `0` for all three (fixes only in the ASIC copy) until [L10](04-limitations.md#l10) is resolved | 04 |
| 12 | `for f in controller core_pmu dcr axi4_adaptor; do cmp ../src/rtl/$f.sv src/rtl/$f.sv; done; cmp ../src/rtl/axi_ram.v src/rtl/axi_ram.v` | no output (identical) | 01 |

Fault-injection spot checks (re-prove the tests have teeth; each should make the named command **fail**):
- Delete the `nzp[warp_id] <= alu_out[2:0];` line in `src/rtl/pc.sv` → `make unit-pc` fails.
- In `src/rtl/l2_cache.sv:102` drop `&& !vwb_push_valid` → `make unit-l2_cache` fails (and SVA `a_no_drop` fires).
- In `src/rtl/core.sv:107` remove `&& (if_fetched_pc == if_pc)` → `make verify-matmul` fails.
Revert with `git checkout -- <file>` afterwards.
