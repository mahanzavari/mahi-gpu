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
    input wire [7:0] ex_next_pc [THREADS_PER_BLOCK],
    input wire ex_ret,
    input wire ex_sync,              // <-- NEW: sync barrier signal from pipeline
    output reg done
);

    // States (3-bit wide to hold 5 states)
    typedef enum logic [2:0] {
        IDLE,
        READY,
        WAITING_MEM,
        WAITING_BARRIER,       // <-- NEW
        DONE_STATE
    } warp_state_t;

    warp_state_t warp_state [NUM_WARPS-1:0];

    reg [7:0] arch_thread_pc [NUM_WARPS][THREADS_PER_BLOCK];
    reg [7:0] spec_thread_pc [NUM_WARPS][THREADS_PER_BLOCK];
    reg thread_active [NUM_WARPS][THREADS_PER_BLOCK];
    reg [$clog2(NUM_WARPS)-1:0] rr_ptr;

    // Barrier support
    reg [$clog2(NUM_WARPS+1):0] barrier_count;
    logic [$clog2(NUM_WARPS+1):0] num_active_warps_comb;

    integer w, t;
    logic all_warps_done;
    logic pc_found;
    integer w_cnt;

    // Combinational count of warps that are neither IDLE nor DONE_STATE
    always_comb begin
        num_active_warps_comb = 0;
        for (w_cnt = 0; w_cnt < NUM_WARPS; w_cnt++) begin
            if (warp_state[w_cnt] != IDLE && warp_state[w_cnt] != DONE_STATE)
                num_active_warps_comb = num_active_warps_comb + 1;
        end
    end

    always @(posedge clk) begin
        if (reset) begin
            done <= 0;
            valid_issue <= 0;
            flush_warp_mask <= 0;
            rr_ptr <= 0;
            if_pc <= 0;
            sched_active_mask <= 0;
            sched_warp_id <= 0;
            barrier_count <= 0;   // <-- NEW

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

            // ---- Initialise warps when start is asserted ----
            if (start && warp_state[0] == IDLE && !done) begin
                for (w = 0; w < NUM_WARPS; w++) begin
                    automatic int threads_for_this_warp = thread_count - (w * THREADS_PER_BLOCK);
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

            // ---- Memory completion releases a warp ----
            for (w = 0; w < NUM_WARPS; w++) begin
                if (warp_state[w] == WAITING_MEM && warp_mem_ready[w]) begin
                    warp_state[w] <= READY;
                end
            end

            // ---- A memory request stalls the warp ----
            if (mem_req_valid) begin
                warp_state[mem_warp_id] <= WAITING_MEM;
                flush_warp_mask[mem_warp_id] <= 1'b1;
                for (t = 0; t < THREADS_PER_BLOCK; t++) begin
                    spec_thread_pc[mem_warp_id][t] <= arch_thread_pc[mem_warp_id][t];
                end
            end

            // ---- Execute stage completion: branch/ret/sync handling ----
            if (ex_valid && ex_active_mask != 0 &&
                !(mem_req_valid && mem_warp_id == ex_warp_id) &&
                warp_state[ex_warp_id] != WAITING_MEM) begin

                logic branch_taken;
                branch_taken = 1'b0;

                // A SYNC instruction forces a pipeline flush (like a branch)
                if (ex_sync)
                    branch_taken = 1'b1;

                for (t = 0; t < THREADS_PER_BLOCK; t++) begin
                    if (ex_active_mask[t]) begin
                        if (ex_ret) begin
                            thread_active[ex_warp_id][t] <= 0;
                            arch_thread_pc[ex_warp_id][t] <= ex_pc;
                            branch_taken = 1;
                        end else begin
                            arch_thread_pc[ex_warp_id][t] <= ex_next_pc[t];
                            if (ex_next_pc[t] != (ex_pc + 8'd1))
                                branch_taken = 1;
                        end
                    end
                end

                if (branch_taken) begin
                    flush_warp_mask[ex_warp_id] <= 1'b1;
                    for (t = 0; t < THREADS_PER_BLOCK; t++) begin
                        if (ex_active_mask[t]) begin
                            if (!ex_ret)
                                spec_thread_pc[ex_warp_id][t] <= ex_next_pc[t];
                        end else begin
                            spec_thread_pc[ex_warp_id][t] <= arch_thread_pc[ex_warp_id][t];
                        end
                    end
                end
            end

            // ---- Barrier entry: warp reaches SYNC ----
            if (ex_valid && ex_sync && warp_state[ex_warp_id] == READY) begin
                warp_state[ex_warp_id] <= WAITING_BARRIER;
                barrier_count <= barrier_count + 1;
            end

            // ---- Barrier release: all active warps have arrived ----
            if (barrier_count >= num_active_warps_comb && num_active_warps_comb > 0) begin
                for (int w_rel = 0; w_rel < NUM_WARPS; w_rel++) begin
                    if (warp_state[w_rel] == WAITING_BARRIER)
                        warp_state[w_rel] <= READY;
                end
                barrier_count <= 0;
            end

            // ---- Check if any warp has no active threads left ----
            for (w = 0; w < NUM_WARPS; w++) begin
                if (warp_state[w] == READY || warp_state[w] == WAITING_MEM) begin
                    logic any_active;
                    any_active = 0;
                    for (t = 0; t < THREADS_PER_BLOCK; t++) begin
                        logic is_ret;
                        is_ret = (ex_valid && ex_warp_id == w && ex_active_mask[t] && ex_ret);
                        if (thread_active[w][t] && !is_ret)
                            any_active = 1;
                    end
                    if (!any_active) begin
                        warp_state[w] <= DONE_STATE;
                    end
                end
            end

            // ---- Warp issue (round‑robin) ----
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
                                if (thread_active[check_w][t] && spec_thread_pc[check_w][t] == selected_pc)
                                    issue_mask[t] = 1'b1;
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
                        if (issue_mask[t])
                            spec_thread_pc[next_rr][t] <= selected_pc + 1;
                    end
                    rr_ptr <= (next_rr + 1) % NUM_WARPS;
                end else begin
                    sched_active_mask <= 0;
                end
            end

            // ---- Global done detection ----
            all_warps_done = 1;
            for (w = 0; w < NUM_WARPS; w++) begin
                if (warp_state[w] != DONE_STATE && warp_state[w] != IDLE)
                    all_warps_done = 0;
            end
            if (start && all_warps_done && warp_state[0] != IDLE) begin
                done <= 1;
            end
            if (!start) begin
                done <= 0;
                for (w = 0; w < NUM_WARPS; w++)
                    warp_state[w] <= IDLE;
            end
        end
    end
endmodule