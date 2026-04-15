# mahi-gpu

A minimal GPU implementation in Verilog optimized for learning about how GPUs work from the ground up.



### Table of Contents

- [Overview](#overview)
- [Architecture](#architecture)
  - [GPU](#gpu)
  - [Memory](#memory)
  - [Core](#core)
- [ISA](#isa)
- [Execution](#execution)
  - [Core](#core-1)
  - [Thread](#thread)
- [Kernels](#kernels)
  - [Matrix Addition](#matrix-addition)
  - [Matrix Multiplication](/tree/master?tab=readme-ov-file#matrix-multiplication)
- [Simulation](#simulation)
- [Advanced Functionality](#advanced-functionality)
- [Next Steps](#next-steps)

# Overview

If you want to learn how a CPU works all the way from architecture to control signals, there are many resources online to help you.

GPUs are not the same.

Because the GPU market is so competitive, low-level technical details for all modern architectures remain proprietary.

While there are lots of resources to learn about GPU programming, there's almost nothing available to learn about how GPU's work at a hardware level.


This is why I built `mahi-gpu`!

# T
special Thanks to [tiny-gpu](https://github.com/adam-maj/tiny-gpu) for letting me learn more about the GPU and giving me many ideas to learn how simple GPUs work!

## What is mahi-gpu?

> [!IMPORTANT]
>
> **mahi-gpu** is a minimal GPU implementation optimized for learning about how GPUs work from the ground up.
>
> Specifically, with the trend toward general-purpose GPUs (GPGPUs) and ML-accelerators like Google's TPU, mahi-gpu focuses on highlighting the general principles of all of these architectures, rather than on the details of graphics-specific hardware.

With this motivation in mind, we can simplify GPUs by cutting out the majority of complexity involved with building a production-grade graphics card, and focus on the core elements that are critical to all of these modern hardware accelerators.

This project is primarily focused on exploring:

1. **Architecture** - What does the architecture of a GPU look like? What are the most important elements?
2. **Parallelization** - How is the SIMD progamming model implemented in hardware?
3. **Memory** - How does a GPU work around the constraints of limited memory bandwidth?

After understanding the fundamentals laid out in this project, you can checkout the [advanced functionality section](#advanced-functionality) to understand some of the most important optimizations made in production grade GPUs (that are more challenging to implement) which improve performance.

# Architecture

<p float="left">
  <img src="/docs/images/gpu.png" alt="GPU" width="48%">
  <img src="/docs/images/core.png" alt="Core" width="48%">
</p>

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
5. Cache

### Device Control Register

The device control register usually stores metadata specifying how kernels should be executed on the GPU.

In this case, the device control register just stores the `thread_count` - the total number of threads to launch for the active kernel.

### Dispatcher

Once a kernel is launched, the dispatcher is the unit that actually manages the distribution of threads to different compute cores.

The dispatcher organizes threads into groups that can be executed in parallel on a single core called **blocks** and sends these blocks off to be processed by available cores.

Once all blocks have been processed, the dispatcher reports back that the kernel execution is done.

## Memory

The GPU is built to interface with an external global memory. Here, data memory and program memory are separated out for simplicity.

### Global Memory

mahi-gpu data memory has the following specifications:

- 8 bit addressability (256 total rows of data memory)
- 8 bit data (stores values of <256 for each row)

mahi-gpu program memory has the following specifications:

- 8 bit addressability (256 rows of program memory)
- 16 bit data (each instruction is 16 bits as specified by the ISA)

### Shared Memory 

mahi-gpu has a shared memory for each Block (core in this project) for faster execution and better caching just like in NVIDIA GPU architectures.

### Memory Controllers

Global memory has fixed read/write bandwidth, but there may be far more incoming requests across all cores to access data from memory than the external memory is actually able to handle.

The memory controllers keep track of all the outgoing requests to memory from the compute cores, throttle requests based on actual external memory bandwidth, and relay responses from external memory back to the proper resources.

Each memory controller has a fixed number of channels based on the bandwidth of global memory.

<!-- ### Cache (WIP)

The same data is often requested from global memory by multiple cores. Constantly access global memory repeatedly is expensive, and since the data has already been fetched once, it would be more efficient to store it on device in SRAM to be retrieved much quicker on later requests.

This is exactly what the cache is used for. Data retrieved from external memory is stored in cache and can be retrieved from there on later requests, freeing up memory bandwidth to be used for new data. -->

## Core

Each core has a number of compute resources, often built around a certain number of threads it can support. In order to maximize parallelization, these resources need to be managed optimally to maximize resource utilization.

In this simplified GPU, each core processed one **block** at a time, and for each thread in a block, the core has a dedicated ALU, LSU, PC, and register file. Managing the execution of thread instructions on these resources is one of the most challening problems in GPUs.

### Scheduler

Each core has a single scheduler that manages the execution of threads.

The mahi-gpu scheduler executes instructions for a single block to completion before picking up a new block, and it executes instructions for all threads in-sync and sequentially.

In more advanced schedulers, techniques like **pipelining** are used to stream the execution of multiple instructions subsequent instructions to maximize resource utilization before previous instructions are fully complete. Additionally, **warp scheduling** can be use to execute multiple batches of threads within a block in parallel.

The main constraint the scheduler has to work around is the latency associated with loading & storing data from global memory. While most instructions can be executed synchronously, these load-store operations are asynchronous, meaning the rest of the instruction execution has to be built around these long wait times.

### Fetcher

Asynchronously fetches the instruction at the current program counter from program memory (most should actually be fetching from cache after a single block is executed).

### Decoder

Decodes the fetched instruction into control signals for thread execution.

### Register Files

Each thread has it's own dedicated set of register files. The register files hold the data that each thread is performing computations on, which enables the same-instruction multiple-data (SIMD) pattern.

Importantly, each register file contains a few read-only registers holding data about the current block & thread being executed locally, enabling kernels to be executed with different data based on the local thread id.

### ALUs

Dedicated arithmetic-logic unit for each thread to perform computations. Handles the `ADD`, `SUB`, `MUL`, `DIV` arithmetic instructions.

Also handles the `CMP` comparison instruction which actually outputs whether the result of the difference between two registers is negative, zero or positive - and stores the result in the `NZP` register in the PC unit.

### LSUs

Dedicated load-store unit for each thread to access global data memory.

Handles the `LDR` & `STR` instructions - and handles async wait times for memory requests to be processed and relayed by the memory controller.

### PCs

Dedicated program-counter for each unit to determine the next instructions to execute on each thread.

By default, the PC increments by 1 after every instruction.

With the `BRnzp` instruction, the NZP register checks to see if the NZP register (set by a previous `CMP` instruction) matches some case - and if it does, it will branch to a specific line of program memory. _This is how loops and conditionals are implemented._

Since threads are processed in parallel, mahi-gpu assumes that all threads "converge" to the same program counter after each instruction - which is a naive assumption for the sake of simplicity.

In real GPUs, individual threads can branch to different PCs, causing **branch divergence** where a group of threads threads initially being processed together has to split out into separate execution.

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
| `CONST` | 1001 | I | rd = sign/zero‑extended imm (implementation‑defined) |
| `SYNC`  | 1010 | — | Synchronization primitive |
| `LDSH`  | 1011 | R | Load from shared memory |
| `STSH`  | 1100 | R | Store to shared memory |
| `RET`   | 1111 | — | Thread return |


# Instruction Format

All instructions are 16 bits.

```
15        12 11        8 7        4 3         0
+------------+-----------+-----------+-----------+
|  OPCODE    |    RD     |    RS     |    RT     |  (R-type)
+------------+-----------+-----------+-----------+

15        12 11        8 7                                0
+------------+-----------+-----------------------+
|  OPCODE    |    NZP    |    IMMEDIATE[7:0]     |  (I-type: BR, CONST, some others)
+------------+-----------+-----------------------+
```

## Registers

per‑thread register file for a small GPU‑like SIMD core, Each thread gets 16 registers.

- 13 general‑purpose registers (R0–R12) — read/write
- 3 read‑only special registers (R13–R15) — automatically set, not writable by the program
  - `%blockIdx`
  - `%blockDim`
  - `%threadIdx`

mahi-gpu implements a simple 11 instruction ISA built to enable simple kernels for proof-of-concept like matrix addition & matrix multiplication These mirror CUDA‑style registers that allow each thread to know:
1. Which block it belongs to,
2. How many threads exist in the block,
3. Which thread index it is.

| Register Index | Name (Conceptual) |  Width   | Read/Write | Initialization | Purpose |
|:--------------:|:-----------------:|:--------:|:-----------:|:--------------:|---------|
| **0–12**       | General Purpose Registers (GPRs) | DATA_BITS | R/W | Zero | Used for arithmetic, memory ops, constants, etc. |
| **13**         | `%blockIdx`       | DATA_BITS | Read‑only to thread | Set to block_id on reset and every cycle | Identifies which block this thread belongs to |
| **14**         | `%blockDim`       | DATA_BITS | Read‑only | Constant = THREADS_PER_BLOCK | Number of threads per block |
| **15**         | `%threadIdx`      | DATA_BITS | Read‑only | Constant = THREAD_ID | Thread index within the block |


# Execution

### Core

Each core follows the following control flow going through different stages to execute each instruction:

1. `FETCH` - Fetch the next instruction at current program counter from program memory.
2. `DECODE` - Decode the instruction into control signals.
3. `REQUEST` - Request data from global memory if necessary (if `LDR` or `STR` instruction).
4. `WAIT` - Wait for data from global memory if applicable.
5. `EXECUTE` - Execute any computations on data.
6. `UPDATE` - Update register files and NZP register.


### Thread

![Thread](/docs/images/thread.png)

Each thread within each core follows the above execution path to perform computations on the data in it's dedicated register file.

This resembles a standard CPU diagram, and is quite similar in functionality as well. The main difference is that the `%blockIdx`, `%blockDim`, and `%threadIdx` values lie in the read-only registers for each thread, enabling SIMD functionality.

# Kernels

I wrote a matrix addition and matrix multiplication kernel using my ISA as a proof of concept to demonstrate SIMD programming and execution with my GPU. The test files in this repository are capable of fully simulating the execution of these kernels on the GPU, producing data memory states and a complete execution trace.

### Matrix Addition

This matrix addition kernel adds two 1 x 8 matrices by performing 8 element wise additions in separate threads.

This demonstration makes use of the `%blockIdx`, `%blockDim`, and `%threadIdx` registers to show SIMD programming on this GPU. It also uses the `LDR` and `STR` instructions which require async memory management.

`gpu_tb.sv`

```asm
// threads 8
// data 1 2 3 4 5 6 7  8            ; matrix A (1 x 8)
// data 1 2 4 6 8 10 12 14          ; matrix B (1 x 8)

MUL R1, BID, TPB        
ADD R2, R1, TID    // r2 = r1 + thread_id      
// r3 = r2 + 0  (A base)
CONST R0, 8'd0       
ADD R3, R2, R0         
LDR R4, R3        // r4 = mem[r3]  (load A[i]) 

// r5 = r2 + 8  (B base)
CONST R0, 8'd8         
ADD R5, R2, R0         

LDR R6, R5       // r6 = mem[r5]  (load B[i])       

ADD R7, R4, R6
// r3 = r2 + 16  (C base)
CONST R0, 8'd16
ADD R3, R2, R0         

STR R3, R7
// RETURN
RET             // kernel's end 
```


# Simulation

mahi-gpu is setup to simulate the execution of the above kernel. Before simulating, Xilinx Vivado or Other Synthesis tools like ALtera Quartus and etc.

Once you've installed the tools, you can run the kernel simulations within the tools.

Executing the simulations will output a text in console consisting of scheduler, controller, LDR and registers writes and the results.. 

Below is a sample of the execution traces, showing on each cycle the execution of every thread within every core, including the current instruction, PC, register values, states, etc.

<!-- ![execution trace]() -->


# Advanced Functionality

For the sake of simplicity, there were many additional features implemented in modern GPUs that heavily improve performance & functionality that mahi-gpu omits. We'll discuss some of those most critical features in this section.

<!-- ### Multi-layered Cache & Shared Memory

In modern GPUs, multiple different levels of caches are used to minimize the amount of data that needs to get accessed from global memory. mahi-gpu implements only one cache layer between individual compute units requesting memory and the memory controllers which stores recent cached data.

Implementing multi-layered caches allows frequently accessed data to be cached more locally to where it's being used (with some caches within individual compute cores), minimizing load times for this data.

Different caching algorithms are used to maximize cache-hits - this is a critical dimension that can be improved on to optimize memory access.

Additionally, GPUs often use **shared memory** for threads within the same block to access a single memory space that can be used to share results with other threads. -->

<!-- ### Memory Coalescing

Another critical memory optimization used by GPUs is **memory coalescing.** Multiple threads running in parallel often need to access sequential addresses in memory (for example, a group of threads accessing neighboring elements in a matrix) - but each of these memory requests is put in separately.

Memory coalescing is used to analyzing queued memory requests and combine neighboring requests into a single transaction, minimizing time spent on addressing, and making all the requests together.

### Pipelining

In the control flow for mahi-gpu, cores wait for one instruction to be executed on a group of threads before starting execution of the next instruction.

Modern GPUs use **pipelining** to stream execution of multiple sequential instructions at once while ensuring that instructions with dependencies on each other still get executed sequentially.

This helps to maximize resource utilization within cores as resources are not sitting idle while waiting (ex: during async memory requests).

### Warp Scheduling

Another strategy used to maximize resource utilization on course is **warp scheduling.** This approach involves breaking up blocks into individual batches of theads that can be executed together.

Multiple warps can be executed on a single core simultaneously by executing instructions from one warp while another warp is waiting. This is similar to pipelining, but dealing with instructions from different threads.

### Branch Divergence

mahi-gpu assumes that all threads in a single batch end up on the same PC after each instruction, meaning that threads can be executed in parallel for their entire lifetime.

In reality, individual threads could diverge from each other and branch to different lines based on their data. With different PCs, these threads would need to split into separate lines of execution, which requires managing diverging threads & paying attention to when threads converge again.

### Synchronization & Barriers

Another core functionality of modern GPUs is the ability to set **barriers** so that groups of threads in a block can synchronize and wait until all other threads in the same block have gotten to a certain point before continuing execution.

This is useful for cases where threads need to exchange shared data with each other so they can ensure that the data has been fully processed. -->

# Next Steps

Updates I want to make in the future to improve the design, anyone else is welcome to contribute as well:

- [ ] Add a simple cache for instructions
- [ ] Build an adapter to use GPU with Tiny Tapeout 7
- [ ] Add basic memory coalescing
- [ ] Add basic pipelining
- [ ] Optimize control flow and use of registers to improve cycle time
- [ ] Write a basic graphics kernel or add simple graphics hardware to demonstrate graphics functionality

