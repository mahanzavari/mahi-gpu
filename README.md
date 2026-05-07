# Mahi GPU

A minimal GPU implementation in Verilog optimized for learning about how GPUs work from the ground up.

## Table of Contents

- [Overview](#overview)
- [Architecture](#architecture)
  - [GPU](#gpu)
  - [Memory](#memory)
  - [Core](#core)
- [ISA](#isa)
- [Execution Pipeline](#execution-pipeline)
  - [Stages](#stages)
  - [Thread Data Path](#thread-data-path)
- [Kernels](#kernels)
  - [Matrix Multiplication](#matrix-multiplication)
- [Simulation](#simulation)
- [Advanced Functionality](#advanced-functionality)
- [Next Steps](#next-steps)

## Overview

If you want to learn how a CPU works all the way from architecture to control signals, there are many resources online to help you.

GPUs are not the same.

Because the GPU market is so competitive, low-level technical details for all modern architectures remain proprietary.

While there are lots of resources to learn about GPU programming, there is almost nothing available to learn about how GPUs work at a hardware level.

This is why I built `mahi-gpu`.

Special thanks to [tiny-gpu](https://github.com/adam-maj/tiny-gpu) for providing inspiration and a foundation for understanding simple GPU architectures.

## What is mahi-gpu?

**mahi-gpu** is a minimal GPU implementation optimized for learning about how GPUs work from the ground up.
Specifically, with the trend toward general-purpose GPUs (GPGPUs) and ML-accelerators like Google's TPU, mahi-gpu focuses on highlighting the general principles of all of these architectures, rather than on the details of graphics-specific hardware.

With this motivation in mind, we can simplify GPUs by cutting out the majority of complexity involved with building a production-grade graphics card, and focus on the core elements that are critical to all of these modern hardware accelerators.

<!-- This project is primarily focused on exploring:

1. **Architecture** - What does the architecture of a GPU look like? What are the most important elements?
2. **Parallelization** - How is the SIMD programming model implemented in hardware?
3. **Memory** - How does a GPU work around the constraints of limited memory bandwidth?
4. **Pipelining** - How are instructions streamed continuously to maximize hardware utilization? -->

After understanding the fundamentals laid out in this project, you can check out the [advanced functionality section](#advanced-functionality) to understand some of the most important optimizations made in production-grade GPUs.

## Architecture

### GPU Card

<p align="center">
  <img src="/docs/PNG/GPU_card.png" alt="GPU" width="48%">
</p>

</br><br>

The GPU is built to execute a single kernel at a time.

In order to launch a kernel, we need to do the following:

1. Load global program memory with the kernel code
2. Load data memory with the necessary data
3. Specify the number of threads to launch in the device control register
4. Launch the kernel by setting the start signal to high.

The GPU itself consists of the following units:

1. Device control register
2. Dispatcher
3. Variable number of compute cores
4. Memory controllers for data memory and program memory

### Device Control Register

The device control register stores metadata specifying how kernels should be executed on the GPU. In this implementation, it stores the `thread_count` - the total number of threads to launch for the active kernel.

### Dispatcher

Once a kernel is launched, the dispatcher manages the distribution of threads to different compute cores. It organizes threads into groups that can be executed in parallel on a single core called **blocks** and sends these blocks off to be processed by available cores.

### Memory

The GPU is built to interface with an external global memory. Data memory and program memory are separated for simplicity.

#### Global Memory

The data memory has the following specifications:
- 32-bit addressability
- 32-bit data (grouped into 128-bit blocks for caches)

The program memory has the following specifications:
- 32-bit addressability
- 32-bit data (each instruction is 32 bits as specified by the ISA)

#### Cache Hierarchy (L1)

To reduce latency, each core features dedicated L1 caches:
- **Instruction Cache (I-Cache):** Caches 128-bit blocks (4 instructions per block) from program memory.
- **Data Cache (D-Cache):** A Write-Through/Write-Update cache that manages 128-bit blocks of data, drastically speeding up global memory accesses.

#### Shared Memory

Each core has a shared memory block for faster communication and data sharing among threads of the same block, similar to NVIDIA GPU architectures.

#### Memory Controllers

Global memory has fixed read/write bandwidth, but there may be far more incoming requests across all cores. The memory controllers handle arbitration using a round-robin system to manage outgoing requests from the L1 caches, throttling them based on actual external memory bandwidth.

### Core

Each core processes one block at a time. For each thread in a block, the core has a dedicated ALU, LSU, PC, and register file. Additionally, the core contains a scheduler that manages warp execution and handles control flow divergence and hardware exceptions.

#### Scheduler

The scheduler manages the continuous flow of instructions into the pipeline. Because the core is pipelined and supports multiple warps, the scheduler dynamically monitors execution to handle:

- **Data and structural hazards**: Freezing the frontend when asynchronous global memory accesses stall the backend (waiting for memory).
- **Branching and divergence**: Monitoring the Execute stage for branch instructions and flushing the pipeline if a jump is taken. Individual threads can diverge; the scheduler tracks per-thread program counters and active masks to serialize divergent paths.
- **Synchronization**: Supporting `SYNC` instructions as a barrier across warps within a block. The scheduler counts arriving warps and releases them when all active warps have reached the barrier.
- **Warp scheduling**: Round-robin selection of ready warps to issue instructions, maximizing utilization even when some warps are stalled on memory or barriers.
- **Exception Handling**: Trapping faults (like divide-by-zero or out-of-bounds memory access) and isolating the offending warp into a `FAULTED` state to prevent memory corruption while letting other warps safely complete.

#### Thread Units
- **Fetcher**: Asynchronously fetches the instruction at the current program counter via the L1 Instruction Cache.
- **Decoder**: Purely combinational unit that translates 32-bit instructions into pipeline control signals.
- **Register Files**: Each thread has its own dedicated register file, holding general-purpose registers and read-only special registers (`%blockIdx`, `%blockDim`, `%threadIdx`), enabling the SIMD pattern.
- **ALUs**: Dedicated arithmetic-logic unit for each thread, supporting standard arithmetic, bitwise logic, and advanced shader math operations (`MIN`, `MAX`, `ABS`, `NEG`).
- **LSUs**: Dedicated load-store unit for each thread. Handles global data, shared memory, and atomic memory operations (`ATOM_ADD`), providing hardware-level serialization for data consistency.

## ISA

| Mnemonic   | Opcode | Type | Notes |
|:----------:|:------:|:----:|:-----:|
| `NOP`      | 0      | —    | No operation |
| `BRnzp`    | 1      | I    | Conditional branch on NZP flags |
| `CMP`      | 2      | R    | Compare rs, rt → update NZP |
| `ADD`      | 3      | R    | rd = rs + rt |
| `SUB`      | 4      | R    | rd = rs - rt |
| `MUL`      | 5      | R    | rd = rs * rt |
| `DIV`      | 6      | R    | rd = rs / rt (Throws DIV0 Exception) |
| `LDR`      | 7      | R    | rd = MEM[rs + offset] |
| `STR`      | 8      | R    | MEM[rs + offset] = rt |
| `CONST`    | 9      | I    | rd = sign/zero-extended immediate |
| `SYNC`     | 10     | —    | Barrier synchronization |
| `LDSH`     | 11     | R    | Load from shared memory |
| `STSH`     | 12     | R    | Store to shared memory |
| `CALL`     | 13     | I    | Function call (pushes return address) |
| `RET_FN`   | 14     | —    | Function return (pops return address) |
| `EXIT`     | 15     | —    | Thread termination |
| `ATOM_ADD` | 16     | R    | Atomic addition to global memory |
| `AND`      | 17     | R    | Bitwise AND |
| `OR`       | 18     | R    | Bitwise OR |
| `XOR`      | 19     | R    | Bitwise XOR |
| `SHL`      | 20     | R    | Shift Left |
| `SHR`      | 21     | R    | Shift Right |
| `MOD`      | 22     | R    | rd = rs % rt |
| `MIN`      | 23     | R    | rd = min(rs, rt) |
| `MAX`      | 24     | R    | rd = max(rs, rt) |
| `ABS`      | 25     | R    | rd = abs(rs) |
| `NEG`      | 26     | R    | rd = -rs |

## Instruction Format

All instructions are 32 bits.

```text
31        26 25    21 20    16 15    11 10              0
+------------+--------+--------+--------+---------------+
|  OPCODE    |   RD   |   RS   |   RT   |    UNUSED     |  (R-type)
+------------+--------+--------+--------+---------------+

31        26 25    21 20    16 15                       0
+------------+--------+--------+------------------------+
|  OPCODE    | RD/NZP |   RS   |     IMMEDIATE[15:0]    |  (I-type: BR, CONST, CALL, LDR, STR)
+------------+--------+--------+------------------------+
```

For `LDR` and `STR`, the immediate 16-bit offset is taken and added to the address computed from `rs`.

## Registers

Each thread has 32 registers (32-bit width):

- General-purpose registers (R0–R28) — readable and writable
- Read-only special registers (R29–R31) — automatically set, not writable by the program

These special registers mirror CUDA-style registers that allow each thread to know:
1. Which block it belongs to
2. How many threads exist in the block
3. Which thread index it is

| Register Index | Name (Conceptual) | Width | Read/Write | Initialization | Purpose |
|:--------------:|:----------------:|:-----:|:----------:|:--------------:|---------|
| 0–28           | General Purpose Registers (GPRs) | 32-bit | R/W | Zero | Used for arithmetic, memory ops, constants, etc. |
| 29             | %blockIdx        | 32-bit | Read-only | Set to block_id | Identifies which block this thread belongs to |
| 30             | %blockDim        | 32-bit | Read-only | Constant = THREADS_PER_BLOCK * WARPS | Number of threads per block |
| 31             | %threadIdx       | 32-bit | Read-only | Constant = THREAD_ID | Thread index within the block |

## Execution Pipeline

The core implements a classic 5-stage RISC pipeline with hardware forwarding and warp-level scheduling, allowing multiple instructions to be processed simultaneously across different stages.

<p align="center">
  <img src="/docs/PNG/core_blockvsdx.png" alt="Core" width="60%">
</p>

### Stages

1. **IF (Instruction Fetch)**: The Fetcher requests the 32-bit instruction at the current PC from the I-Cache.
2. **ID (Instruction Decode)**: The Decoder translates the instruction into control signals. The register file is read asynchronously, and forwarding paths are applied.
3. **EX (Execute)**: The ALU performs arithmetic or comparisons. Branch targets and conditions are evaluated here. Hardware faults (memory bounds, DIV0) are detected here, tripping the pipeline into an exception state.
4. **MEM (Memory Access)**: The LSU performs asynchronous reads/writes to global or shared memory via the D-Cache, as well as complex serialized `ATOM_ADD` actions.
5. **WB (Write Back)**: The result from the ALU or LSU is written back synchronously to the register file.

### Hardware Data Forwarding

The pipeline includes forwarding logic that bypasses the register file when a later stage (MEM or WB) has a pending write to a register that is being read in the EX stage. This eliminates the need for compiler-inserted NOPs for most arithmetic dependencies.

### Branch Divergence Handling

The scheduler maintains per-thread architectural and speculative program counters along with an active mask. When a branch occurs, threads that take the branch continue along the new path while others are masked out. Divergent control flow is serialized by the scheduler, which resynchronizes threads when they reconverge.

## Kernels

### Matrix Multiplication

The following kernel performs a 5x5 matrix multiplication \( C = A \times B \).

**Assembly program** (addresses shown as PC):

```asm
// --- MAIN KERNEL ---
// R29 = %blockIdx, R31 = %threadIdx, R30 = %blockDim
0:  CONST R7, 16                // R7 = 16
1:  MUL   R0, R29, R7           // R0 = blockIdx * 16
2:  ADD   R0, R0, R31           // R0 = global thread ID

// Bounds check: if (R0 < 25) goto MAIN_BODY, else EXIT
3:  CONST R1, 25
4:  CMP   R0, R1
5:  BRn   7                     // branch to MAIN_BODY if R0 < 25
6:  EXIT                        // threads 25-31 diverge and terminate

// MAIN_BODY: compute row = R0 / 5, col = R0 % 5
7:  CONST R4, 5
8:  DIV   R2, R0, R4            // R2 = row
9:  MUL   R3, R2, R4            // R3 = row * 5
10: SUB   R3, R0, R3            // R3 = col

// Call dot_product(row, col) -> returns result in R5
11: CALL  16                    // jump to subroutine at PC=16

// Store result to C[global_id]
12: CONST R7, 50                // base address of C
13: ADD   R7, R7, R0
14: STR   [R7+0], R5
15: EXIT

// --- SUBROUTINE: DOT_PROD (PC = 16) ---
// Computes R5 = sum_{k=0}^{4} A[row*5 + k] * B[k*5 + col]
16: CONST R5, 0                 // accumulator = 0
17: CONST R6, 0                 // k = 0

// LOOP_START: if (k < 5) loop else RET_FN
18: CMP   R6, R4                // compare k with 5
19: BRn   21                    // if k < 5 goto LOOP_BODY
20: RET_FN                      // return to caller (PC=12)

// LOOP_BODY
21: MUL   R8, R2, R4            // R8 = row * 5
22: ADD   R8, R8, R6            // R8 = A_addr = row*5 + k
23: CONST R7, 25                // base of B
24: MUL   R9, R6, R4            // R9 = k * 5
25: ADD   R9, R9, R7            // R9 = base_B + k*5
26: ADD   R9, R9, R3            // R9 = B_addr = base_B + k*5 + col
27: LDR   R8, [R8+0]            // R8 = A_val
28: LDR   R9, [R9+0]            // R9 = B_val
29: MUL   R10, R8, R9           // R10 = A_val * B_val
30: ADD   R5, R5, R10           // accumulator += product
31: CONST R7, 1
32: ADD   R6, R6, R7            // k = k + 1
33: BRnzp 18                    // jump back to LOOP_START
```

## Simulation

The GPU is set up to simulate the execution of the above kernel. You can run the kernel simulations within tools like Xilinx Vivado or Altera Quartus.

Executing the simulations will output a text console trace consisting of scheduler events, exception traps, pipeline stage progress, memory controller handshakes, cache hits/misses, and register writes.

## Advanced Functionality

Features implemented to emulate modern hardware functionality:

### Cache Hierarchy
The GPU includes L1 Instruction and Data Caches, minimizing external requests over the memory controllers and dramatically improving throughput on repetitive or localized memory access patterns.

### Memory Fault & Exception Handling
If an instruction requests a global array operation out-of-bounds or attempts to divide by zero, the EX pipeline stage correctly flags an exception. The scheduler catches this, flushes the offending warp's speculative instruction path, and moves the warp to an isolated `FAULTED` state preventing memory corruption.

### Atomic Memory Access
Hardware atomic functions (`ATOM_ADD`) allow multi-threading patterns like global counter increments without race conditions.