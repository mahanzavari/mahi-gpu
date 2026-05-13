// --- Begin: C:\Users\ASUS\Desktop\tiny-gpu\src\gpu.sv ---
`default_nettype none
`timescale 1ns/1ns

module gpu #(
    parameter DATA_MEM_ADDR_BITS = 32,
    parameter DATA_MEM_DATA_BITS = 32,
    parameter DATA_MEM_NUM_CHANNELS = 4,
    parameter PROGRAM_MEM_ADDR_BITS = 32,
    parameter PROGRAM_MEM_DATA_BITS = 32,
    parameter PROGRAM_MEM_NUM_CHANNELS = 1,
    parameter NUM_CORES = 2,
    parameter THREADS_PER_BLOCK = 4,
    parameter NUM_WARPS = 4
) (
    input wire clk,
    input wire reset,

    input wire start,
    output wire done,

    input wire device_control_write_enable,
    input wire [7:0] device_control_data,

    // Program memory interface (128-bit blocks)
    output wire [PROGRAM_MEM_NUM_CHANNELS-1:0] program_mem_read_valid,
    output wire [PROGRAM_MEM_ADDR_BITS-1:0]    program_mem_read_address [PROGRAM_MEM_NUM_CHANNELS],
    input  wire [PROGRAM_MEM_NUM_CHANNELS-1:0] program_mem_read_ready,
    input  wire [(PROGRAM_MEM_DATA_BITS*4)-1:0] program_mem_read_data [PROGRAM_MEM_NUM_CHANNELS],

    // Data memory interface (128-bit blocks)
    output wire [DATA_MEM_NUM_CHANNELS-1:0] data_mem_read_valid,
    output wire [DATA_MEM_ADDR_BITS-1:0]    data_mem_read_address [DATA_MEM_NUM_CHANNELS],
    input  wire [DATA_MEM_NUM_CHANNELS-1:0] data_mem_read_ready,
    input  wire [(DATA_MEM_DATA_BITS*4)-1:0] data_mem_read_data [DATA_MEM_NUM_CHANNELS],
    output wire [DATA_MEM_NUM_CHANNELS-1:0] data_mem_write_valid,
    output wire [DATA_MEM_ADDR_BITS-1:0]    data_mem_write_address [DATA_MEM_NUM_CHANNELS],
    output wire [(DATA_MEM_DATA_BITS*4)-1:0] data_mem_write_data [DATA_MEM_NUM_CHANNELS],
    output wire [3:0]                       data_mem_write_strobe [DATA_MEM_NUM_CHANNELS],
    input  wire [DATA_MEM_NUM_CHANNELS-1:0] data_mem_write_ready
);

    wire [7:0] thread_count;

    // Dispatch outputs
    wire [NUM_CORES-1:0] core_start, core_reset, core_done;
    wire [7:0] core_block_id [NUM_CORES];
    wire [$clog2(THREADS_PER_BLOCK * NUM_WARPS):0] core_thread_count [NUM_CORES];

    // ------------------------------------------------------------------------
    // Wires between cores and L1 caches (native widths)
    localparam NUM_FETCHERS = NUM_CORES;
    wire [NUM_FETCHERS-1:0]                 core_pmem_read_valid;
    wire [PROGRAM_MEM_ADDR_BITS-1:0]        core_pmem_read_addr [NUM_FETCHERS];
    wire [NUM_FETCHERS-1:0]                 core_pmem_read_ready;
    wire [PROGRAM_MEM_DATA_BITS-1:0]        core_pmem_read_data [NUM_FETCHERS];

    localparam NUM_LSUS = NUM_CORES;
    wire [NUM_LSUS-1:0]                 core_dmem_read_valid;
    wire [DATA_MEM_ADDR_BITS-1:0]       core_dmem_read_addr [NUM_LSUS];
    wire [NUM_LSUS-1:0]                 core_dmem_read_ready;
    wire [(DATA_MEM_DATA_BITS*4)-1:0]   core_dmem_read_data [NUM_LSUS];
    wire [NUM_LSUS-1:0]                 core_dmem_write_valid;
    wire [DATA_MEM_ADDR_BITS-1:0]       core_dmem_write_addr [NUM_LSUS];
    wire [(DATA_MEM_DATA_BITS*4)-1:0]   core_dmem_write_data [NUM_LSUS];
    wire [3:0]                          core_dmem_write_strobe [NUM_LSUS];
    wire [NUM_LSUS-1:0]                 core_dmem_write_ready;

    // ------------------------------------------------------------------------
    // Wires between Caches and downstream consumers
    wire [NUM_CORES-1:0]                 icache_mem_read_valid;
    wire [PROGRAM_MEM_ADDR_BITS-1:0]     icache_mem_read_addr [NUM_CORES];
    wire [NUM_CORES-1:0]                 icache_mem_read_ready;
    wire [(PROGRAM_MEM_DATA_BITS*4)-1:0] icache_mem_read_data [NUM_CORES]; 

    // Wires between L1 DCaches and Unified L2 Cache (Cache-line widths)
    wire [NUM_CORES-1:0]                 dcache_mem_read_valid;
    wire [DATA_MEM_ADDR_BITS-1:0]        dcache_mem_read_addr [NUM_CORES];
    wire [NUM_CORES-1:0]                 dcache_mem_read_ready;
    wire [(DATA_MEM_DATA_BITS*4)-1:0]    dcache_mem_read_data [NUM_CORES];
    wire [NUM_CORES-1:0]                 dcache_mem_write_valid;
    wire [DATA_MEM_ADDR_BITS-1:0]        dcache_mem_write_addr [NUM_CORES];
    wire [(DATA_MEM_DATA_BITS*4)-1:0]    dcache_mem_write_data [NUM_CORES];
    wire [3:0]                           dcache_mem_write_strobe [NUM_CORES];
    wire [NUM_CORES-1:0]                 dcache_mem_write_ready;

    // Wires between Unified L2 Cache and Memory Controller
    wire [0:0]                           l2_mem_read_valid;
    wire [DATA_MEM_ADDR_BITS-1:0]        l2_mem_read_addr [1];
    wire [0:0]                           l2_mem_read_ready;
    wire [(DATA_MEM_DATA_BITS*4)-1:0]    l2_mem_read_data [1];
    wire [0:0]                           l2_mem_write_valid;
    wire [DATA_MEM_ADDR_BITS-1:0]        l2_mem_write_addr [1];
    wire [(DATA_MEM_DATA_BITS*4)-1:0]    l2_mem_write_data [1];
    wire [3:0]                           l2_mem_write_strobe [1];
    wire [0:0]                           l2_mem_write_ready;
    
    // Flush Control
    wire flush_caches_global;
    wire l2_flush_done;
    wire [NUM_CORES-1:0] l1_dcache_flush_done;
    wire [NUM_CORES-1:0] core_cache_flush_done;

    // ------------------------------------------------------------------------
    // DCR instance
    dcr dcr_instance (
        .clk(clk), .reset(reset),
        .device_control_write_enable(device_control_write_enable),
        .device_control_data(device_control_data),
        .thread_count(thread_count)
    );

    // ------------------------------------------------------------------------
    // Unified L2 Cache (Sits between L1s and Data Memory Controller)
    l2_cache #(
        .ADDR_BITS(DATA_MEM_ADDR_BITS),
        .BLOCK_BITS(DATA_MEM_DATA_BITS * 4), // 128-bit lines
        .CACHE_LINES(256),    
        .WAYS(4),      
        .SECTORS(4),
        .NUM_PORTS(NUM_CORES),    
        .VWB_DEPTH(8)     
    ) unified_cache (
        .clk(clk),
        .reset(reset),

        // === Upstream: from L1 dcaches ===
        .up_read_valid(dcache_mem_read_valid),
        .up_read_addr(dcache_mem_read_addr),
        .up_read_ready(dcache_mem_read_ready),
        .up_read_data(dcache_mem_read_data),

        .up_write_valid(dcache_mem_write_valid),
        .up_write_addr(dcache_mem_write_addr),
        .up_write_data(dcache_mem_write_data),
        .up_write_strobe(dcache_mem_write_strobe),
        .up_write_ready(dcache_mem_write_ready),

        // === Downstream: to Data Memory Controller ===
        .mem_read_valid(l2_mem_read_valid[0]),
        .mem_read_addr(l2_mem_read_addr[0]),
        .mem_read_ready(l2_mem_read_ready[0]),
        .mem_read_data(l2_mem_read_data[0]),

        .mem_write_valid(l2_mem_write_valid[0]),
        .mem_write_addr(l2_mem_write_addr[0]),
        .mem_write_data(l2_mem_write_data[0]),
        .mem_write_strobe(l2_mem_write_strobe[0]),
        .mem_write_ready(l2_mem_write_ready[0]),

        // === Flush ===
        .flush_en(flush_caches_global),
        .flush_done(l2_flush_done)
    );    

    // ------------------------------------------------------------------------
    // Data memory controller (now only has 1 consumer: The L2 Cache)
    controller #(
        .ADDR_BITS(DATA_MEM_ADDR_BITS), .DATA_BITS(DATA_MEM_DATA_BITS),
        .BLOCK_DATA_BITS(DATA_MEM_DATA_BITS*4),
        .NUM_CONSUMERS(1), // Changed to 1 because L2 unifies the traffic
        .NUM_CHANNELS(DATA_MEM_NUM_CHANNELS)
    ) data_memory_controller (
        .clk(clk), .reset(reset),
        .consumer_read_valid(l2_mem_read_valid),
        .consumer_read_address(l2_mem_read_addr),
        .consumer_read_ready(l2_mem_read_ready),
        .consumer_read_data(l2_mem_read_data),
        .consumer_write_valid(l2_mem_write_valid),
        .consumer_write_address(l2_mem_write_addr),
        .consumer_write_data(l2_mem_write_data),
        .consumer_write_strobe(l2_mem_write_strobe),
        .consumer_write_ready(l2_mem_write_ready),
        
        .mem_read_valid(data_mem_read_valid),
        .mem_read_address(data_mem_read_address),
        .mem_read_ready(data_mem_read_ready),
        .mem_read_data(data_mem_read_data),
        .mem_write_valid(data_mem_write_valid),
        .mem_write_address(data_mem_write_address),
        .mem_write_data(data_mem_write_data),
        .mem_write_strobe(data_mem_write_strobe),
        .mem_write_ready(data_mem_write_ready)
    );

    // ------------------------------------------------------------------------
    // Program memory controller
    controller #(
        .ADDR_BITS(PROGRAM_MEM_ADDR_BITS),
        .DATA_BITS(PROGRAM_MEM_DATA_BITS),
        .BLOCK_DATA_BITS(PROGRAM_MEM_DATA_BITS * 4), 
        .NUM_CONSUMERS(NUM_FETCHERS),
        .NUM_CHANNELS(PROGRAM_MEM_NUM_CHANNELS),
        .WRITE_ENABLE(0)
    ) program_memory_controller (
        .clk(clk), .reset(reset),
        .consumer_read_valid(icache_mem_read_valid),
        .consumer_read_address(icache_mem_read_addr),
        .consumer_read_ready(icache_mem_read_ready),
        .consumer_read_data(icache_mem_read_data),
        // write ports are not connected (WRITE_ENABLE=0)
        .mem_read_valid(program_mem_read_valid),
        .mem_read_address(program_mem_read_address),
        .mem_read_ready(program_mem_read_ready),
        .mem_read_data(program_mem_read_data),
        
        .mem_write_valid(),
        .mem_write_address(),
        .mem_write_data(),
        .mem_write_strobe(),
        .mem_write_ready({PROGRAM_MEM_NUM_CHANNELS{1'b0}})
    );

    // ------------------------------------------------------------------------
    // Dispatch unit
    dispatch #(
        .NUM_CORES(NUM_CORES), .THREADS_PER_BLOCK(THREADS_PER_BLOCK), .NUM_WARPS(NUM_WARPS)
    ) dispatch_instance (
        .clk(clk), .reset(reset), .start(start), .thread_count(thread_count),
        .core_done(core_done), .core_start(core_start), .core_reset(core_reset),
        .core_block_id(core_block_id), .core_thread_count(core_thread_count), 
        .flush_caches(flush_caches_global),
        .cache_flush_done(core_cache_flush_done),
        .done(done)
    );

    // ------------------------------------------------------------------------
    // Per-core generation
    genvar i;
    generate
        for (i = 0; i < NUM_CORES; i = i + 1) begin : core_block
            wire ic_ev_acc, ic_ev_hit, ic_ev_stall;
            wire dc_ev_r_acc, dc_ev_r_hit, dc_ev_r_stall;
            wire dc_ev_w_acc, dc_ev_w_hit, dc_ev_w_stall;

            // Tie the dispatcher's flush requirement to BOTH L1 and L2 being finished
            assign core_cache_flush_done[i] = l1_dcache_flush_done[i] & l2_flush_done;

            // ----- Core itself ---
            core #(
                .DATA_MEM_ADDR_BITS(DATA_MEM_ADDR_BITS),
                .DATA_MEM_DATA_BITS(DATA_MEM_DATA_BITS),
                .PROGRAM_MEM_ADDR_BITS(PROGRAM_MEM_ADDR_BITS),
                .PROGRAM_MEM_DATA_BITS(PROGRAM_MEM_DATA_BITS),
                .THREADS_PER_BLOCK(THREADS_PER_BLOCK),
                .NUM_WARPS(NUM_WARPS)
            ) core_inst (
                .clk(clk), .reset(core_reset[i]), .start(core_start[i]), .done(core_done[i]),
                .block_id(core_block_id[i]), .thread_count(core_thread_count[i]),

                .program_mem_read_valid(core_pmem_read_valid[i]),
                .program_mem_read_address(core_pmem_read_addr[i]),
                .program_mem_read_ready(core_pmem_read_ready[i]),
                .program_mem_read_data(core_pmem_read_data[i]),

                .data_mem_read_valid(core_dmem_read_valid[i]),
                .data_mem_read_address(core_dmem_read_addr[i]),
                .data_mem_read_ready(core_dmem_read_ready[i]),
                .data_mem_read_data(core_dmem_read_data[i]),
                .data_mem_write_valid(core_dmem_write_valid[i]),
                .data_mem_write_address(core_dmem_write_addr[i]),
                .data_mem_write_data(core_dmem_write_data[i]),
                .data_mem_write_strobe(core_dmem_write_strobe[i]),
                .data_mem_write_ready(core_dmem_write_ready[i]),
                
                .ic_ev_access(ic_ev_acc), .ic_ev_hit(ic_ev_hit), .ic_ev_stall(ic_ev_stall),
                .dc_ev_read_acc(dc_ev_r_acc), .dc_ev_read_hit(dc_ev_r_hit), .dc_ev_read_stall(dc_ev_r_stall),
                .dc_ev_write_acc(dc_ev_w_acc), .dc_ev_write_hit(dc_ev_w_hit), .dc_ev_write_stall(dc_ev_w_stall)
            );

            // ----- Instruction Cache -----
            icache #(
                .ADDR_BITS(PROGRAM_MEM_ADDR_BITS),
                .DATA_BITS(PROGRAM_MEM_DATA_BITS),
                .BLOCK_BITS(PROGRAM_MEM_DATA_BITS * 4),
                .CACHE_LINES(16)
            ) icache_inst (
                .clk(clk), .reset(reset),
                .core_read_valid(core_pmem_read_valid[i]),
                .core_read_addr(core_pmem_read_addr[i]),
                .core_read_ready(core_pmem_read_ready[i]),
                .core_read_data(core_pmem_read_data[i]),
                
                .mem_read_valid(icache_mem_read_valid[i]),
                .mem_read_block_addr(icache_mem_read_addr[i]),
                .mem_read_ready(icache_mem_read_ready[i]),
                .mem_read_block_data(icache_mem_read_data[i]),
                
                .ev_access(ic_ev_acc), .ev_hit(ic_ev_hit), .ev_stall(ic_ev_stall)
            );

            // ----- Data Cache (Write-Through L1) -----
            dcache #(
                .ADDR_BITS(DATA_MEM_ADDR_BITS),
                .BLOCK_BITS(DATA_MEM_DATA_BITS * 4),
                .CACHE_LINES(16)
            ) dcache_inst (
                .clk(clk), .reset(reset),
                
                .core_read_valid(core_dmem_read_valid[i]),
                .core_read_block_addr(core_dmem_read_addr[i]),
                .core_read_ready(core_dmem_read_ready[i]),
                .core_read_block_data(core_dmem_read_data[i]),
                .core_write_valid(core_dmem_write_valid[i]),
                .core_write_block_addr(core_dmem_write_addr[i]),
                .core_write_block_data(core_dmem_write_data[i]),
                .core_write_strobe(core_dmem_write_strobe[i]),
                .core_write_ready(core_dmem_write_ready[i]),
                
                // memory side routes UP to L2 cache
                .mem_read_valid(dcache_mem_read_valid[i]),
                .mem_read_block_addr(dcache_mem_read_addr[i]),
                .mem_read_ready(dcache_mem_read_ready[i]),
                .mem_read_block_data(dcache_mem_read_data[i]),
                .mem_write_valid(dcache_mem_write_valid[i]),
                .mem_write_block_addr(dcache_mem_write_addr[i]),
                .mem_write_block_data(dcache_mem_write_data[i]),
                .mem_write_strobe(dcache_mem_write_strobe[i]),
                .mem_write_ready(dcache_mem_write_ready[i]),
                
                .flush_en(flush_caches_global),
                .flush_done(l1_dcache_flush_done[i]),
                
                .ev_read_acc(dc_ev_r_acc), .ev_read_hit(dc_ev_r_hit), .ev_read_stall(dc_ev_r_stall),
                .ev_write_acc(dc_ev_w_acc), .ev_write_hit(dc_ev_w_hit), .ev_write_stall(dc_ev_w_stall)
            );
        end
    endgenerate

endmodule