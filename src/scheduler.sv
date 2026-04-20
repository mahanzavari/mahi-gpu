`default_nettype none
`timescale 1ns/1ns

module scheduler #(
    parameter THREADS_PER_BLOCK = 4,
    parameter NUM_WARPS = 4,
    parameter STACK_DEPTH = 8
) (
    input wire clk,
    input wire reset,
    input wire start,
    input wire [$clog2(NUM_WARPS * THREADS_PER_BLOCK):0] thread_count,
    
    // Memory Wait Feedback (From LSU)
    input wire mem_req_valid,
    input wire [$clog2(NUM_WARPS)-1:0] mem_req_warp_id,
    input wire [NUM_WARPS-1:0] warp_mem_ready,
    
    // Frontend Stall (From Fetcher)
    input wire frontend_stall, 
    
    // Output to IF Pipeline Stage
    output reg flush_warp_valid,
    output reg [$clog2(NUM_WARPS)-1:0] flush_warp_id,
    
    output reg [7:0] if_pc,
    output reg [THREADS_PER_BLOCK-1:0] sched_active_mask,
    output reg [$clog2(NUM_WARPS)-1:0] sched_warp_id,
    output reg valid_issue,
    
    // Backend (Execution Monitoring)
    input wire ex_valid,
    input wire [$clog2(NUM_WARPS)-1:0] ex_warp_id,
    input wire [THREADS_PER_BLOCK-1:0] ex_active_mask,
    input wire [7:0] ex_pc,
    input wire [7:0] ex_next_pc [THREADS_PER_BLOCK-1:0],
    input wire ex_ret,
    
    output reg done
);

    typedef enum logic [1:0] { IDLE, READY, WAITING_MEM, DONE_STATE } warp_state_t;
    warp_state_t warp_state [NUM_WARPS-1:0];

    reg [7:0] warp_pc [NUM_WARPS-1:0];
    reg [THREADS_PER_BLOCK-1:0] warp_mask [NUM_WARPS-1:0];
    reg [THREADS_PER_BLOCK-1:0] warp_done_mask [NUM_WARPS-1:0];
    reg [THREADS_PER_BLOCK-1:0] warp_target_mask [NUM_WARPS-1:0];
    
    // SIMT Stack per warp
    reg [(8 + THREADS_PER_BLOCK - 1):0] simt_stack [NUM_WARPS-1:0][0:STACK_DEPTH-1];
    reg [$clog2(STACK_DEPTH):0] stack_ptr [NUM_WARPS-1:0];

    reg [$clog2(NUM_WARPS)-1:0] rr_ptr; // Round-robin issue pointer
    
    logic [THREADS_PER_BLOCK-1:0] taken_mask;
    logic [THREADS_PER_BLOCK-1:0] fallthrough_mask;
    logic [7:0] target_pc;

    always_comb begin
        taken_mask = 0;
        fallthrough_mask = 0;
        target_pc = 0;
        
        if (ex_valid) begin
            for (int i = 0; i < THREADS_PER_BLOCK; i++) begin
                if (ex_active_mask[i]) begin
                    if (ex_next_pc[i] != (ex_pc + 8'd1)) begin
                        taken_mask[i] = 1'b1;
                        target_pc = ex_next_pc[i]; 
                    end else begin
                        fallthrough_mask[i] = 1'b1;
                    end
                end
            end
        end
    end

    integer w;
    logic all_warps_done;

    always @(posedge clk) begin
        if (reset) begin
            done <= 0;
            valid_issue <= 0;
            flush_warp_valid <= 0;
            flush_warp_id <= 0;
            rr_ptr <= 0;
            if_pc <= 0;
            sched_active_mask <= 0;
            sched_warp_id <= 0;
            
            for (w = 0; w < NUM_WARPS; w++) begin
                warp_state[w] <= IDLE;
                warp_pc[w] <= 0;
                warp_mask[w] <= 0;
                warp_done_mask[w] <= 0;
                warp_target_mask[w] <= 0;
                stack_ptr[w] <= 0;
            end
        end else begin
            valid_issue <= 0;
            flush_warp_valid <= 0;

            if (start && warp_state[0] == IDLE && !done) begin
                $display("[%0t] [SCHEDULER] Core Started! Thread count received: %0d", $time, thread_count);
                for (w = 0; w < NUM_WARPS; w++) begin
                    int threads_for_this_warp = thread_count - (w * THREADS_PER_BLOCK);
                    if (threads_for_this_warp > 0) begin
                        if (threads_for_this_warp > THREADS_PER_BLOCK) threads_for_this_warp = THREADS_PER_BLOCK;
                        warp_state[w] <= READY;
                        warp_pc[w] <= 0;
                        warp_target_mask[w] <= (1 << threads_for_this_warp) - 1;
                        warp_mask[w] <= (1 << threads_for_this_warp) - 1;
                        warp_done_mask[w] <= 0;
                        stack_ptr[w] <= 0;
                        $display("[%0t] [SCHEDULER] Initialized Warp %0d | Target Mask: %b", $time, w, (1 << threads_for_this_warp) - 1);
                    end else begin
                        warp_state[w] <= DONE_STATE;
                    end
                end
            end

            for (w = 0; w < NUM_WARPS; w++) begin
                if (warp_state[w] == WAITING_MEM && warp_mem_ready[w]) begin
                    warp_state[w] <= READY;
                    $display("[%0t] [SCHEDULER] WAKING UP Warp %0d (Memory response received)", $time, w);
                end
            end

            if (mem_req_valid) begin
                warp_state[mem_req_warp_id] <= WAITING_MEM;
                $display("[%0t] [SCHEDULER] SLEEPING Warp %0d (Waiting for memory)", $time, mem_req_warp_id);
            end

            if (ex_valid && ex_active_mask != 0) begin
                if (ex_ret) begin
                    warp_done_mask[ex_warp_id] <= warp_done_mask[ex_warp_id] | ex_active_mask;
                    $display("[%0t] [SCHEDULER] Warp %0d thread(s) retired. DoneMask=%b, Target=%b", $time, ex_warp_id, warp_done_mask[ex_warp_id] | ex_active_mask, warp_target_mask[ex_warp_id]);
                    
                    if ((warp_done_mask[ex_warp_id] | ex_active_mask) == warp_target_mask[ex_warp_id]) begin
                        warp_state[ex_warp_id] <= DONE_STATE;
                        $display("[%0t] [SCHEDULER] *** Warp %0d completely finished! ***", $time, ex_warp_id);
                    end else if (stack_ptr[ex_warp_id] > 0) begin
                        stack_ptr[ex_warp_id] <= stack_ptr[ex_warp_id] - 1;
                        warp_pc[ex_warp_id] <= simt_stack[ex_warp_id][stack_ptr[ex_warp_id] - 1][7+THREADS_PER_BLOCK : THREADS_PER_BLOCK];
                        warp_mask[ex_warp_id] <= simt_stack[ex_warp_id][stack_ptr[ex_warp_id] - 1][THREADS_PER_BLOCK-1 : 0];
                        flush_warp_valid <= 1;
                        flush_warp_id <= ex_warp_id;
                        $display("[%0t] [SCHEDULER] Warp %0d SIMT POP: Resuming PC=%0d", $time, ex_warp_id, simt_stack[ex_warp_id][stack_ptr[ex_warp_id] - 1][7+THREADS_PER_BLOCK : THREADS_PER_BLOCK]);
                    end
                end else if (taken_mask != 0) begin
                    if (fallthrough_mask != 0) begin
                        simt_stack[ex_warp_id][stack_ptr[ex_warp_id]] <= { (ex_pc + 8'd1), fallthrough_mask };
                        stack_ptr[ex_warp_id] <= stack_ptr[ex_warp_id] + 1;
                        warp_pc[ex_warp_id] <= target_pc;
                        warp_mask[ex_warp_id] <= taken_mask;
                        flush_warp_valid <= 1;
                        flush_warp_id <= ex_warp_id;
                        $display("[%0t] [SCHEDULER] Warp %0d DIVERGENCE! Saved fallthrough PC=%0d. Branching to %0d.", $time, ex_warp_id, ex_pc + 8'd1, target_pc);
                    end else begin
                        warp_pc[ex_warp_id] <= target_pc;
                        flush_warp_valid <= 1;
                        flush_warp_id <= ex_warp_id;
                        $display("[%0t] [SCHEDULER] Warp %0d UNIFORM BRANCH to PC=%0d", $time, ex_warp_id, target_pc);
                    end
                end
            end

            if (start && !done && !frontend_stall) begin
                logic found;
                logic [$clog2(NUM_WARPS)-1:0] next_rr;
                found = 0;
                next_rr = rr_ptr;
                
                for (int i = 0; i < NUM_WARPS; i++) begin
                    if (!found && warp_state[(rr_ptr + i) % NUM_WARPS] == READY) begin
                        found = 1;
                        next_rr = (rr_ptr + i) % NUM_WARPS;
                    end
                end

                if (found) begin
                    if_pc <= warp_pc[next_rr];
                    sched_active_mask <= warp_mask[next_rr];
                    sched_warp_id <= next_rr;
                    valid_issue <= 1;
                    
                    warp_pc[next_rr] <= warp_pc[next_rr] + 1;
                    rr_ptr <= (next_rr + 1) % NUM_WARPS;
                    $display("[%0t] [SCOREBOARD] Issued Warp %0d | PC=%0d | Mask=%b", $time, next_rr, warp_pc[next_rr], warp_mask[next_rr]);
                end else begin
                    $display("[%0t] [SCOREBOARD] IDLE - All warps are sleeping or done.", $time);
                end
            end

            all_warps_done = 1;
            for (w = 0; w < NUM_WARPS; w++) begin
                if (warp_state[w] != DONE_STATE && warp_state[w] != IDLE) begin
                    all_warps_done = 0;
                end
            end
            
            if (start && all_warps_done && warp_state[0] != IDLE) begin
                done <= 1;
                $display("[%0t] [SCHEDULER] Core Done Signal Asserted.", $time);
            end
            if (!start) begin
                done <= 0;
                for (w = 0; w < NUM_WARPS; w++) warp_state[w] <= IDLE;
            end
        end
    end
endmodule