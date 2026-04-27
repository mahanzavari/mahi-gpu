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
- 8-bit addressability (256 total rows of data memory)
- 16-bit data

The program memory has the following specifications:
- 8-bit addressability (256 rows of program memory)
- 16-bit data (each instruction is 16 bits as specified by the ISA)

#### Shared Memory

Each core has a shared memory block for faster communication and data sharing among threads of the same block, similar to NVIDIA GPU architectures.

#### Memory Controllers

Global memory has fixed read/write bandwidth, but there may be far more incoming requests across all cores. The memory controllers manage outgoing requests, throttle them based on actual external memory bandwidth, and relay responses back to the proper resources.

### Core

Each core processes one block at a time. For each thread in a block, the core has a dedicated ALU, LSU, PC, and register file. Additionally, the core contains a scheduler that manages warp execution and handles control flow divergence.

#### Scheduler

The scheduler manages the continuous flow of instructions into the pipeline. Because the core is pipelined and supports multiple warps, the scheduler dynamically monitors execution to handle:

- **Data and structural hazards**: Freezing the frontend when asynchronous global memory accesses stall the backend (waiting for memory).
- **Branching and divergence**: Monitoring the Execute stage for branch instructions and flushing the pipeline if a jump is taken. Individual threads can diverge; the scheduler tracks per-thread program counters and active masks to serialize divergent paths.
- **Synchronization**: Supporting `SYNC` instructions as a barrier across warps within a block. The scheduler counts arriving warps and releases them when all active warps have reached the barrier.
- **Warp scheduling**: Round-robin selection of ready warps to issue instructions, maximizing utilization even when some warps are stalled on memory or barriers.

#### Thread Units
- **Fetcher**: Asynchronously fetches the instruction at the current program counter from program memory.
- **Decoder**: Purely combinational unit that translates 16-bit instructions into pipeline control signals.
- **Register Files**: Each thread has its own dedicated register file, holding general-purpose registers and read-only special registers (`%blockIdx`, `%blockDim`, `%threadIdx`), enabling the SIMD pattern.
- **ALUs**: Dedicated arithmetic-logic unit for each thread, supporting addition, subtraction, multiplication, division, and comparisons.
- **LSUs**: Dedicated load-store unit for each thread to access global data memory and shared memory asynchronously.

## ISA

| Mnemonic | Opcode | Type | Notes |
|:--------:|:------:|:----:|:-----:|
| `NOP`    | 0000   | —    | No operation |
| `BRnzp`  | 0001   | I    | Conditional branch on NZP flags |
| `CMP`    | 0010   | R    | Compare rs, rt → update NZP |
| `ADD`    | 0011   | R    | rd = rs + rt |
| `SUB`    | 0100   | R    | rd = rs - rt |
| `MUL`    | 0101   | R    | rd = rs * rt |
| `DIV`    | 0110   | R    | rd = rs / rt |
| `LDR`    | 0111   | R    | rd = MEM[rs + offset] (offset from rt or immediate field) |
| `STR`    | 1000   | R    | MEM[rs + offset] = rt (offset from rd or immediate field) |
| `CONST`  | 1001   | I    | rd = sign/zero-extended immediate |
| `SYNC`   | 1010   | —    | Barrier synchronization (all threads in block wait) |
| `LDSH`   | 1011   | R    | Load from shared memory |
| `STSH`   | 1100   | R    | Store to shared memory |
| `CALL`   | 1101   | I    | Function call (pushes return address) |
| `RET_FN` | 1110   | —    | Function return (pops return address) |
| `EXIT`   | 1111   | —    | Thread termination |

## Instruction Format

All instructions are 16 bits.

```
15        12 11        8 7        4 3         0
+------------+-----------+-----------+-----------+
|  OPCODE    |    RD     |    RS     |    RT     |  (R-type)
+------------+-----------+-----------+-----------+

15        12 11        8 7                                0
+------------+-----------+-------------------------------+
|  OPCODE    |    NZP    |         IMMEDIATE[7:0]        |  (I-type: BR, CONST, CALL)
+------------+-----------+-------------------------------+
```

For `LDR` and `STR`, the offset is taken from the `rt` field (for `LDR`) or `rd` field (for `STR`) and zero-extended to 8 bits.

## Registers

Each thread has 16 registers:

- 13 general-purpose registers (R0–R12) — readable and writable
- 3 read-only special registers (R13–R15) — automatically set, not writable by the program

These special registers mirror CUDA-style registers that allow each thread to know:
1. Which block it belongs to
2. How many threads exist in the block
3. Which thread index it is

| Register Index | Name (Conceptual) | Width | Read/Write | Initialization | Purpose |
|:--------------:|:----------------:|:-----:|:----------:|:--------------:|---------|
| 0–12           | General Purpose Registers (GPRs) | DATA_BITS | R/W | Zero | Used for arithmetic, memory ops, constants, etc. |
| 13             | %blockIdx        | DATA_BITS | Read-only | Set to block_id on reset and every cycle | Identifies which block this thread belongs to |
| 14             | %blockDim        | DATA_BITS | Read-only | Constant = THREADS_PER_BLOCK | Number of threads per block |
| 15             | %threadIdx       | DATA_BITS | Read-only | Constant = THREAD_ID | Thread index within the block |

## Execution Pipeline

The core implements a classic 5-stage RISC pipeline with hardware forwarding and warp-level scheduling, allowing multiple instructions to be processed simultaneously across different stages.

