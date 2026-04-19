`default_nettype none
`timescale 1ns/1ns

module scheduler #(
    parameter THREADS_PER_BLOCK = 4
) (
    input wire clk,
    input wire reset,
    input wire start,
    input wire [$clog2(THREADS_PER_BLOCK):0] thread_count,
    
    // Pipeline Controls
    input wire frontend_stall, // Freezes the PC
    input wire backend_stall,  // Freezes backend monitoring
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

    always @(posedge clk) begin
        if (reset) begin
            state <= IDLE;
            if_pc <= 0;
            sched_active_mask <= 0;
            done <= 0;
            pipeline_flush <= 0;
            done_mask <= 0;
        end else begin
            pipeline_flush <= 0; // Default to not flushing unless a branch is taken
            
            case (state)
                IDLE: begin
                    done <= 0;
                    done_mask <= 0;
                    if (start) begin
                        state <= RUNNING;
                        if_pc <= 0;
                        target_mask = (1 << thread_count) - 1;
                        sched_active_mask <= target_mask;
                        $display("[%0t] [SCHEDULER] Block Started. Mask = %b", $time, target_mask);
                    end
                end
                
                RUNNING: begin
                    // 1. Backend Monitoring: Only pause monitoring if the backend itself is frozen (LSU stall)
                    if (!backend_stall) begin
                        if (ex_ret && (|ex_active_mask)) begin
                            done_mask <= done_mask | ex_active_mask;
                            
                            if ((done_mask | ex_active_mask) == target_mask) begin
                                state <= DONE_STATE;
                                done <= 1;
                                sched_active_mask <= 0; // Stop fetching
                                $display("[%0t] [SCHEDULER] Block Finished! Releasing bus.", $time);
                            end
                        end 
                        else if (|ex_active_mask) begin
                            int first_active = 0;
                            for (int i = 0; i < THREADS_PER_BLOCK; i++) begin
                                if (ex_active_mask[i]) begin
                                    first_active = i;
                                    break;
                                end
                            end
                            
                            if (ex_next_pc[first_active] != ex_pc + 1) begin
                                if_pc <= ex_next_pc[first_active]; 
                                pipeline_flush <= 1;               
                                $display("[%0t] [SCHEDULER] Branch taken to PC=%0d. Flushing pipeline!", $time, ex_next_pc[first_active]);
                            end
                        end
                    end

                    // 2. Frontend Control: Freeze PC if either memory is stalling or fetch is waiting
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