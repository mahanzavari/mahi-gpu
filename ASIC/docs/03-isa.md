# 03 — ISA as implemented (ASIC profile)

> Verified against commit `dadec7f` (+ uncommitted docs), 2026-10-21. Authoritative sources: `src/rtl/decoder.sv` (encoding, control),
> `alu.sv`, `fp32_fma.sv`, `pc.sv`, `registers.sv`, `lsu.sv`. The executable specification is `scripts/isa.py`
> (golden model); `scripts/test_model.py` checks it against hand-computed values and the DUT is compared against it
> by `make rand`. For the generic programming model see the root README.

## Encoding (32-bit words)
```
R-type : [31:26] opcode | [25:21] rd | [20:16] rs | [15:11] rt | [10:0] unused
I-type : [31:26] opcode | [25:21] rd | [20:16] rs | [15:0]  imm16 (sign-extended)
BR     : [31:26] =1     | [25:23] nzp mask | [22:16] unused | [15:0] absolute target PC (imm16)
CALL   : [31:26] =13    | [15:0] absolute target PC            RET/EXIT/SYNC: opcode only
LUI    : [31:26] =29    | [25:21] rd | [20:1] imm20 -> value = imm20 << 12
```
Quirk: **for `STR` and `STSH` the register holding the value to store is in the `rd` slot** (`decoder.sv:64-68`);
`rs` is the address register. For `LDR` the destination is `rd`, address `rs + sext(imm16)`.
Branch/call targets are absolute and truncated to `PROGRAM_MEM_ADDR_BITS` (12) in the ASIC profile.

## Opcodes
<!-- BEGIN GENERATED: opcodes -->
NOP=0 BRnzp=1 CMP=2 ADD=3 SUB=4 MUL=5 DIV=6 LDR=7 STR=8 CONST=9 SYNC=10 LDSH=11 STSH=12 CALL=13 RET_FN=14 EXIT=15 ATOM_ADD=16 AND=17 OR=18 XOR=19 SHL=20 SHR=21 MOD=22 MIN=23 MAX=24 ABS=25 NEG=26 MAC=27 ATOM_CAS=28 LUI=29 POPCNT=30 CLZ=31 BREV=32 FADD=33 FSUB=34 FMUL=35 FMA=36
<!-- END GENERATED: opcodes -->
Opcodes 37–63 are reserved and decode as **inert** (no side effects) — checked by `unit-decoder`.

## Semantics
All integer values are 32-bit. "signed" = two's complement.

| Group | Instruction | Semantics |
|---|---|---|
| Integer | `ADD SUB` | wrap-around |
| | `MUL` | low 32 bits of signed product |
| | `DIV MOD` | **unsigned**; `rt==0` raises a fault (cause 1, [L12](04-limitations.md#l12)); multi-cycle on the shared iterative divider, up to 33 cycles per active lane while the warp waits ([L2](04-limitations.md#l2)) |
| | `AND OR XOR` | bitwise |
| | `SHL SHR` | logical; shift count ≥ 32 gives 0 |
| | `MIN MAX` | signed compare |
| | `ABS NEG` | signed; `ABS(0x80000000)=0x80000000` |
| | `MAC` | `rd = rd + rs*rt` (signed, low 32 bits); reads `rd` |
| | `POPCNT CLZ BREV` | popcount; leading zeros (`CLZ(0)=32`); bit reverse |
| | `CONST rd, imm16` | `rd = sext(imm16)` |
| | `LUI rd, imm20` | `rd = imm20 << 12` |
| Compare/branch | `CMP rs, rt` | writes this lane's NZP = `{rs<rt, rs==rt, rs>rt}` — **unsigned** compare ([L5](04-limitations.md#l5)) |
| | `BRnzp mask, target` | taken iff `(NZP & mask) != 0`. NZP resets to 0, so **a branch executed before any `CMP` is never taken, even with mask `111`** |
| | `CALL t / RET_FN` | per-lane return stack, 8 deep ([L6](04-limitations.md#l6)); `RET` with an empty stack is undefined |
| | `EXIT` | ends the lane; if the warp's divergence stack is non-empty the next group resumes |
| | `SYNC` | block barrier across **warps**; only correct under warp-uniform execution ([L1](04-limitations.md#l1)) |
| Global memory | `LDR rd,[rs+imm]` / `STR rv,[rs+imm]` | word addressed; fault if address > `0xFFFF`, **but the bus is 14 bits so `0x4000-0xFFFF` silently alias** ([L14](04-limitations.md#l14)) |
| Shared memory | `LDSH rd,[rs]` / `STSH rv,[rs]` | 64 words, **no offset**; fault if address ≥ 64 |
| Atomics (global) | `ATOM_ADD rd,rs,rt` | `old = mem[rs]; mem[rs] = old + rt; rd = old`; lanes serialised |
| | `ATOM_CAS rd,rs,rt` | `old = mem[rs]; if old == rd_value then mem[rs] = rt; rd = old` (rd is also an input) |
| Floating point | `FADD FSUB FMUL FMA` | `a=rs, b=rt, c=rd`: `a+b`, `a−b`, `a*b`, `a*b+c`; truncating, denormal inputs/outputs flush to 0, exponent 255 treated as an ordinary number (no NaN/Inf) — bit-exact port in `isa.py:fma_bits` ([L8](04-limitations.md#l8)) |

## Registers
32 per lane per warp, 32-bit. `R0–R28` general, **writes to `R29–R31` are ignored**:
`R29` = block id (low 8 bits), `R30` = `THREADS_PER_BLOCK × NUM_WARPS` (=8), `R31` = `warp*4 + lane` (`registers.sv:81-90`).
All `R0–R28` reset to 0. Same-cycle write→read is forwarded inside the register file and by the core's forwarding network.
Write-port priority when several results target the same register: FP > LSU > ALU (`registers.sv`); a per-warp scoreboard stalls
instructions that read an FP result still in flight.

## Condition flags
The ALU also produces C/V/Z/N/SAT flags (`alu.sv`), stored per warp/lane in `core.sv:386-390`, but **no instruction reads them**;
branches use only NZP.

## Faults
Division by zero and out-of-range memory addresses mark the **warp** `FAULTED` and flush it; the fault is **not visible outside
the core** ([L12](04-limitations.md#l12)).