<p align="center">
  <img src="/docs/PNG/core_blockvsdx.png" alt="Core" width="60%">
</p>

### Stages

1. **IF (Instruction Fetch)**: The Fetcher requests the instruction at the current PC from program memory. The scheduler selects which warp and which threads issue the next instruction.
2. **ID (Instruction Decode)**: The Decoder translates the 16-bit instruction into control signals. The register file is read asynchronously, and forwarding paths are applied to resolve Read-After-Write hazards without stalling.
3. **EX (Execute)**: The ALU performs arithmetic or comparisons. Branch targets and conditions are evaluated here. The NZP condition codes are updated for compare instructions.
4. **MEM (Memory Access)**: The LSU performs asynchronous reads/writes to global or shared memory. The pipeline may stall if memory is not immediately ready, and the scheduler moves to another warp.
5. **WB (Write Back)**: The result from the ALU or LSU is written back synchronously to the register file.

### Hardware Data Forwarding

The pipeline includes forwarding logic that bypasses the register file when a later stage (MEM or WB) has a pending write to a register that is being read in the EX stage. This eliminates the need for compiler-inserted NOPs for most arithmetic dependencies, though memory loads still require careful scheduling due to the asynchronous memory interface.

### Branch Divergence Handling

The scheduler maintains per-thread architectural and speculative program counters along with an active mask. When a branch occurs, threads that take the branch continue along the new path while others are masked out. Divergent control flow is serialized by the scheduler, which resynchronizes threads when they reconverge. The `SYNC` instruction provides an explicit barrier across all threads in a block.

### Warp Scheduling and Barriers

Warps (groups of threads) are scheduled round-robin by the scheduler. Warps can be in one of several states: `IDLE`, `READY`, `WAITING_MEM`, `WAITING_BARRIER`, or `DONE_STATE`. The barrier mechanism uses a counter to track how many warps have reached a `SYNC` instruction; when the counter equals the number of active warps, all waiting warps are released.

## Kernels

### Matrix Multiplication

The following kernel performs a 5x5 matrix multiplication \( C = A \times B \), where \( A \) is the identity matrix and \( B \) contains values 0 through 24 laid out sequentially. The output matrix \( C \) should therefore equal \( B \) exactly.

This example demonstrates several advanced features:
- Thread indexing using `%blockDim` (R14) and `%threadIdx` (R15) to compute a global thread ID.
- Bounds checking with conditional branches, causing 7 threads (IDs 25‑31) to diverge and exit immediately.
- A subroutine (`DOT_PROD`) called via `CALL` and returned from via `RET_FN`, exercising the per‑warp hardware return stack.
- Loop constructs with iteration over the inner dimension (`k` from 0 to 4).
- Global memory loads/stores with offset addressing.

**Memory layout**:
- Matrix A: addresses 0‑24 (identity matrix: 1 on diagonal, 0 elsewhere)
- Matrix B: addresses 25‑49 (values 0 to 24 in row‑major order)
- Matrix C: addresses 50‑74 (output)

**Assembly program** (addresses shown as PC):

```asm
// --- MAIN KERNEL ---
// R13 = %blockIdx, R15 = %threadIdx, R14 = %blockDim (16)
0:  CONST R7, 16                // R7 = 16
1:  MUL   R0, R13, R7           // R0 = blockIdx * 16
2:  ADD   R0, R0, R15           // R0 = global thread ID

// Bounds check: if (R0 < 25) goto MAIN_BODY, else EXIT
3:  CONST R1, 25
4:  CMP   R0, R1
5:  BRn   7                     // branch to MAIN_BODY if R0 < 25
6:  EXIT                        // threads 25-31 diverge and terminate
                                // (these are the extra threads beyond the 5x5 matrix)

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

**Execution notes**:
- The first 25 threads (global IDs 0‑24) compute one element of the 5x5 output matrix.
- Threads 25‑31 immediately diverge and exit – they do not write to memory.
- The `CALL`/`RET_FN` pair uses the per‑warp hardware stack, allowing nested function calls (up to a depth of 8).
- The scheduler handles the divergent exit automatically: threads that exit are marked inactive and do not issue further instructions.
- Memory loads have single‑cycle latency in the simulation, but the general pattern works with any memory latency because the LSU buffers requests per warp.

## Simulation

The GPU is set up to simulate the execution of the above kernel. You can run the kernel simulations within tools like Xilinx Vivado or Altera Quartus.

Executing the simulations will output a text console trace consisting of scheduler events, pipeline stage progress, memory controller handshakes, and register writes.

## Advanced Functionality

For the sake of simplicity, there are additional features implemented in modern GPUs that heavily improve performance and functionality which this design currently omits or simplifies:

### Memory Coalescing
Multiple threads running in parallel often need to access sequential addresses in memory (e.g., neighboring elements in a matrix). Memory coalescing analyzes queued memory requests and combines neighboring requests into a single wide transaction, minimizing time spent on addressing.

### Cache Hierarchy
Many GPUs include L1 and L2 caches for data and instructions to reduce average memory latency. This design currently has no caches beyond the shared memory.

### Dynamic Warp Scheduling
While the scheduler implements round-robin selection, more sophisticated scheduling policies (e.g., priority-based, age-based) can further improve throughput.

## Next Steps

Potential improvements and additions for the future:

- Add a simple instruction cache
- Implement basic memory coalescing in the memory controller
- Write a simple graphics kernel or add basic graphics hardware
- Add support for multiple kernel launches without reset
- Extend the ISA with floating-point operations
