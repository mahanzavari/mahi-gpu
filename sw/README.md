# sw: the mahi software stack

Shared by the ASIC and FPGA builds: both run the same ISA, only the profile (cores, warps, lanes, memory sizes)
differs.

| Path | What |
|---|---|
| [isa/mahi.toml](isa/mahi.toml) | **The ISA definition**: fields, formats, opcodes, operand roles, decoder control signals, semantics, profiles, open questions. The only place encodings are written down. |
| [isa/ISA.md](isa/ISA.md) | Reference generated from `mahi.toml` (`python sw/isa/check.py --update`). |
| [isa/mahi_isa.py](isa/mahi_isa.py) | `mahi.toml` as Python objects: `ISA.encode(...)`, `ISA.decode(word)`, profiles. |
| [isa/check.py](isa/check.py) | Fails when `mahi.toml` disagrees with `decoder.sv` (ASIC and FPGA trees), the golden model `ASIC/scripts/isa.py`, `gpu_pkg.sv` or the chip memory map, or when `ISA.md` is stale. |
| [asm/mahias.py](asm/mahias.py) | Assembler v2: labels, expressions, `.equ`/`.word`/`.org`, pseudo-instructions `MOV`/`JMP`/`LI`, `file:line` errors, listings, `--profile` size checks, hex / hex128 / bin output. |
| [asm/mahidis.py](asm/mahidis.py) | Disassembler; its output reassembles to the identical words for any input. |
| [asm/test_asm.py](asm/test_asm.py) | Round-trip, oracle, legacy and error tests. |

## Use

```bash
python sw/asm/mahias.py assembler/kernels/reduction_sum.asm -o build/k.hex -l build/k.lst --profile fpga
```

```bash
python sw/asm/mahidis.py build/k.hex
```

```bash
python sw/isa/check.py
```

```bash
python sw/asm/test_asm.py
```

Output formats: `hex` (one word per line, the `$readmemh` format of `tb_random` and `ASIC/scripts/gen.py`), `hex128`
(four words per line, word 3 first: the old assembler's AXI format), `bin` (little-endian words).
`ASIC/scripts/docs_check.py` (`make docs-check`) runs `check.py` and a quick `test_asm.py`.

## Changing the ISA

1. Edit `isa/mahi.toml` (opcode, format, syntax, `ctrl`, `sem`).
2. Change `decoder.sv` in **both** RTL trees, and `ASIC/scripts/isa.py` if semantics change.
3. `python sw/isa/check.py --update` regenerates `ISA.md` and must report OK. The assembler and disassembler need no
   changes for a new instruction in an existing format.

## What the tests cover

- **Round trip** `assemble(disassemble(w)) == w`: 200 random encodings per opcode, 50,000 random 32-bit words
  (unknown opcodes and stray bits come back through `.word`) and 200 programs from the random generator `gen.py`.
- **Independent oracle:** 32 hand-written lines are checked against the golden model's own encoders (`enc_R`,
  `enc_I`, `enc_BR`, ...), so a bug shared by `mahi.toml` and the assembler can't hide.
- **Old assembler:** every kernel in `assembler/` assembles to the same words as `assembler/assembler.py`.
- **Errors and warnings:** 19 error cases plus the profile size limit and the warning for a write to `r29`–`r31`.

## Old assembler

The old [assembler/assembler.py](../assembler/assembler.py) is superseded but still accepted. Its source syntax still
assembles (`LDR r1, r2, 4`, `STSH r2, r31, 0`, `BR 7, label`). Its own bugs, which the existing kernels happened not
to hit:

- `CALL` drops its target and encodes 0.
- `ABS` and `NEG` get no source register.
- `ATOM_ADD` encodes its third operand as an immediate instead of `rt`.
- `ATOM_CAS` gets no operands.
- Only lowercase `r` registers parse.
- An unknown mnemonic is silently encoded as `NOP`.

## Open before ISA version 1

Version 0 is the ISA exactly as built. A compiler needs the decisions in the last section of [isa/ISA.md](isa/ISA.md):

| ID | Topic |
|---|---|
| Q1 | Reconvergence |
| Q2 | Word vs byte addressing |
| Q3 | Kernel ABI: arguments, stack, calls, thread count |
| Q4 | Signed compare and true jump |
| Q5 | ALU immediates |
| Q6 | Floating-point completeness |
