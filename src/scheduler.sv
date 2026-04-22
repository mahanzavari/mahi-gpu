`default_nettype none
`timescale 1ns/1ns
module scheduler #(
    parameter THREADS_PER_BLOCK = 4,
    parameter NUM_WARPS = 4
) (
    input wire clk,
    input wire reset,
    input wire start,
    input wire [$clog2(NUM_WARPS * THREADS_PER_BLOCK):0] thread_count,
    input wire mem_req_valid,
    input wire [$clog2(NUM_WARPS)-1:0] mem_warp_id,
    input wire [7:0] mem_pc, 
    input wire [NUM_WARPS-1:0] warp_mem_ready,
    input wire frontend_stall, 
    output reg [NUM_WARPS-1:0] flush_warp_mask, 
    output reg [7:0] if_pc,
    output reg [THREADS_PER_BLOCK-1:0] sched_active_mask,
    output reg [$clog2(NUM_WARPS)-1:0] sched_warp_id,
    output reg valid_issue,
    input wire ex_valid,
    input wire [$clog2(NUM_WARPS)-1:0] ex_warp_id,
    input wire [THREADS_PER_BLOCK-1:0] ex_active_mask,
    input wire [7:0] ex_pc,
    input wire [7:0] ex_next_pc [THREADS_PER_BLOCK], // CHANGED to [SIZE] to eliminate reversals 
    input wire ex_ret,
    output reg done
);
    typedef enum logic [1:0] { IDLE, READY, WAITING_MEM, DONE_STATE } warp_state_t;
    warp_state_t warp_state [NUM_WARPS-1:0];
    reg [7:0] arch_thread_pc [NUM_WARPS][THREADS_PER_BLOCK];
    reg [7:0] spec_thread_pc [NUM_WARPS][THREADS_PER_BLOCK];
    reg thread_active [NUM_WARPS][THREADS_PER_BLOCK];
    reg [$clog2(NUM_WARPS)-1:0] rr_ptr; 
    integer w, t;
    logic all_warps_done;
    logic pc_found;
    
    always @(posedge clk) begin
        if (reset) begin
            done <= 0;
            valid_issue <= 0;
            flush_warp_mask <= 0;
            rr_ptr <= 0;
            if_pc <= 0;
            sched_active_mask <= 0;
            sched_warp_id <= 0;
            for (w = 0; w < NUM_WARPS; w++) begin
                warp_state[w] <= IDLE;
                for (t = 0; t < THREADS_PER_BLOCK; t++) begin
                    arch_thread_pc[w][t] <= 0;
                    spec_thread_pc[w][t] <= 0;
                    thread_active[w][t] <= 0;
                end
            end
        end else begin
            valid_issue <= 0;
            flush_warp_mask <= 0;
            
            if (start && warp_state[0] == IDLE && !done) begin
                for (w = 0; w < NUM_WARPS; w++) begin
                    int threads_for_this_warp = thread_count - (w * THREADS_PER_BLOCK);
                    if (threads_for_this_warp > 0) begin
                        warp_state[w] <= READY;
                        for (t = 0; t < THREADS_PER_BLOCK; t++) begin
                            arch_thread_pc[w][t] <= 0;
                            spec_thread_pc[w][t] <= 0;
                            thread_active[w][t] <= (t < threads_for_this_warp) ? 1'b1 : 1'b0;
                        end
                    end else begin
                        warp_state[w] <= DONE_STATE;
                        for (t = 0; t < THREADS_PER_BLOCK; t++) begin
                            thread_active[w][t] <= 0;
                        end
                    end
                end
            end
            
            for (w = 0; w < NUM_WARPS; w++) begin
                if (warp_state[w] == WAITING_MEM && warp_mem_ready[w]) begin
                    warp_state[w] <= READY;
                end
            end
            
            if (mem_req_valid) begin
                warp_state[mem_warp_id] <= WAITING_MEM;
                flush_warp_mask[mem_warp_id] <= 1'b1;
                for (t = 0; t < THREADS_PER_BLOCK; t++) begin
                    spec_thread_pc[mem_warp_id][t] <= arch_thread_pc[mem_warp_id][t];
                end
            end
            
            if (ex_valid && ex_active_mask != 0 && !(mem_req_valid && mem_warp_id == ex_warp_id) && warp_state[ex_warp_id] != WAITING_MEM) begin
                logic branch_taken;
                branch_taken = 0;
                for (t = 0; t < THREADS_PER_BLOCK; t++) begin
                    if (ex_active_mask[t]) begin
                        if (ex_ret) begin
                            thread_active[ex_warp_id][t] <= 0;
                            arch_thread_pc[ex_warp_id][t] <= ex_pc;
                            branch_taken = 1; 
                        end else begin
                            arch_thread_pc[ex_warp_id][t] <= ex_next_pc[t];
                            if (ex_next_pc[t] != (ex_pc + 8'd1)) begin
                                branch_taken = 1; 
                            end
                        end
                    end
                end
                if (branch_taken) begin
                    flush_warp_mask[ex_warp_id] <= 1'b1;
                    for (t = 0; t < THREADS_PER_BLOCK; t++) begin
                        if (ex_active_mask[t]) begin
                            if (!ex_ret) spec_thread_pc[ex_warp_id][t] <= ex_next_pc[t];
                        end else begin
                            spec_thread_pc[ex_warp_id][t] <= arch_thread_pc[ex_warp_id][t];
                        end
                    end
                end
            end
            
            for (w = 0; w < NUM_WARPS; w++) begin
                if (warp_state[w] == READY || warp_state[w] == WAITING_MEM) begin
                    logic any_active;
                    any_active = 0;
                    for (t = 0; t < THREADS_PER_BLOCK; t++) begin
                        logic is_ret;
                        is_ret = (ex_valid && ex_warp_id == w && ex_active_mask[t] && ex_ret);
                        if (thread_active[w][t] && !is_ret) any_active = 1;
                    end
                    if (!any_active) begin
                        warp_state[w] <= DONE_STATE;
                    end
                end
            end
            
            // Allow bypassing frontend stall if the fetcher's scheduled warp was just forcibly flushed
            if (start && !done && (!frontend_stall || flush_warp_mask[sched_warp_id])) begin
                logic found;
                logic [$clog2(NUM_WARPS)-1:0] next_rr;
                logic [7:0] selected_pc;
                logic [THREADS_PER_BLOCK-1:0] issue_mask;
                found = 0;
                next_rr = rr_ptr;
                selected_pc = 0;
                issue_mask = 0;
                for (int i = 0; i < NUM_WARPS; i++) begin
                    if (!found && warp_state[(rr_ptr + i) % NUM_WARPS] == READY) begin
                        logic [$clog2(NUM_WARPS)-1:0] check_w;
                        check_w = (rr_ptr + i) % NUM_WARPS;
                        pc_found = 0;
                        for (t = 0; t < THREADS_PER_BLOCK; t++) begin
                            if (!pc_found && thread_active[check_w][t]) begin
                                selected_pc = spec_thread_pc[check_w][t];
                                pc_found = 1;
                            end
                        end
                        if (pc_found) begin
                            found = 1;
                            next_rr = check_w;
                            for (t = 0; t < THREADS_PER_BLOCK; t++) begin
                                if (thread_active[check_w][t] && spec_thread_pc[check_w][t] == selected_pc) begin
                                    issue_mask[t] = 1'b1;
                                end
                            end
                        end
                    end
                end
                if (found) begin
                    if_pc <= selected_pc;
                    sched_active_mask <= issue_mask;
                    sched_warp_id <= next_rr;
                    valid_issue <= 1;
                    for (t = 0; t < THREADS_PER_BLOCK; t++) begin
                        if (issue_mask[t]) begin
                            spec_thread_pc[next_rr][t] <= selected_pc + 1;
                        end
                    end
                    rr_ptr <= (next_rr + 1) % NUM_WARPS;
                end else begin
                    sched_active_mask <= 0;
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
            end
            if (!start) begin
                done <= 0;
                for (w = 0; w < NUM_WARPS; w++) warp_state[w] <= IDLE;
            end
        end
    end
endmodule