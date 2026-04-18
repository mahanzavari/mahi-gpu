`default_nettype none
`timescale 1ns/1ns

// SCHEDULER / PIPELINE CONTROLLER
// > Manages Hazard Detection, Branch Flushing, and SIMT Divergence
// > Observes the Execute (EX) stage to control the Fetcher and Pipeline Registers
module scheduler #(
    parameter THREADS_PER_BLOCK = 4
) (
    input wire clk,
    input wire reset,
    input wire start,

    input wire [$clog2(THREADS_PER_BLOCK):0] thread_count,
    
    // Pipeline Hazard Controls
    input wire pipeline_stall,   // Comes from LSU waiting for memory
    output reg pipeline_flush,   // Clears IF and ID stages on control flow change
    
    // Fetch Stage Controls
    output reg [7:0] if_pc,
    output reg [THREADS_PER_BLOCK-1:0] sched_active_mask,
    
    // Execute (EX) Stage Feedback
    input wire [THREADS_PER_BLOCK-1:0] ex_active_mask,
    input wire [7:0] ex_pc,
    input wire [7:0] ex_next_pc [THREADS_PER_BLOCK-1:0],
    input wire ex_ret,
    input wire ex_sync,

    // Execution State
    output reg done
);
    typedef enum logic [1:0] { IDLE, RUNNING, DONE_STATE } state_t;
    state_t state;

    // SIMT Divergence Stack
    reg [THREADS_PER_BLOCK-1:0] stack_mask [0:7];
    reg [7:0] stack_pc [0:7];
    reg [2:0] stack_ptr;

    // Synchronization & Completion Tracking
    reg [THREADS_PER_BLOCK-1:0] sync_mask;
    reg [THREADS_PER_BLOCK-1:0] done_mask;

    // Combinational evaluation of divergence and branch targets in EX stage
    reg [7:0] target_a, target_b;
    reg [THREADS_PER_BLOCK-1:0] mask_a, mask_b;
    reg has_diverged;

    always_comb begin
        target_a = 0; target_b = 0;
        mask_a = 0; mask_b = 0;
        has_diverged = 0;

        for (int i = 0; i < THREADS_PER_BLOCK; i = i + 1) begin
            if (ex_active_mask[i]) begin
                target_a = ex_next_pc[i];
                break;
            end
        end
        for (int i = 0; i < THREADS_PER_BLOCK; i = i + 1) begin
            if (ex_active_mask[i]) begin
                if (ex_next_pc[i] == target_a) begin
                    mask_a[i] = 1'b1;
                end else begin
                    mask_b[i] = 1'b1;
                    target_b = ex_next_pc[i];
                    has_diverged = 1'b1;
                end
            end
        end
    end

    // Combinational flush logic (Instantly squashes invalid instructions in IF/ID)
    always_comb begin
        pipeline_flush = 1'b0;
        if (state == RUNNING && !pipeline_stall && (|ex_active_mask)) begin
            // Flush if thread returns, synchronizes, diverges, or takes a standard branch
            if (ex_ret || ex_sync || has_diverged || (target_a != ex_pc + 1)) begin
                pipeline_flush = 1'b1;
            end
        end
    end

    always @(posedge clk) begin 
        if (reset) begin
            state <= IDLE;
            done <= 0;
            if_pc <= 0;
            sched_active_mask <= 0;
            stack_ptr <= 0;
            sync_mask <= 0;
            done_mask <= 0;
        end else begin 
            case (state)
                IDLE: begin
                    if (start) begin 
                        state <= RUNNING;
                        if_pc <= 0;
                        sched_active_mask <= (1 << thread_count) - 1;
                        done <= 0;
                        stack_ptr <= 0;
                        sync_mask <= 0;
                        done_mask <= 0;
                        $display("[%0t] SCHEDULER: START asserted. Running block.", $time);
                    end
                end
                
                RUNNING: begin 
                    if (!pipeline_stall) begin
                        if (pipeline_flush) begin
                            // Handle Control Flow Updates synchronously as instruction officially leaves EX stage
                            if (ex_ret) begin 
                                done_mask <= done_mask | ex_active_mask;
                                if ((done_mask | ex_active_mask) == ((1 << thread_count) - 1)) begin
                                    state <= DONE_STATE;
                                    done <= 1'b1;
                                    $display("[%0t] SCHEDULER: Block execution DONE.", $time);
                                end else begin
                                    // Pop divergent path from stack
                                    if (stack_ptr > 0) begin
                                        sched_active_mask <= stack_mask[stack_ptr - 1];
                                        if_pc <= stack_pc[stack_ptr - 1];
                                        stack_ptr <= stack_ptr - 1;
                                    end else begin
                                        sched_active_mask <= 0;
                                    end
                                end
                            end else if (ex_sync) begin
                                sync_mask <= sync_mask | ex_active_mask;
                                if ((sync_mask | ex_active_mask) == ((1 << thread_count) - 1)) begin
                                    // Barrier met! Wake all threads
                                    sched_active_mask <= (1 << thread_count) - 1;
                                    if_pc <= target_a;
                                    sync_mask <= 0;
                                    $display("[%0t] SCHEDULER: SYNC barrier resolved.", $time);
                                end else begin
                                    // Pop stack and wait at barrier
                                    if (stack_ptr > 0) begin
                                        sched_active_mask <= stack_mask[stack_ptr - 1];
                                        if_pc <= stack_pc[stack_ptr - 1];
                                        stack_ptr <= stack_ptr - 1;
                                    end else begin
                                        sched_active_mask <= 0;
                                    end
                                end
                            end else if (has_diverged) begin
                                // SIMT Divergence
                                stack_mask[stack_ptr] <= mask_b;
                                stack_pc[stack_ptr]   <= target_b;
                                stack_ptr             <= stack_ptr + 1;
                                sched_active_mask     <= mask_a;
                                if_pc                 <= target_a;
                                $display("[%0t] SCHEDULER: Divergence detected! Path A (PC=%0d), Path B (PC=%0d) pushed.", $time, target_a, target_b);
                            end else begin
                                // Standard Branch
                                if_pc <= target_a;
                            end
                        end else begin
                            // Default sequential fetching
                            if_pc <= if_pc + 1;
                        end
                    end
                end

                DONE_STATE: begin 
                    // Wait for dispatch module to reset core
                end
            endcase
        end
    end
endmodule