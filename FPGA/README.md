# FPGA tree

| Path | What |
|---|---|
| `src/rtl/` | the GPU RTL: a copy of `ASIC/src/rtl` plus the fixes below (`core.sv`, `pc.sv`, `scheduler.sv`) |
| `src/tb/` | `random/`, `unit/`, `ISA/tb_asic_call_ret_branch.sv`, `kernels/tb_matmul.sv` are maintained (from `ASIC/src/tb`, adapted for 2 cores); the other directories are legacy and do not build against the current `gpu` ports |
| `sim/xsim_run.py` | Vivado simulator (xsim) flow: Windows or Linux, no make |

## Simulating with Vivado (xsim)

```
python sim/xsim_run.py all --jobs 12                # unit + system + 2 x 40 random seeds (about 1.5 min)
python sim/xsim_run.py unit
python sim/xsim_run.py system
python sim/xsim_run.py rand --seeds 0 300 --lat 6 --jobs 12
```

`--profile fpga` (default) builds `TARGET_FPGA`: 2 cores x 4 warps x 4 lanes, 64K-word program/data spaces, 256-line L2,
4 data channels. `--profile sim` builds the default profile (same shape, 32-bit address spaces). Vivado is found through
`$XILINX_VIVADO` or the newest `C:/Xilinx/Vivado/<ver>`; `--vivado DIR` overrides it. Builds and logs go to `sim/build/`
(git-ignored); failing random seeds are kept in `sim/build/rand_fail/`.

| Test | What it checks | Cores used |
|---|---|---|
| `unit` | `alu` (also without `USE_COMB_DIV`), `dcache`, `decoder`, `divider`, `fp32_fma`, `l2_cache` (+ victim write buffer), `pc`, `registers`; self-checking | — |
| `call_ret_branch` | CMP + N/Z/P branches and nested CALL/RET on all 32 threads | 2 |
| `matmul`, `matmul_combdiv` | 5x5 matrix multiply: divergent EXIT, CALL/RET, loops, LDR/STR, DIV through the shared divider / the combinational ALU divide | 2 |
| `rand` | constrained-random programs (integer, FP, shared memory + SYNC, atomics, calls, loops) compared word for word with the Python golden model (`ASIC/scripts/isa.py`); `--lat N` adds random memory latency | 1 (one 16-thread block) |

The random test runs one block on core 0 because generated programs index their private memory with R31, the
block-local thread id; the 2-core tests cover the second core and the shared L2 arbitration. Its hang watchdog is
`--maxcyc` (default 2,000,000 cycles): `tb_random`'s own 400,000 is too short for 16 threads (seed 311 needs 546k).

**Results (2026-11-03, Vivado 2019.1, `TARGET_FPGA`):** `all` 14/14. Random regression with the final RTL: seeds 0-999
at memory latency 0 and at latency 0-6, all 2,000 matching the golden model (seed 311 after raising the watchdog).
Average 17-18k cycles per program; xsim runs about 15k cycles/s per job.

### xsim 2019.1 notes
- Every tool option goes through `--file`: the Windows `.bat` wrappers split arguments at `=`.
- Paths use forward slashes: plusargs pass through Tcl, which eats backslashes.
- Parallel runs each get their own copy of the snapshot: xsim rewrites `xsim.dir/<snapshot>/xsim_script.tcl` on every run.
- The SVA checkers in `src/rtl/sva` are not compiled: xsim 2019.1 rejects `$past` in properties and ignores several
  assertions. `MAHI_SIM_CHECKS` (a plain `$error` in `core.sv`) stays on. SVA coverage is the Verilator flow's.

## Bugs found by the first xsim runs

