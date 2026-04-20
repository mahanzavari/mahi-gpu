`default_nettype none
`timescale 1ns/1ns

module scheduler #(
    parameter THREADS_PER_BLOCK = 4,
    parameter STACK_DEPTH = 8
) (
    input wire clk,
    input wire reset,
    input wire start,
    input wire [$clog2(THREADS_PER_BLOCK):0] thread_count,
    
    // Pipeline Controls
    input wire frontend_stall, 
    input wire backend_stall,  
    output reg pipeline_flush,
    
    // Frontend (Fetch)
    output reg [7:0] if_pc,
    output reg [THREADS_PER_BLOCK-1:0] sched_active_mask,
    
    // Backend (Execution Monitoring)
    input wire [THREADS_PER_BLOCK-1:0] ex_active_mask,
    input wire [7:0] ex_pc,
    input wire [7:0] ex_next_pc [THREADS_PER_BLOCK-1:0],
    input wire ex_ret,
    input wire ex_sync,
    
    // Output to Dispatcher
    output reg done
);

    typedef enum logic [1:0] { IDLE, RUNNING, DONE_STATE } state_t;
    state_t state;

    reg [THREADS_PER_BLOCK-1:0] done_mask;
    reg [THREADS_PER_BLOCK-1:0] target_mask;

    // ==================== SIMT DIVERGENCE STACK ====================
    // Stores { PC (8 bits), Active_Mask (THREADS_PER_BLOCK bits) }
    reg [(8 + THREADS_PER_BLOCK - 1):0] simt_stack [0:STACK_DEPTH-1];
    reg [$clog2(STACK_DEPTH):0] stack_ptr;

    // Combinational Divergence Analysis
    logic [THREADS_PER_BLOCK-1:0] taken_mask;
    logic [THREADS_PER_BLOCK-1:0] fallthrough_mask;
    logic [7:0] target_pc;

    always_comb begin
        taken_mask = 0;
        fallthrough_mask = 0;
        target_pc = 0;
        
        for (int i = 0; i < THREADS_PER_BLOCK; i++) begin
            if (ex_active_mask[i]) begin
                if (ex_next_pc[i] != (ex_pc + 8'd1)) begin
                    taken_mask[i] = 1'b1;
                    target_pc = ex_next_pc[i]; // All taken threads branch to the same target
                end else begin
                    fallthrough_mask[i] = 1'b1;
                end
            end
        end
    end

    always @(posedge clk) begin
        if (reset) begin
            state <= IDLE;
            if_pc <= 0;
            sched_active_mask <= 0;
            done <= 0;
            pipeline_flush <= 0;
            done_mask <= 0;
            stack_ptr <= 0;
        end else begin
            pipeline_flush <= 0; // Default to not flushing unless a branch/pop occurs
            
            case (state)
                IDLE: begin
                    done <= 0;
                    done_mask <= 0;
                    stack_ptr <= 0;
                    if (start) begin
                        state <= RUNNING;
                        if_pc <= 0;
                        target_mask = (1 << thread_count) - 1;
                        sched_active_mask <= target_mask;
                        $display("[%0t] [SCHEDULER] Block Started. Mask = %b", $time, target_mask);
                    end
                end
                
                RUNNING: begin
                    // 1. Backend Monitoring: Check for Returns and Divergence
                    if (!backend_stall) begin
                        
                        // Handle Reconvergence at RET
                        if (ex_ret && (|ex_active_mask)) begin
                            done_mask <= done_mask | ex_active_mask;
                            
                            // If all threads in this block have retired, we are done!
                            if ((done_mask | ex_active_mask) == target_mask) begin
                                state <= DONE_STATE;
                                done <= 1;
                                sched_active_mask <= 0; 
                                $display("[%0t] [SCHEDULER] Block Finished! Releasing bus.", $time);
                            
                            // Otherwise, pop the stack to resume sleeping threads
                            end else if (stack_ptr > 0) begin
                                stack_ptr <= stack_ptr - 1;
                                if_pc <= simt_stack[stack_ptr - 1][7+THREADS_PER_BLOCK : THREADS_PER_BLOCK];
                                sched_active_mask <= simt_stack[stack_ptr - 1][THREADS_PER_BLOCK-1 : 0];
                                pipeline_flush <= 1;
                                
                                $display("[%0t] [SCHEDULER] SIMT POP: Resuming PC=%0d, Mask=%b", $time, 
                                    simt_stack[stack_ptr - 1][7+THREADS_PER_BLOCK : THREADS_PER_BLOCK],
                                    simt_stack[stack_ptr - 1][THREADS_PER_BLOCK-1 : 0]);
                            end
                            
                        // Handle Branching and Divergence
                        end else if (|ex_active_mask && (taken_mask != 0)) begin
                            if (fallthrough_mask != 0) begin
                                // ---> DIVERGENCE OCCURRED <---
                                // Push the fall-through path to the stack
                                simt_stack[stack_ptr] <= { (ex_pc + 8'd1), fallthrough_mask };
                                stack_ptr <= stack_ptr + 1;
                                
                                // Follow the taken path
                                if_pc <= target_pc;
                                sched_active_mask <= taken_mask;
                                pipeline_flush <= 1;
                                
                                $display("[%0t] [SCHEDULER] SIMT PUSH: Divergence! Stack[%0d] = {PC:%0d, Mask:%b}. Branching to PC=%0d, Mask:%b", 
                                    $time, stack_ptr, (ex_pc + 8'd1), fallthrough_mask, target_pc, taken_mask);
                            end else begin
                                // ---> UNIFORM BRANCH <--- (All active threads agreed to jump)
                                if_pc <= target_pc;
                                pipeline_flush <= 1;
                                $display("[%0t] [SCHEDULER] Uniform Branch taken to PC=%0d", $time, target_pc);
                            end
                        end
                    end

                    // 2. Frontend Control: Freeze PC if memory is stalling or fetch is waiting
                    if (!frontend_stall && !pipeline_flush && state == RUNNING) begin
                        if_pc <= if_pc + 1;
                    end
                end
                
                DONE_STATE: begin
                    if (!start) begin
                        state <= IDLE;
                        done <= 0;
                    end
                end
            endcase
        end
    end
endmodule