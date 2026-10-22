`default_nettype none
`timescale 1ns/1ns

// =============================================================================
// gpu_pkg.sv — Centralized Target Configuration Package (ASIC dir only)
// -----------------------------------------------------------------------------
// BUG 2 — COMPILE ORDER IS MANDATORY:
//   Leaf defaults reference gpu_pkg::... so this file MUST be parsed first
//   in every compilation unit. Always list it FIRST:
//     iverilog -g2012 ASIC/src/rtl/include/gpu_pkg.sv ASIC/src/rtl/*.sv ...
//   Use ASIC/rtl.f for canonical order, or ASIC/Makefile targets.
//   Standalone `iverilog .../alu.sv` WITHOUT this file WILL fail with
//   "'gpu_pkg' has not been declared" — expected, not a bug.
// -----------------------------------------------------------------------------
// TRAP 5 — OVERRIDE POLICY:
//   Hierarchy (gpu -> core -> leaf) explicitly forwards parameters, so a TB
//   override like `gpu #(.NUM_WARPS(2))` DOES propagate all the way down.
//   Preferred flow is still: switch PROFILE, don't hand-override widths.
// NOTE: no CFG_L2_NUM_PORTS — L2 ports always equal CFG_NUM_CORES
// (1 dcache per core). gpu.sv forwards .NUM_PORTS(NUM_CORES); never add it.
// =============================================================================
package gpu_pkg;

    // =========================================================================
    // 1. Target Hardware Profiles
    // =========================================================================
    `ifdef TARGET_ASIC
        // --- ASIC Silicon Profile (Sky130 SRAM-Constrained) ---
        localparam int CFG_NUM_CORES                 = 1;
        localparam int CFG_NUM_WARPS                 = 2;
        // TARGET_ASIC_MINI (with TARGET_ASIC): "physical bring-up" overlay -- half the lanes and
        // smaller caches/buffers so place-and-route fits a 16 GB machine. Same ISA and microarchitecture.
`ifdef TARGET_ASIC_MINI
        localparam int CFG_THREADS_PER_BLOCK         = 2;  // 2 lanes x 2 warps = 4 threads
`else
        localparam int CFG_THREADS_PER_BLOCK         = 4;
`endif
        localparam int CFG_PMEM_ADDR_BITS            = 12; // 4K words (16KB)
        localparam int CFG_PMEM_DATA_BITS            = 32;
        localparam int CFG_DMEM_ADDR_BITS            = 14; // 16K words (64KB)
        localparam int CFG_DMEM_DATA_BITS            = 32;
        localparam int CFG_SHARED_MEM_ADDR_BITS      = 8;
`ifdef TARGET_ASIC_MINI
        localparam int CFG_SHARED_MEM_SIZE           = 32; // 32 words (128B)
`else
        localparam int CFG_SHARED_MEM_SIZE           = 64; // 64 words (256B)
`endif
        localparam int CFG_DEBUG                     = 0;
`ifdef TARGET_ASIC_MINI
        localparam int CFG_L1_CACHE_LINES            = 8;
`else
        localparam int CFG_L1_CACHE_LINES            = 16;
`endif
        localparam int CFG_L2_CACHE_LINES            = 64;
        localparam int CFG_L2_WAYS                   = 4;
        localparam int CFG_L2_SECTORS                = 4;
`ifdef TARGET_ASIC_MINI
        localparam int CFG_VWB_DEPTH                 = 2;
`else
        localparam int CFG_VWB_DEPTH                 = 4;
`endif
        localparam int CFG_DATA_MEM_NUM_CHANNELS     = 1;
        localparam int CFG_PROGRAM_MEM_NUM_CHANNELS  = 1;

    `elsif TARGET_FPGA
        // --- FPGA Profile (BRAM Target) ---
        localparam int CFG_NUM_CORES                 = 2;
        localparam int CFG_NUM_WARPS                 = 4;
        localparam int CFG_THREADS_PER_BLOCK         = 4;
        localparam int CFG_PMEM_ADDR_BITS            = 16;
        localparam int CFG_PMEM_DATA_BITS            = 32;
        localparam int CFG_DMEM_ADDR_BITS            = 16;
        localparam int CFG_DMEM_DATA_BITS            = 32;
        localparam int CFG_SHARED_MEM_ADDR_BITS      = 8;
        localparam int CFG_SHARED_MEM_SIZE           = 256;
        localparam int CFG_DEBUG                     = 1;
        localparam int CFG_L1_CACHE_LINES            = 16;
        localparam int CFG_L2_CACHE_LINES            = 256;
        localparam int CFG_L2_WAYS                   = 4;
        localparam int CFG_L2_SECTORS                = 4;
        localparam int CFG_VWB_DEPTH                 = 8;
        localparam int CFG_DATA_MEM_NUM_CHANNELS     = 4;
        localparam int CFG_PROGRAM_MEM_NUM_CHANNELS  = 1;

    `else
        // --- Default / Simulation Architecture Profile ---
        localparam int CFG_NUM_CORES                 = 2;
        localparam int CFG_NUM_WARPS                 = 4;
        localparam int CFG_THREADS_PER_BLOCK         = 4;
        localparam int CFG_PMEM_ADDR_BITS            = 32;
        localparam int CFG_PMEM_DATA_BITS            = 32;
        localparam int CFG_DMEM_ADDR_BITS            = 32;
        localparam int CFG_DMEM_DATA_BITS            = 32;
        localparam int CFG_SHARED_MEM_ADDR_BITS      = 8;
        localparam int CFG_SHARED_MEM_SIZE           = 256;
        localparam int CFG_DEBUG                     = 1;
        localparam int CFG_L1_CACHE_LINES            = 16;
        localparam int CFG_L2_CACHE_LINES            = 256;
        localparam int CFG_L2_WAYS                   = 4;
        localparam int CFG_L2_SECTORS                = 4;
        localparam int CFG_VWB_DEPTH                 = 8;
        localparam int CFG_DATA_MEM_NUM_CHANNELS     = 4;
        localparam int CFG_PROGRAM_MEM_NUM_CHANNELS  = 1;
    `endif

    // Fixed Constants and Calculations
    localparam int DATA_BITS         = 32;
    localparam int WORDS_PER_BLOCK   = 4;
    localparam int AXI_DATA_WIDTH    = DATA_BITS * WORDS_PER_BLOCK; // 128 bits
    localparam int THREADS_PER_CORE  = CFG_THREADS_PER_BLOCK * CFG_NUM_WARPS;
    localparam int WARP_ID_BITS      = (CFG_NUM_WARPS > 1) ? $clog2(CFG_NUM_WARPS) : 1;
    localparam int CORE_ID_BITS      = (CFG_NUM_CORES > 1) ? $clog2(CFG_NUM_CORES) : 1;

endpackage : gpu_pkg