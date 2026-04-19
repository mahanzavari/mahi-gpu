# mahi-gpu

A minimal GPU implementation in Verilog optimized for learning about how GPUs work from the ground up.

### Table of Contents

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
  - [Matrix Addition](#matrix-addition)
- [Simulation](#simulation)
- [Advanced Functionality](#advanced-functionality)
- [Next Steps](#next-steps)

# Overview

If you want to learn how a CPU works all the way from architecture to control signals, there are many resources online to help you.

GPUs are not the same.

Because the GPU market is so competitive, low-level technical details for all modern architectures remain proprietary.

While there are lots of resources to learn about GPU programming, there's almost nothing available to learn about how GPU's work at a hardware level.

This is why I built `mahi-gpu`!

Special thanks to [tiny-gpu](https://github.com/adam-maj/tiny-gpu) for letting me learn more about the GPU and giving me many ideas to learn how simple GPUs work!

## What is mahi-gpu?


**mahi-gpu** is a minimal GPU implementation optimized for learning about how GPUs work from the ground up.
Specifically, with the trend toward general-purpose GPUs (GPGPUs) and ML-accelerators like Google's TPU, mahi-gpu focuses on highlighting the general principles of all of these architectures, rather than on the details of graphics-specific hardware.

With this motivation in mind, we can simplify GPUs by cutting out the majority of complexity involved with building a production-grade graphics card, and focus on the core elements that are critical to all of these modern hardware accelerators.

This project is primarily focused on exploring:

1. **Architecture** - What does the architecture of a GPU look like? What are the most important elements?
2. **Parallelization** - How is the SIMD programming model implemented in hardware?
3. **Memory** - How does a GPU work around the constraints of limited memory bandwidth?
4. **Pipelining** - How are instructions streamed continuously to maximize hardware utilization?

After understanding the fundamentals laid out in this project, you can check out the [advanced functionality section](#advanced-functionality) to understand some of the most important optimizations made in production-grade GPUs.

# Architecture

<!-- <p float="left">
  <img src="/docs/images/gpu.png" alt="GPU" width="48%">
  <img src="/docs/images/core.png" alt="Core" width="48%">
</p> -->

## GPU

mahi-gpu is built to execute a single kernel at a time.

In order to launch a kernel, we need to do the following:

1. Load global program memory with the kernel code
2. Load data memory with the necessary data
3. Specify the number of threads to launch in the device control register
4. Launch the kernel by setting the start signal to high.

The GPU itself consists of the following units:

1. Device control register
2. Dispatcher
3. Variable number of compute cores
4. Memory controllers for data memory & program memory
5. Shared Memory for threads within a block

### Device Control Register

The device control register usually stores metadata specifying how kernels should be executed on the GPU. In this case, it stores the `thread_count` - the total number of threads to launch for the active kernel.

### Dispatcher

Once a kernel is launched, the dispatcher manages the distribution of threads to different compute cores. It organizes threads into groups that can be executed in parallel on a single core called **blocks** and sends these blocks off to be processed by available cores.

## Memory

The GPU is built to interface with an external global memory. Here, data memory and program memory are separated out for simplicity.

### Global Memory

mahi-gpu data memory has the following specifications:
- 8-bit addressability (256 total rows of data memory)
- 16-bit data 

mahi-gpu program memory has the following specifications:
- 8-bit addressability (256 rows of program memory)
- 16-bit data (each instruction is 16 bits as specified by the ISA)

### Shared Memory 

mahi-gpu has a shared memory for each Block (core in this project) for faster execution and better caching just like in NVIDIA GPU architectures.

### Memory Controllers

Global memory has fixed read/write bandwidth, but there may be far more incoming requests across all cores. The memory controllers keep track of all the outgoing requests, throttle them based on actual external memory bandwidth, and relay responses back to the proper resources.

## Core

Each core has a number of compute resources built around a certain number of threads it can support. In this simplified GPU, each core processes one **block** at a time. For each thread in a block, the core has a dedicated ALU, LSU, PC, and register file.

### Scheduler (Hazard & Branch Control)

The scheduler manages the continuous flow of instructions into the pipeline. Because mahi-gpu is pipelined, the scheduler dynamically monitors execution to handle:
- **Data & Structural Hazards:** Freezing the frontend (PC) when asynchronous global memory accesses stall the backend.
- **Branching:** Monitoring the Execute (EX) stage for branch instructions and dynamically flushing the pipeline if a jump is taken.

### Thread Units
- **Fetcher**: Asynchronously fetches the instruction at the current program counter from program memory.
- **Decoder**: Purely combinational unit that translates instructions into pipeline control signals.
- **Register Files**: Each thread has its own dedicated set of register files, holding data and read-only thread context (`%blockIdx`, `%blockDim`, `%threadIdx`), enabling the SIMD pattern.
- **ALUs**: Dedicated arithmetic-logic unit for each thread (`ADD`, `SUB`, `MUL`, `DIV`, `CMP`).
- **LSUs**: Dedicated load-store unit for each thread to access global data memory asynchronously.

# ISA

| Mnemonic | Opcode | Type | Notes |
|:--------:|:------:|:----:|:-----:|
| `NOP`   | 0000 | — | No operation |
| `BRnzp` | 0001 | I | Conditional branch on NZP flags |
| `CMP`   | 0010 | R | Compare rs, rt → update NZP |
| `ADD`   | 0011 | R | rd = rs + rt |
| `SUB`   | 0100 | R | rd = rs - rt |
| `MUL`   | 0101 | R | rd = rs * rt |
| `DIV`   | 0110 | R | rd = rs / rt |
| `LDR`   | 0111 | R | rd = MEM[rs + rt] |
| `STR`   | 1000 | R | MEM[rs + rt] = rt |
| `CONST` | 1001 | I | rd = sign/zero‑extended imm |
| `SYNC`  | 1010 | — | Synchronization primitive |
| `LDSH`  | 1011 | R | Load from shared memory |
| `STSH`  | 1100 | R | Store to shared memory |
| `RET`   | 1111 | — | Thread return |

# Execution Pipeline

mahi-gpu implements a **classic 5-stage RISC pipeline**, allowing multiple instructions to be processed simultaneously across different stages of execution. This drastically improves hardware utilization compared to a multi-cycle state machine.

```mermaid
graph LR
    IF[Instruction Fetch] -->|IF/ID Reg| ID[Instruction Decode]
    ID -->|ID/EX Reg| EX[Execute]
    EX -->|EX/MEM Reg| MEM[Memory Access]
    MEM -->|MEM/WB Reg| WB[Write Back]
    
    style IF fill:#e1f5fe,stroke:#311b92
    style ID fill:#fff3e0,stroke:#e65100
    style EX fill:#e8f5e9,stroke:#1b5e20
    style MEM fill:#fce4ec,stroke:#b71c1c
    style WB fill:#f3e5f5,stroke:#4a148c
```

### Stages

1. **IF (Instruction Fetch)**: The Fetcher requests the instruction at the current PC from Program Memory.
2. **ID (Instruction Decode)**: The Decoder translates the 16-bit instruction into control signals. The Register File is read asynchronously.
3. **EX (Execute)**: The ALU performs arithmetic or comparisons. Branch targets and conditions are evaluated here.
4. **MEM (Memory Access)**: The LSU performs asynchronous reads/writes to Global or Shared Memory. The pipeline will stall here if memory is not immediately ready.
5. **WB (Write Back)**: The result from the ALU or LSU is written back synchronously to the Register File.

### Thread Data Path

This resembles a standard CPU data path, but multiplied across the core. The main difference is that the `%blockIdx`, `%blockDim`, and `%threadIdx` values lie in the read-only registers for each thread, enabling SIMD functionality where threads execute the exact same instruction but on their own private data.

# Kernels

### Matrix Addition

This matrix addition kernel adds two matrices by performing element-wise additions in separate parallel threads. It demonstrates SIMD programming utilizing `%blockIdx` and `%threadIdx` (represented here as `BID` and `TID`) to dynamically calculate memory offsets.

```asm
// threads 8
// data 1 2 3 4 5 6 7 8             ; matrix A
// data 1 2 4 6 8 10 12 14          ; matrix B

MUL R1, BID, TPB        
ADD R2, R1, TID        // r2 = (blockIdx * blockDim) + threadIdx
CONST R0, 8'd0       
ADD R3, R2, R0         // A base address
LDR R4, R3             // Load A[i]

CONST R0, 8'd8         
ADD R5, R2, R0         // B base address
LDR R6, R5             // Load B[i]       

NOP                    // Pipeline bubble to prevent Data Hazard
NOP 
NOP

ADD R7, R4, R6         // Add A[i] + B[i]
CONST R0, 8'd16
ADD R3, R2, R0         // C base address

STR R3, R7             // Store result to C[i]
RET                    // End Thread
```
*(Note: Because mahi-gpu currently lacks hardware data-forwarding, `NOP` instructions are inserted manually by the compiler to prevent Read-After-Write hazards during memory loads).*

# Simulation

mahi-gpu is setup to simulate the execution of the above kernel. You can run the kernel simulations within tools like Xilinx Vivado or Altera Quartus.

Executing the simulations will output a text console trace consisting of scheduler events, pipeline stage progress, memory controller handshakes, and register writes.

# Advanced Functionality

For the sake of simplicity, there are additional features implemented in modern GPUs that heavily improve performance & functionality that mahi-gpu currently omits:

### Data Forwarding (Bypassing)
Currently, if an instruction depends on the result of an immediately preceding memory load, the compiler must insert `NOP` bubbles to wait for the data to reach the Write-Back stage. Modern pipelines use hardware forwarding logic to route data directly from the MEM stage back to the EX stage to avoid these stalls.

### Memory Coalescing
Multiple threads running in parallel often need to access sequential addresses in memory (e.g., neighboring elements in a matrix). Memory coalescing analyzes queued memory requests and combines neighboring requests into a single wide transaction, minimizing time spent on addressing.

### Warp Scheduling
This approach involves breaking up blocks into smaller batches of threads called **warps**. Multiple warps can be executed on a single core simultaneously by swapping execution out when one warp stalls on a memory access.

### Branch Divergence
mahi-gpu currently assumes that all threads in a single block follow the exact same control flow path. In reality, individual threads could evaluate conditionals differently and branch to different PCs. This requires a divergence stack to temporarily mask out inactive threads and serialize the execution of the diverging paths until they converge again.

# Next Steps

Updates I want to make in the future to improve the design:

- [x] Add basic pipelining
- [ ] Add hardware data forwarding / bypass paths
- [ ] Add a simple cache for instructions
- [ ] Add basic memory coalescing
- [ ] Implement SIMT Branch Divergence handling
- [ ] Write a basic graphics kernel or add simple graphics hardware
