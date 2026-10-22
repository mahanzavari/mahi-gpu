# 05 — Bug log (found and fixed)

> Verified against commit `dadec7f` (+ uncommitted docs), 2026-10-21. All four fixes are in `ASIC/src/rtl` only ([L10](04-limitations.md#l10)).
> For each bug: how it showed up, root cause, fix, **the test that fails without the fix** and **the SVA that now fires at the
> moment of failure** (both were demonstrated by re-introducing the bug — "mutation evidence").

| ID | Bug | Introduced by | Fixed in | Guard tests | SVA |
|---|---|---|---|---|---|
| [B1](#b1) | `pc.sv`: NZP / CALL / RET state updates deleted | ASIC port | `499a7d0` | `unit-pc`, `verify-asic`, `rand` | `pc_sva.a_nzp_update`, `a_sp_call/ret` |
| [B2](#b2) | ID-latch squash drops a fresh instruction of another warp | original design (latent) | `0ab48c4` | `verify-asic`, `rand` | `core_sva.a_issue_not_dropped` |
| [B3](#b3) | Fetcher issues warp A's fetched instruction as warp B's | original design (latent) | `ab57e33` | `verify-matmul`, `rand` | `core_sva.a_issue_pc_match` |
| [B4](#b4) | L2 pushes to a full victim write buffer → dirty line lost | original design (latent) | `e086fc4` | `unit-l2_cache`, `rand` | `vwb_sva.a_no_drop` |

## B1
**`pc.sv` — the sequential updates of `nzp`, `return_stack` and `stack_ptr` were deleted in the ASIC port.**
- *Symptom.* Every conditional branch was dead (NZP stayed 0), `CALL`/`RET` never pushed/popped. The chip would still have passed
  synthesis, STA and DRC — the LibreLane run `RUN_2026-10-19_14-54-17` was produced from this broken RTL (`a1d47e0`).
- *Root cause.* A `` `ifndef SYNTHESIS `` clean-up kept only the `$display` statements; the three non-blocking assignments were removed
  (`git show a1d47e0:ASIC/src/rtl/pc.sv`). `src/rtl/pc.sv` is intact.
- *Fix.* Restored `nzp[warp_id] <= alu_out[2:0]`, return-address push + `stack_ptr++`, `stack_ptr--` (`pc.sv`, current file), prints stay under `SYNTHESIS`.
- *Evidence.* `tb_pc` fails 5+ checks on the old file; `tb_asic_call_ret_branch` times out; SVA `a_nzp_update` fires at t=535 (first `CMP`);
  random regression: 98/100 seeds fail.

## B2
**`core.sv` ID-stage latch: a flush of the *previous* occupant's warp discarded a fresh instruction of a *different* warp.**
- *Symptom.* One thread of a divergent warp read `R7 = 0` and stored 0 instead of 211 (looked like a cache write-combine bug).
- *Root cause.* `else if (flush_warp_mask[id_warp_id] || …)` squashed the ID latch even when a valid instruction for another warp was
  being issued the same cycle; `id_warp_id` still held the old warp. The fetcher had already consumed the instruction
  (`.consume(valid_issue)`), so it was lost.
- *Fix.* `core.sv:118-119`: squash on the stale occupant only if nothing fresh is loading
  (`flush_warp_mask[id_warp_id] && !(valid_issue && if_instruction_valid)`).
- *Evidence.* SVA `a_issue_not_dropped` fires at t=2455 ("warp 1 pc 1a"); random: 92–95 / 100 seeds fail.
- *Lesson.* Timing-dependent (needs two warps' control-flow events in the same cycle); passed many tests by luck.

## B3
**Fetcher / scheduler warp skew.** The scheduler re-selects a warp combinationally every cycle but the fetcher latches one PC; if the selection
moved while a fetch was in flight (or while the result was held), the held instruction was issued for the wrong warp.
- *Symptom.* `tb_matmul`, core 1: PC `0x1d` issued word `0x07800012` (the loop-back branch fetched for PC `0x21`); four MUL/ADD/CONST/ADD
  instructions skipped; elements 16–19 of the result were 0.
- *Fix.* `fetcher.sv` exports `fetched_pc` (`fetcher.sv:31`, `fetcher.sv:38`) and refetches from `DONE` when the selected PC changed (`fetcher.sv:74`); `core.sv:107`
  accepts the instruction only when `if_fetched_pc == if_pc`.
- *Evidence.* SVA `a_issue_pc_match` fires at t=2765 ("issuing PC 1c but fetched for 1d"); random: 98–100 / 100 fail without the fix;
  `verify-matmul` passes 25/25 elements.

## B4
**L2 ↔ victim-write-buffer handshake.** L2 decided to push an evicted/flush line using `push_ready`, which lags by one cycle; back-to-back pushes
(flush scan, evictions) overflowed the 4-entry buffer, which silently dropped the line.
- *Symptom.* After the final flush ~16/512 random blocks in external memory lacked their last partial write.
- *Fix.* `l2_cache.sv:102` `vwb_can_push = vwb_push_ready && !vwb_push_valid`, used at the three decision points (`l2_cache.sv:220`, `l2_cache.sv:256`, `l2_cache.sv:306`); the buffer
  now raises `$error` on a push while full (`victim_write_buffer.sv:101`).
- *Evidence.* `tb_l2_cache` fails after flush; SVA `a_no_drop` fires at the lost write (t=324,005 in the unit test); random: 100/100 fail
  (every program ends with a flush).

## Findings that were test-infrastructure bugs (not RTL)
| What | Effect | Resolution |
|---|---|---|
| `int x = expr;` in a clocked block is *static* under Verilator (IEEE 1800-2023) | memory mock froze at first address; checker printed "EXPECTED 00" | hoist plain `integer` to module scope; `automatic` breaks iverilog |
| `$bitstoshortreal` returns garbage in Verilator | FP unit test compared 0 vs 0 (vacuous pass) | explicit IEEE decoder in `tb_fp32_fma.sv` |
| `Makefile` `.PHONY unit-*` blocked the pattern rule | unit tests silently did not run | static pattern rule |
| generator: loop nested in `if` reused the outer counter | 37 % non-terminating programs | `loop_depth` passed through `stmt_if` |
| `tb_matmul` checker `int expected_val = i;` | false passes (everything "expected 0") | hoisted variable |
