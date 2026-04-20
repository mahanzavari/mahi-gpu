`default_nettype none
`timescale 1ns/1ns

module gpu #(
    parameter DATA_MEM_ADDR_BITS = 8,
    parameter DATA_MEM_DATA_BITS = 16,
    parameter DATA_MEM_NUM_CHANNELS = 4,
    parameter PROGRAM_MEM_ADDR_BITS = 8,
    parameter PROGRAM_MEM_DATA_BITS = 16,
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

    output wire [PROGRAM_MEM_NUM_CHANNELS-1:0] program_mem_read_valid,
    output wire [PROGRAM_MEM_ADDR_BITS-1:0] program_mem_read_address [PROGRAM_MEM_NUM_CHANNELS],
    input wire [PROGRAM_MEM_NUM_CHANNELS-1:0] program_mem_read_ready,
    input wire [PROGRAM_MEM_DATA_BITS-1:0] program_mem_read_data [PROGRAM_MEM_NUM_CHANNELS],

    output wire [DATA_MEM_NUM_CHANNELS-1:0] data_mem_read_valid,
    output wire [DATA_MEM_ADDR_BITS-1:0] data_mem_read_address [DATA_MEM_NUM_CHANNELS],
    input wire [DATA_MEM_NUM_CHANNELS-1:0] data_mem_read_ready,
    input wire [DATA_MEM_DATA_BITS-1:0] data_mem_read_data [DATA_MEM_NUM_CHANNELS],
    output wire [DATA_MEM_NUM_CHANNELS-1:0] data_mem_write_valid,
    output wire [DATA_MEM_ADDR_BITS-1:0] data_mem_write_address [DATA_MEM_NUM_CHANNELS],
    output wire [DATA_MEM_DATA_BITS-1:0] data_mem_write_data [DATA_MEM_NUM_CHANNELS],
    input wire [DATA_MEM_NUM_CHANNELS-1:0] data_mem_write_ready
);
    wire [7:0] thread_count;

    // FIX: Using wires for outputs of the dispatch module
    wire [NUM_CORES-1:0] core_start;
    wire [NUM_CORES-1:0] core_reset;
    wire [NUM_CORES-1:0] core_done;
    wire [7:0] core_block_id [NUM_CORES-1:0];
    wire [$clog2(THREADS_PER_BLOCK * NUM_WARPS):0] core_thread_count [NUM_CORES-1:0];

    localparam NUM_LSUS = NUM_CORES * THREADS_PER_BLOCK;
    wire [NUM_LSUS-1:0] lsu_read_valid;
    wire [DATA_MEM_ADDR_BITS-1:0] lsu_read_address [NUM_LSUS];
    wire [NUM_LSUS-1:0] lsu_read_ready;
    wire [DATA_MEM_DATA_BITS-1:0] lsu_read_data [NUM_LSUS];
    wire [NUM_LSUS-1:0] lsu_write_valid;
    wire [DATA_MEM_ADDR_BITS-1:0] lsu_write_address [NUM_LSUS];
    wire [DATA_MEM_DATA_BITS-1:0] lsu_write_data [NUM_LSUS];
    wire [NUM_LSUS-1:0] lsu_write_ready;

    localparam NUM_FETCHERS = NUM_CORES;
    wire [NUM_FETCHERS-1:0] fetcher_read_valid;
    wire [PROGRAM_MEM_ADDR_BITS-1:0] fetcher_read_address [NUM_FETCHERS];
    wire [NUM_FETCHERS-1:0] fetcher_read_ready;
    wire [PROGRAM_MEM_DATA_BITS-1:0] fetcher_read_data [NUM_FETCHERS];
    
    dcr dcr_instance (
        .clk(clk), .reset(reset),
        .device_control_write_enable(device_control_write_enable),
        .device_control_data(device_control_data),
        .thread_count(thread_count)
    );

    controller #(
        .ADDR_BITS(DATA_MEM_ADDR_BITS), .DATA_BITS(DATA_MEM_DATA_BITS),
        .NUM_CONSUMERS(NUM_LSUS), .NUM_CHANNELS(DATA_MEM_NUM_CHANNELS)
    ) data_memory_controller (
        .clk(clk), .reset(reset),
        .consumer_read_valid(lsu_read_valid), .consumer_read_address(lsu_read_address),
        .consumer_read_ready(lsu_read_ready), .consumer_read_data(lsu_read_data),
        .consumer_write_valid(lsu_write_valid), .consumer_write_address(lsu_write_address),
        .consumer_write_data(lsu_write_data), .consumer_write_ready(lsu_write_ready),
        .mem_read_valid(data_mem_read_valid), .mem_read_address(data_mem_read_address),
        .mem_read_ready(data_mem_read_ready), .mem_read_data(data_mem_read_data),
        .mem_write_valid(data_mem_write_valid), .mem_write_address(data_mem_write_address),
        .mem_write_data(data_mem_write_data), .mem_write_ready(data_mem_write_ready)
    );

    controller #(
        .ADDR_BITS(PROGRAM_MEM_ADDR_BITS), .DATA_BITS(PROGRAM_MEM_DATA_BITS),
        .NUM_CONSUMERS(NUM_FETCHERS), .NUM_CHANNELS(PROGRAM_MEM_NUM_CHANNELS), .WRITE_ENABLE(0)
    ) program_memory_controller (
        .clk(clk), .reset(reset),
        .consumer_read_valid(fetcher_read_valid), .consumer_read_address(fetcher_read_address),
        .consumer_read_ready(fetcher_read_ready), .consumer_read_data(fetcher_read_data),
        .mem_read_valid(program_mem_read_valid), .mem_read_address(program_mem_read_address),
        .mem_read_ready(program_mem_read_ready), .mem_read_data(program_mem_read_data)
    );

    dispatch #(
        .NUM_CORES(NUM_CORES), .THREADS_PER_BLOCK(THREADS_PER_BLOCK), .NUM_WARPS(NUM_WARPS)
    ) dispatch_instance (
        .clk(clk), .reset(reset), .start(start), .thread_count(thread_count),
        .core_done(core_done), .core_start(core_start), .core_reset(core_reset),
        .core_block_id(core_block_id), .core_thread_count(core_thread_count), .done(done)
    );

    always @(posedge clk) begin
        if (start && !reset) begin
            $display("[%0t] [GPU] Top-level Start. DCR Thread Count=%0d", $time, thread_count);
        end
    end

    genvar i;
    generate
        for (i = 0; i < NUM_CORES; i = i + 1) begin : cores
            
            // Unpacked arrays (Reverted)
            wire [THREADS_PER_BLOCK-1:0] core_lsu_read_valid;
            wire [DATA_MEM_ADDR_BITS-1:0] core_lsu_read_address [THREADS_PER_BLOCK];
            wire [THREADS_PER_BLOCK-1:0] core_lsu_read_ready;
            wire [DATA_MEM_DATA_BITS-1:0] core_lsu_read_data [THREADS_PER_BLOCK];
            
            wire [THREADS_PER_BLOCK-1:0] core_lsu_write_valid;
            wire [DATA_MEM_ADDR_BITS-1:0] core_lsu_write_address [THREADS_PER_BLOCK];
            wire [DATA_MEM_DATA_BITS-1:0] core_lsu_write_data [THREADS_PER_BLOCK];
            wire [THREADS_PER_BLOCK-1:0] core_lsu_write_ready;

            genvar j;
            for (j = 0; j < THREADS_PER_BLOCK; j = j + 1) begin
                localparam lsu_index = i * THREADS_PER_BLOCK + j;
                
                assign lsu_read_address[lsu_index] = core_lsu_read_address[j];
                assign lsu_write_address[lsu_index] = core_lsu_write_address[j];
                assign lsu_write_data[lsu_index] = core_lsu_write_data[j];
                assign core_lsu_read_data[j] = lsu_read_data[lsu_index];
                
                assign lsu_read_valid[lsu_index] = core_lsu_read_valid[j];
                assign core_lsu_read_ready[j] = lsu_read_ready[lsu_index];
                
                assign lsu_write_valid[lsu_index] = core_lsu_write_valid[j];
                assign core_lsu_write_ready[j] = lsu_write_ready[lsu_index];
            end

            core #(
                .DATA_MEM_ADDR_BITS(DATA_MEM_ADDR_BITS), .DATA_MEM_DATA_BITS(DATA_MEM_DATA_BITS),
                .PROGRAM_MEM_ADDR_BITS(PROGRAM_MEM_ADDR_BITS), .PROGRAM_MEM_DATA_BITS(PROGRAM_MEM_DATA_BITS),
                .THREADS_PER_BLOCK(THREADS_PER_BLOCK), .NUM_WARPS(NUM_WARPS)
            ) core_instance (
                .clk(clk), .reset(core_reset[i]), .start(core_start[i]), .done(core_done[i]),
                .block_id(core_block_id[i]), .thread_count(core_thread_count[i]),
                
                .program_mem_read_valid(fetcher_read_valid[i]),
                .program_mem_read_address(fetcher_read_address[i]),
                .program_mem_read_ready(fetcher_read_ready[i]),
                .program_mem_read_data(fetcher_read_data[i]),

                .data_mem_read_valid(core_lsu_read_valid),
                .data_mem_read_address(core_lsu_read_address),
                .data_mem_read_ready(core_lsu_read_ready),
                .data_mem_read_data(core_lsu_read_data),
                .data_mem_write_valid(core_lsu_write_valid),
                .data_mem_write_address(core_lsu_write_address),
                .data_mem_write_data(core_lsu_write_data),
                .data_mem_write_ready(core_lsu_write_ready)
            );
            
            always @(posedge clk) begin
                if (!reset && core_start[i]) begin
                    $display("[%0t] [GPU] Wiring core_start[%0d]=1 | block_id=%0d | thread_count_wire=%0d", $time, i, core_block_id[i], core_thread_count[i]);
                end
            end
        end
    endgenerate
endmodule