`default_nettype none
`timescale 1ns/1ns

module scheduler #(
    parameter THREADS_PER_BLOCK = 4
) (
    input wire clk,
    input wire reset,
    input wire start,

    input wire [$clog2(THREADS_PER_BLOCK):0] thread_count,
    
    // Control Signals
    input reg decoded_mem_read_enable,
    input reg decoded_mem_write_enable,
    input reg decoded_ret,
    input wire decoded_sync,

    // Memory Access State
    input reg [2:0] fetcher_state,
    input reg [1:0] lsu_state [THREADS_PER_BLOCK-1:0],

    // Current & Next PC
    output reg [7:0] current_pc,
    input reg [7:0] next_pc [THREADS_PER_BLOCK-1:0],

    // Execution State
    output reg [2:0] core_state,
    output reg [THREADS_PER_BLOCK-1:0] active_mask,
    output reg done
);
    localparam IDLE = 3'b000, 
        FETCH = 3'b001,       
        DECODE = 3'b010,      
        REQUEST = 3'b011,     
        WAIT = 3'b100,        
        EXECUTE = 3'b101,     
        UPDATE = 3'b110,      
        DONE = 3'b111;        

    reg is_sync_barrier;

    reg [THREADS_PER_BLOCK-1:0] stack_mask [0:7];
    reg [7:0] stack_pc [0:7];
    reg [2:0] stack_ptr;
    reg [7:0] target_a, target_b; // execution paths
    reg [THREADS_PER_BLOCK-1:0] mask_a, mask_b;
    reg has_diverged;

    always@(*) begin
        target_a = 0; target_b = 0;
        mask_a = 0; mask_b = 0;
        has_diverged = 0;
        for (int i = 0; i < THREADS_PER_BLOCK; i = i + 1) begin
            if(active_mask[i]) begin
                target_a = next_pc[i];
                break;
            end
        end
        for(int i = 0; i < THREADS_PER_BLOCK; i = i + 1) begin
            if (active_mask[i]) begin
                if (next_pc[i] == target_a) begin
                    mask_a[i] = 1'b1;
                end else begin
                    mask_b[i] = 1'b1;
                    target_b = next_pc[i];
                    has_diverged = 1'b1;
                end
            end
        end
    end
    
    always @(posedge clk) begin 
        if (reset) begin
            current_pc <= 0;
            core_state <= IDLE;
            done <= 0;
            active_mask <= 0;
            stack_ptr <= 0;
            is_sync_barrier <= 0;
        end else begin 
            case (core_state)
                IDLE: begin
                    if (start) begin 
                        active_mask <= (1 << thread_count) - 1;
                        stack_ptr <= 0;
                        is_sync_barrier <= 0;
                        core_state <= FETCH;
                        $display("[%0t] SCHEDULER (%m): START asserted. Moving to FETCH. PC=%0d, Mask=%b", $time, current_pc, (1 << thread_count) - 1);
                    end
                end
                FETCH: begin 
                    if (fetcher_state == 3'b010) begin 
                        core_state <= DECODE;
                    end
                end
                DECODE: begin
                    core_state <= REQUEST;
                end
                REQUEST: begin 
                    if (decoded_mem_read_enable || decoded_mem_write_enable) begin
                        $display("[%0t] SCHEDULER (%m): Mem request dispatched. Waiting for LSUs...", $time);
                    end
                    core_state <= WAIT;
                end
                WAIT: begin
                    reg any_lsu_waiting = 1'b0;
                    for (int i = 0; i < THREADS_PER_BLOCK; i++) begin
                        if (lsu_state[i] == 2'b01 || lsu_state[i] == 2'b10) begin
                            any_lsu_waiting = 1'b1;
                            break;
                        end
                    end

                    if (!any_lsu_waiting) begin
                        core_state <= EXECUTE;
                    end
                end
                EXECUTE: begin
                    if (decoded_sync) begin
                        is_sync_barrier <= 1'b1;
                        $display("[%0t] SCHEDULER (%m): SYNC barrier hit.", $time);
                    end
                    core_state <= UPDATE;
                end
                UPDATE: begin
                    if (is_sync_barrier) begin
                        reg all_idle;
                        all_idle = 1'b1;
                        for (int i = 0; i < THREADS_PER_BLOCK; i++) begin
                            if (active_mask[i] && lsu_state[i] != 2'b00) begin
                                all_idle = 1'b0;
                                break;
                            end
                        end
                        if (all_idle) begin
                            is_sync_barrier <= 1'b0;
                            $display("[%0t] SCHEDULER (%m): SYNC barrier resolved.", $time);
                        end else begin
                            // still waiting — stay in UPDATE
                        end
                    end

                    if (!is_sync_barrier) begin
                        if (decoded_ret) begin 
                            if (stack_ptr > 0) begin
                                stack_ptr   <= stack_ptr - 1;
                                active_mask <= stack_mask[stack_ptr - 1];
                                current_pc  <= stack_pc[stack_ptr - 1];
                                core_state  <= FETCH;
                                $display("[%0t] SCHEDULER (%m): RET encountered. Popped stack -> PC=%0d, Mask=%b", $time, stack_pc[stack_ptr - 1], stack_mask[stack_ptr - 1]);
                            end else begin
                                done       <= 1;
                                core_state <= DONE;
                                $display("[%0t] SCHEDULER (%m): Block execution DONE.", $time);
                            end
                        end else begin 
                            if (has_diverged) begin
                                stack_mask[stack_ptr] <= mask_b;
                                stack_pc[stack_ptr]   <= target_b;
                                stack_ptr             <= stack_ptr + 1;
                                active_mask           <= mask_a;
                                current_pc            <= target_a;
                                $display("[%0t] SCHEDULER (%m): Divergence detected! Path A (PC=%0d, Mask=%b), Path B (PC=%0d, Mask=%b) pushed.", $time, target_a, mask_a, target_b, mask_b);
                            end else begin
                                current_pc <= target_a;
                            end
                            core_state <= FETCH;
                        end
                    end
                end

                DONE: begin 
                end
            endcase
        end
    end
endmodule