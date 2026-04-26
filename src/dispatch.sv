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
    output reg [7:0] core_block_id [NUM_CORES-1:0],
    output reg [$clog2(THREADS_PER_BLOCK * NUM_WARPS):0] core_thread_count [NUM_CORES-1:0],

    output reg done
);
    localparam THREADS_PER_CORE = THREADS_PER_BLOCK * NUM_WARPS;
    wire [7:0] total_blocks = (thread_count + THREADS_PER_CORE - 1) / THREADS_PER_CORE;

    reg [7:0] blocks_dispatched; 
    reg [7:0] blocks_done; 
    reg start_execution; 
    reg is_running; 

    always @(posedge clk) begin
        if (reset) begin
            done <= 0;
            blocks_dispatched = 0;
            blocks_done = 0;
            start_execution <= 0;
            is_running <= 0;

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
                    $display("[%0t] [DISPATCH] Started. Global Threads=%0d, Blocks=%0d, ThreadsPerCore=%0d", $time, thread_count, total_blocks, THREADS_PER_CORE);
                end

                for (int i = 0; i < NUM_CORES; i++) begin
                    if (core_reset[i]) begin 
                        core_reset[i] <= 0;
                        if (blocks_dispatched < total_blocks) begin 
                            core_start[i] <= 1;
                            core_block_id[i] <= blocks_dispatched;
                            
                            // Calculate remainder threads for the last block
                            if (blocks_dispatched == total_blocks - 1 && (thread_count % THREADS_PER_CORE) != 0) begin
                                core_thread_count[i] <= thread_count % THREADS_PER_CORE;
                            end else begin
                                core_thread_count[i] <= THREADS_PER_CORE;
                            end

                            $display("[%0t] [DISPATCH] Launching Core %0d -> Block %0d (Driving core_thread_count to %0d)", $time, i, blocks_dispatched, core_thread_count[i]);
                            blocks_dispatched = blocks_dispatched + 1;
                        end
                    end
                    
                    if (core_start[i] && core_done[i]) begin
                        $display("[%0t] [DISPATCH] Core %0d finished Block %0d", $time, i, core_block_id[i]);
                        core_reset[i] <= 1;
                        core_start[i] <= 0;
                        blocks_done = blocks_done + 1;
                    end
                end

                if (blocks_done == total_blocks && total_blocks > 0) begin 
                    done <= 1;
                    is_running <= 0;
                    $display("[%0t] [DISPATCH] All blocks finished.", $time);
                end
            end else begin
                done <= 0;
            end
        end
    end
endmodule