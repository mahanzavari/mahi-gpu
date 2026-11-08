# mahi-gpu software stack

Option A of the software plan: assembler, runtime, kernel library and a tiny training framework. The goal is to train
a small neural network (tens of parameters) entirely in GPU kernels, with the same results on the golden model, in
RTL simulation and, later, on the FPGA.

| Layer | Where | Status |
|---|---|---|
| Assembler v2 | `mahi/asm.py` | done (M1) |
| Runtime: device memory, launch; `golden` / `verilator` / `xsim` backends | `mahi/runtime.py` | done (M2); `xsim` written but not yet run (needs Vivado) |
| Kernels: `vadd`, `matvec`, `reduce_sum` | `kernels/*.s` | done |
| NN kernels: `linear_fwd`, `linear_bwd_x`, `linear_bwd_w`, `relu_fwd`, `relu_bwd`, `mse`, `sgd` | `kernels/*.s` | done (M3) |
| Framework: `MLP` (any depth, one launch per op), `RefMLP` (NumPy float32 reference) | `mahi/nn.py` | done (M4) |
| Fused training kernel `mlp_train` (one hidden layer, N steps per launch) + `FusedMLP` | `kernels/mlp_train.s`, `mahi/nn.py` | done (M5) |
| Examples: XOR (2-4-1, 17 params), sin(x) fit (1-8-1, 25 params, 16 samples) | `examples/` | done (M4, M6) |
| Benchmark suite: 46 kernels, RTL performance probes, findings/oversight report | `bench/` | done ([bench/README.md](bench/README.md), [baseline report](bench/baseline/fpga/report.md)) |
| FPGA board backend | — | after board bring-up (M7) |

## Results (profile `fpga`: 2 cores x 4 warps x 4 lanes; RTL = Verilator simulation of FPGA/src/rtl)
| Run | Steps | Result | RTL vs golden model | GPU cycles |
|---|---|---|---|---|
| XOR, unfused (`examples/xor.py`) | 600 | loss 0.000000, outputs [0, 1, 1, 0] | losses and weights bit-identical | 5.61 M (9,354/step, 12 launches/step) |
| XOR, fused (`--fused`) | 600 | same | same weights as unfused | 2.67 M (4,443/step, 6 launches in all) |
| sin(x), unfused (`examples/sine.py`) | 3,000 | MSE 0.0044 (target 0.01), max error 0.144 | bit-identical | 78.0 M (26,012/step) |
| sin(x), fused (`--fused`) | 3,000 | same | bit-identical | 69.6 M (23,216/step, 6 launches in all) |

The GPU's FP32 truncates and flushes denormals (ASIC L8); against the same network in NumPy float32 the loss differs by
at most 6e-7 (XOR) and 3e-6 (sine) over the whole run. At the ASIC's 25 MHz, the fused XOR training is about 0.1 s of
chip time.

## Quick start
```
python3 -m mahi.asm kernels/vadd.s -o build/vadd -l      # from sw/: prog.hex, dmem.hex, map.json, listing
python3 tests/test_asm.py                                 # assembler
python3 tests/test_kernels.py                             # kernels: golden (+ verilator if installed)
python3 tests/test_nn.py                                  # NN kernels, training steps, fused == unfused
python3 examples/xor.py --compare golden,verilator        # train XOR on the golden model and the RTL
python3 examples/sine.py --fused --backend verilator      # fused training kernel
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

## Benchmarks

`python sw/bench/run.py` runs 46 micro and application kernels on the golden model and on the RTL with
simulation-only performance probes. It writes a report with an issue-slot breakdown, a roofline, cache and LSU
metrics, latency sensitivity, and rule-based oversight flags. See [bench/README.md](bench/README.md). Headline findings
(baseline report):
- **Atomics are not coherent across cores.** `ATOM_ADD` from both cores onto one cache line loses updates.
- **FP instructions block their warp until writeback** (`WAITING_FP`), so independent FMAs of one warp never overlap.
  The best case reaches 6.75 of 16 FLOP/cycle.
- **The LSU is the memory bottleneck.** It handles one line at a time per core and blocks the warp. Bandwidth is
  1.2 B/cycle from L2 or DRAM, a store costs about 33 LSU cycles per line (write-through), and 100% of added DRAM
  latency shows up in the runtime.

## Next
- **M7, FPGA board backend:** a `Device('fpga')` backend that loads program and data memory over the board's host link
  (UART-to-Wishbone bridge or Zynq AXI), launches, and reads back; then XOR and sine on the board, bit-identical to
  the simulation.
- On the Vivado machine: `MAHI_BACKENDS=golden,xsim python tests/test_kernels.py` and `tests/test_nn.py` to validate
  the `xsim` backend (4-state simulation is a useful second opinion).
- Later: a Python kernel builder (generate kernels like `mlp_train` instead of writing them by hand), more layers in
  the fused kernel, a softmax-free classifier example.
