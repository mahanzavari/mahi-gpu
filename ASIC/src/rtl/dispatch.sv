`default_nettype none
`timescale 1ns/1ns

module dispatch #(
    parameter NUM_CORES = 2,
    parameter THREADS_PER_BLOCK = 4,
    parameter NUM_WARPS = 4
) (
    input wire clk,
    input wire reset,
    input wire start,

    input wire [7:0] thread_count,

    input wire [NUM_CORES-1:0] core_done,
    output reg [NUM_CORES-1:0] core_start,
    output reg [NUM_CORES-1:0] core_reset,
    output reg [7:0] core_block_id [NUM_CORES],
    output reg [$clog2(THREADS_PER_BLOCK * NUM_WARPS):0] core_thread_count [NUM_CORES],

    // --- Flush Control ---
    output reg flush_caches,
    input wire [NUM_CORES-1:0] cache_flush_done,

    output reg done
);
    localparam THREADS_PER_CORE = THREADS_PER_BLOCK * NUM_WARPS;
    wire [7:0] total_blocks = (thread_count + THREADS_PER_CORE - 1) / THREADS_PER_CORE;

    reg [7:0] blocks_dispatched; 
    reg [7:0] blocks_done; 
    reg start_execution; 
    reg is_running; 
    reg flushing;

    always @(posedge clk) begin
        if (reset) begin
            done <= 0;
            blocks_dispatched = 0;
            blocks_done = 0;
            start_execution <= 0;
            is_running <= 0;
            flush_caches <= 0;
            flushing <= 0;

            for (int i = 0; i < NUM_CORES; i++) begin
                core_start[i] <= 0;
                core_reset[i] <= 1;
                core_block_id[i] <= 0;
                core_thread_count[i] <= 0;
            end
        end else begin
            if (start) is_running <= 1;

            if (start || is_running) begin    
                if (!start_execution) begin 
                    start_execution <= 1;
                    for (int i = 0; i < NUM_CORES; i++) core_reset[i] <= 1;
                end

                for (int i = 0; i < NUM_CORES; i++) begin
                    if (core_reset[i] && !flushing) begin 
                        core_reset[i] <= 0;
                        if (blocks_dispatched < total_blocks) begin 
                            core_start[i] <= 1;
                            core_block_id[i] <= blocks_dispatched;
                            
                            if (blocks_dispatched == total_blocks - 1 && (thread_count % THREADS_PER_CORE) != 0) begin
                                core_thread_count[i] <= thread_count % THREADS_PER_CORE;
                            end else begin
                                core_thread_count[i] <= THREADS_PER_CORE;
                            end

                            blocks_dispatched = blocks_dispatched + 1;
                        end
                    end
                    
                    if (core_start[i] && core_done[i]) begin
                        core_reset[i] <= 1;
                        core_start[i] <= 0;
                        blocks_done = blocks_done + 1;
                    end
                end

                // Start Flush when all compute is done
                if (blocks_done == total_blocks && total_blocks > 0 && !flushing) begin 
                    flush_caches <= 1;
                    flushing <= 1;
                end

                // Finish completely when flush completes
                if (flushing && (&cache_flush_done)) begin
                    flush_caches <= 0;
                    flushing <= 0;
                    is_running <= 0;
                    done <= 1;
                end

            end else begin
                done <= 0;
            end
        end
    end
endmodule