The three RTL fixes are **only in this tree so far**; `ASIC/src/rtl` still has all three
([ASIC L10](../ASIC/docs/04-limitations.md#l10); `make docs-check` knows the three files).

| # | Where | Kind | What went wrong | Fix |
|---|---|---|---|---|
| 1 | `src/rtl/scheduler.sv` | **real bug** (any simulator, silicon) | lanes waiting at a divergence join point were silently dropped | hold the warp at its join point while an older instruction of it is in ID/EX |
| 2 | `src/rtl/core.sv` | simulation semantics | the issue-time hazard never cleared, every program hung | plain wires instead of a function reading module signals |
| 3 | `src/rtl/pc.sv` | simulation semantics | RET after 8 nested CALLs read X | keep the stack index 3 bits wide |
| 4 | `src/tb/kernels/tb_matmul.sv` | testbench | DCR address port left open: no block ever started | tie it to `8'h00` |
| 5 | `src/tb/ISA/tb_asic_call_ret_branch.sv` | testbench | results stored by block-local thread id: core 1 overwrote core 0 | store at the global id |
| 6 | `src/tb/unit/tb_l2_cache.sv` | testbench | 1-port testbench, 2-port L2 in this profile | `#(.NUM_PORTS(1))` |

Bugs 2-6 never showed under Verilator because it is 2-state (an open input reads 0, an out-of-range read returns some
element) and schedules combinational logic statically from the netlist, not by IEEE events. xsim follows the IEEE event
and 4-state rules. Bug 1 is different: it is wrong logic, so Verilator should show it on the same programs (not checked:
there is no Verilator on this machine).

### 1. Lanes lost at a fall-through join (`scheduler.sv`)

**How divergence works here.** When a branch splits a warp, the scheduler keeps running one lane group (`mask_a` at
`target_a`) and pushes the other (`{target_b, mask_b}`) on the warp's 4-entry divergence stack. Every non-divergent
instruction in EX is then checked: if its next PC equals the stack-top PC, the running group has reached the parked
group, and the scheduler merges them (`current_mask <= mask_a | stack_mask[top]`, pop, flush the warp).

**The gap.** A warp may not issue while one of its *serializing* instructions (branch, CALL/RET/EXIT, SYNC, memory,
atomics, FP, DIV) is in ID or EX, because those redirect the warp. A plain ALU instruction is not serializing, so the
next instruction of the same warp issues right behind it. But an ALU instruction can reach the join point by falling
through (its PC + 1 is the stack-top PC). When the merge happens, with the ALU instruction in EX, the join-point
instruction is already in ID with the **pre-merge** mask. The merge's flush is a registered signal, so it acts one cycle
later; by then that instruction has moved into EX, and the flush only stops it at the EX-to-MEM step. Its EX-stage side
effects still happen, and nothing in EX is gated by the flush:
- if it is a branch, the scheduler sets `current_mask <= mask_a` from the stale mask, overwriting the merged mask; the
  lanes that were parked on the stack are now in no mask and not on the stack, so they never run again;
- the per-lane PC module (`enable = ex_active_mask[i]`) can push or pop the call stack or set the NZP flags, and an FP
  or DIV op can launch, before the instruction is squashed and re-issued with the merged mask.

The warp still reaches EXIT with its remaining lanes, so nothing hangs: results are just missing.

**Seen on** random seeds 227 and 294 (4 warps), 2 of the first 600, at every memory latency. Seed 227, warp 2 (mask bits
are lanes 3..0; thread id = 4 x warp + lane):
```
t=966845  0x5e  DIVERGE     lane 2 runs on at 0x5f, lane 3 parks at 0x59 (stack top)
          ...   lane 2 runs alone (mask 0100) through calls and loops
t=973405  0x58  RECONVERGE  ALU op falls through to 0x59 = stack top: mask := 1100, pop
t=973415  0x59  BRANCH      issued before the merge with mask 0100: mask := 0100   -> lane 3 (thread 11) lost
```
Thread 10 was lost the same way at another join, so seed 227 missed 35 words of their register dumps and 5 atomic sums
they never added. Seed 294 showed only 2 wrong atomic sums; I did not trace it cycle by cycle (the call-stack side effect
above would explain it), and it passes with the fix. The bug needs the join-point instruction to issue in the very next
cycle, so no other warp may be ready then; that is why it is rare.

**Fix.** The scheduler does not issue a warp whose next PC is its stack-top PC while an older instruction of that warp
is still in ID or EX:
```systemverilog
// core.sv: any instruction of warp w in ID or EX
assign warp_in_pipe[w] = ((|id_active_mask) && id_warp_id == w) || ((|ex_active_mask) && ex_warp_id == w);
// scheduler.sv, warp selection
at_join = warp_in_pipe[check_w_var] && stack_ptr[check_w_var] > 0 &&
          current_pc[check_w_var] == stack_pc[check_w_var][stack_ptr[check_w_var] - 1'b1];
if (... && !warp_in_flight[check_w_var] && !at_join) ...   // pick this warp
```
Once the older instruction has passed EX the merge has happened (or not) and issue resumes, so it cannot deadlock: the
hold needs an instruction in flight, and that always drains. Cost: one or two bubbles at each fall-through join (not
measured separately).

### 2. Issue-time hazard never re-evaluated (`core.sv`)

```systemverilog
// before
function automatic logic reads_pending(input logic [4:0] r);
    reads_pending = (id_writes && r == id_rd) || (ex_writes && r == ex_rd);   // id_*, ex_* read from module scope
endfunction
wire issue_hazard = (iss_rs_re && reads_pending(iss_rs)) || ...;
// after
wire rs_pending = (id_writes && iss_rs == id_rd) || (ex_writes && iss_rs == ex_rd);   // same for rt, rd
wire issue_hazard = (iss_rs_re && rs_pending) || (iss_rt_re && rt_pending) || (iss_rd_re && rd_pending);
```
An `assign` (like `always @*`) is re-evaluated only when an operand of its own expression changes; a function's
arguments count, signals the function body reads from the module do not. So when the producing instruction left EX,
`id_writes`/`ex_writes` changed but `issue_hazard` stayed 1, and the warp waited forever. Every random program hung at
its first dependent pair (`MUL R28, R31, R26` then `ADD R28, R28, R26` at PC 0xa). Verilator orders the logic from the
netlist, and synthesis flattens the function, so both produce the correct gate logic. (`always_comb` would also have
been correct: it is sensitive to signals read inside called functions.)

### 3. RET index out of range at stack pointer 0 (`pc.sv`)

```systemverilog
next_pc = return_stack[warp_id][stack_ptr[warp_id] - 1];      // before
next_pc = return_stack[warp_id][stack_ptr[warp_id] - 1'b1];   // after
```
An index expression is sized by its own operands. `1` is a 32-bit integer, so `stack_ptr - 1` is 32 bits wide and at
`stack_ptr = 0` it is -1: out of range, and the IEEE result is X. With `1'b1` the expression is 3 bits wide and wraps
to entry 7, which is the behaviour the docs promise (the 8-deep call stack wraps, ASIC L6). Verilator and Yosys truncate
the index, so they already wrapped. It only matters right after exactly 8 nested CALLs (the `tb_pc` unit test does
that). The scheduler's similar `stack_ptr - 1` indexes are all guarded by `stack_ptr > 0`.

### 4-6. Testbench fixes
- **`tb_matmul`** did not connect `device_control_address`. An open input is `z` in a 4-state simulator, so the DCR's
  `address == 8'h00` check was never true, the thread count stayed 0 and the dispatcher had no block to start: a
  timeout. Verilator reads an open input as 0 (and the ASIC Makefile waives `PINMISSING`). Now tied to `8'h00`, as the
  other testbenches do.
- **`tb_asic_call_ret_branch`** stored each result at `d_mem[R31]`, but R31 is the block-local thread id. In the 1-core
  ASIC profile there is one block, so it worked; here 32 threads are 2 blocks on 2 cores, and core 1 wrote over core 0's
  words while words 16-31 stayed 0. It now computes the global id `R29*R30 + R31` (block id x threads per block + local
  id) and uses it for the compare and the store.
- **`tb_l2_cache`** drives one upstream port, but `l2_cache` defaults to one port per core (2 here); xsim rejects the
  width mismatch that Verilator only warns about. Pinned to `#(.NUM_PORTS(1))`.
- **`tb_random`'s watchdog** (400,000 cycles) is too short for 16 threads: seed 311 needs 546k (warp 3 runs 10 times the
  loop trips of warp 0, which waits at a barrier meanwhile). The driver passes `+maxcyc=2000000`.
