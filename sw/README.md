# mahi-gpu software stack

Option A of the software plan: assembler, runtime, kernel library and a tiny training framework. The goal is to train
a small neural network (tens of parameters) entirely in GPU kernels, with the same results on the golden model, in
RTL simulation and, later, on the FPGA.

| Layer | Where | Status |
|---|---|---|
| Assembler v2 | `mahi/asm.py` | done (M1) |
| Runtime: device memory, launch; `golden` / `verilator` / `xsim` backends | `mahi/runtime.py` | done (M2); `xsim` written but not yet run (needs Vivado) |
| Kernel library | `kernels/*.s` | `vadd`, `matvec` (FMA, linear layer), `reduce_sum` (shared memory + SYNC) |
| NN kernels and the training framework | — | next (M3–M6) |
| FPGA board backend | — | after board bring-up (M7) |

## Quick start
```
python3 -m mahi.asm kernels/vadd.s -o build/vadd -l      # from sw/: prog.hex, dmem.hex, map.json, listing
python3 tests/test_asm.py                                 # assembler
python3 tests/test_kernels.py                             # kernels: golden (+ verilator if installed)
MAHI_BACKENDS=golden,xsim python3 tests/test_kernels.py   # on the Vivado machine
MAHI_PROFILE=asic_mini python3 tests/test_kernels.py      # profiles: fpga (default), sim, asic, asic_mini
```
```python
import numpy as np
from mahi import Device, assemble_file
dev = Device('verilator')                                 # 'golden' | 'verilator' | 'xsim'; profile='fpga' by default
k = assemble_file('kernels/vadd.s')
a, b, c = dev.alloc(16), dev.alloc(16), dev.alloc(16)
dev.write(a, np.arange(16, dtype=np.float32)); dev.write(b, np.ones(16, np.float32))
r = dev.launch(k, threads=16, a=a, b=b, c=c, n=16)
print(dev.read(c), r.cycles)
```

## Conventions (the kernel ABI)
- **Data memory** (the 1024 words of the simulation harness): words 0..15 are the **parameter block**, the kernel's
  `.data` section starts at word 16, the runtime heap at word 512 (`Device(heap_base=...)`).
- **Kernel arguments** are declared with `.param a, b, n`; each gets one word of the parameter block, in order, and the
  symbol is that word's address. A kernel reads them with `LDR r, rz, a` where `rz` holds 0. `Device.launch(k, threads,
  a=buf, n=16, lr=0.01)` writes them: buffers as their address, ints as is, Python floats as FP32 bits.
- **Thread ids**: `bid` (r29) block id, `nthr` (r30) threads per block (the profile's block size, also in a partly
  filled last block), `tid` (r31) thread id in the block; global id = `bid * nthr + tid`. Threads per launch: 1..255.
- **`at` (r28)** is the assembler's temporary: pseudo-instructions (`LI`, `NOT`, `ADDI`, `JMP`) overwrite it.
- **Blocks are independent** within one launch (they run in parallel on the cores; the golden model runs them in order).

## ISA facts a kernel writer needs (see ASIC/docs/03-isa.md, 04-limitations.md)
- `CMP` is unsigned and only it sets N/Z/P; a `BR` before any `CMP` is never taken. `JMP` is `CMP at, at ; BRz`.
- No ALU immediates: constants go through `CONST` (16-bit signed), `LUI`, or the `LI`/`LIF` pseudo-instructions.
- FP32 is `FADD/FSUB/FMUL/FMA` only, truncating, denormals flushed to zero, no NaN/Inf (L8). There is no float
  compare, divide or `exp`. **ReLU is one instruction**: `MAX rd, rs, rzero`, because a float's bit pattern compared as
  a signed integer has the float's sign.
- `SYNC` while a warp is diverged is a fault (L1): keep control flow before every barrier warp-uniform (see
  `kernels/reduce_sum.s`, which masks instead of branching).
- `STR`/`STSH` take the value as their first operand; shared memory (`LDSH`/`STSH`) has no offset.

## Next milestones
| # | Deliverable | Done when |
|---|---|---|
| M3 | NN kernel library: linear forward/backward, ReLU and its gradient, MSE loss and gradient, batch reduction, SGD update; NumPy tests | every kernel within tolerance, golden == RTL bit for bit |
| M4 | XOR 2-4-1 training with one kernel per op + `mahi.nn` (`Tensor`, `Linear`, `ReLU`, `MSELoss`, `SGD`) | loss falls, all 4 XOR outputs right; golden and RTL loss curves identical |
| M5 | fused training-step kernel, cycle and stall report | same weights as M4, fewer host round trips |
| M6 | 1-8-1 curve fit with a 16-sample batch | MSE below target vs NumPy float32 |
| M7 | FPGA board backend | M4-M6 on the board match simulation |
