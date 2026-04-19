`default_nettype none
`timescale 1ns/1ns

module dispatch #(
    parameter NUM_CORES = 2,
    parameter THREADS_PER_BLOCK = 4
) (
    input wire clk,
    input wire reset,
    input wire start,

    input wire [7:0] thread_count,

    input reg [NUM_CORES-1:0] core_done,
    output reg [NUM_CORES-1:0] core_start,
    output reg [NUM_CORES-1:0] core_reset,
    output reg [7:0] core_block_id [NUM_CORES-1:0],
    output reg [$clog2(THREADS_PER_BLOCK):0] core_thread_count [NUM_CORES-1:0],

    output reg done
);
    wire [7:0] total_blocks;
    assign total_blocks = (thread_count + THREADS_PER_BLOCK - 1) / THREADS_PER_BLOCK;

    reg [7:0] blocks_dispatched; 
    reg [7:0] blocks_done; 
    reg start_execution; 
    reg [7:0] next_blocks_dispatched;
    reg [7:0] temp_blocks_done;
    
    // NEW: Latch the start pulse
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
                core_thread_count[i] <= THREADS_PER_BLOCK;
            end
        end else begin
            // Latch the pulse
            if (start) is_running <= 1;

            // Run as long as the system is flagged as running
            if (start || is_running) begin    
                if (!start_execution) begin 
                    start_execution <= 1;
                    for (int i = 0; i < NUM_CORES; i++) begin
                        core_reset[i] <= 1;
                    end
                end

                next_blocks_dispatched = blocks_dispatched;
                for (int i = 0; i < NUM_CORES; i++) begin
                    if (core_reset[i]) begin 
                        core_reset[i] <= 0;
                        if (next_blocks_dispatched < total_blocks) begin 
                            core_start[i] <= 1;
                            core_block_id[i] <= next_blocks_dispatched;
                            core_thread_count[i] <= (next_blocks_dispatched == total_blocks - 1) 
                                ? thread_count - (next_blocks_dispatched * THREADS_PER_BLOCK)
                                : THREADS_PER_BLOCK;

                            next_blocks_dispatched = next_blocks_dispatched + 1;
                        end
                    end
                end
                blocks_dispatched <= next_blocks_dispatched;
                
                temp_blocks_done = blocks_done;
                for (int i = 0; i < NUM_CORES; i++) begin
                    if (core_start[i] && core_done[i]) begin
                        core_reset[i] <= 1;
                        core_start[i] <= 0;
                        temp_blocks_done = temp_blocks_done + 1;
                    end
                end
                blocks_done <= temp_blocks_done;

                if (temp_blocks_done == total_blocks) begin 
                    done <= 1;
                    is_running <= 0; // Clear the running flag when everything is finished
                end
            end
        end
    end
endmodule