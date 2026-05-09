`default_nettype none
`timescale 1ns/1ns

module scheduler #(
    parameter THREADS_PER_BLOCK = 4,
    parameter NUM_WARPS = 4,
    parameter PROGRAM_MEM_ADDR_BITS = 32
) (
    input wire clk,
    input wire reset,
    input wire start,
    input wire [$clog2(NUM_WARPS * THREADS_PER_BLOCK):0] thread_count,
    input wire mem_req_valid,
    input wire [$clog2(NUM_WARPS)-1:0] mem_warp_id,
    input wire [PROGRAM_MEM_ADDR_BITS-1:0] mem_pc,
    input wire [NUM_WARPS-1:0] warp_mem_ready,
    input wire [NUM_WARPS-1:0] mem_in_progress,
    input wire frontend_stall,
    output reg [NUM_WARPS-1:0] flush_warp_mask,
    output reg [PROGRAM_MEM_ADDR_BITS-1:0] if_pc,
    output reg [THREADS_PER_BLOCK-1:0] sched_active_mask,
    output reg [$clog2(NUM_WARPS)-1:0] sched_warp_id,
    output reg valid_issue,
    input wire ex_valid,
    input wire [$clog2(NUM_WARPS)-1:0] ex_warp_id,
    input wire [THREADS_PER_BLOCK-1:0] ex_active_mask,
    input wire [PROGRAM_MEM_ADDR_BITS-1:0] ex_pc,
    input wire [PROGRAM_MEM_ADDR_BITS-1:0] ex_next_pc [THREADS_PER_BLOCK],
    input wire ex_exit,
    input wire ex_sync,
    input wire ex_exception_valid,
    output reg done,

    // --- PMU Event Pulses ---
    output wire ev_scheduler_idle,
    output wire ev_warp_switch,
    output wire ev_diverge
);

    typedef enum logic [2:0] { IDLE, READY, WAITING_MEM, WAITING_BARRIER, DONE_STATE, FAULTED } warp_state_t;
    warp_state_t warp_state [NUM_WARPS];

    localparam STACK_DEPTH = 4;
    reg [PROGRAM_MEM_ADDR_BITS-1:0] current_pc [NUM_WARPS];
    reg [THREADS_PER_BLOCK-1:0] current_mask [NUM_WARPS];
    
    reg [PROGRAM_MEM_ADDR_BITS-1:0] stack_pc [NUM_WARPS][STACK_DEPTH];
    reg [THREADS_PER_BLOCK-1:0] stack_mask [NUM_WARPS][STACK_DEPTH];
    reg [$clog2(STACK_DEPTH+1)-1:0] stack_ptr [NUM_WARPS];

    reg [$clog2(NUM_WARPS)-1:0] rr_ptr;
    reg [$clog2(NUM_WARPS+1):0] barrier_count;
    logic [$clog2(NUM_WARPS+1):0] num_active_warps_comb;
    logic all_warps_done;

    logic [NUM_WARPS-1:0] warp_flush_inhibit;
    logic ex_is_branch, ex_has_divergence;

    always_comb begin
        logic [PROGRAM_MEM_ADDR_BITS-1:0] comb_target_a;
        logic comb_target_a_valid;
        
        ex_is_branch = 1'b0;
        ex_has_divergence = 1'b0;
        comb_target_a_valid = 1'b0;
        warp_flush_inhibit = '0;
        num_active_warps_comb = 0;
        
        for (int i = 0; i < NUM_WARPS; i++) begin
            if (warp_state[i] != IDLE && warp_state[i] != DONE_STATE && warp_state[i] != FAULTED) begin
                num_active_warps_comb = num_active_warps_comb + 1;
            end
        end
        
        if (ex_valid && ex_active_mask != 0) begin
            for (int t = 0; t < THREADS_PER_BLOCK; t++) begin
                if (ex_active_mask[t]) begin
                    if (!ex_exit) begin
                        if (!comb_target_a_valid) begin
                            comb_target_a = ex_next_pc[t];
                            comb_target_a_valid = 1'b1;
                        end else if (ex_next_pc[t] != comb_target_a) begin
                            ex_has_divergence = 1;
                        end
                        if (ex_next_pc[t] != (ex_pc + 1))
                            ex_is_branch = 1;
                    end
                end
            end
        end

        if (ex_valid && ex_active_mask != 0 &&
            !(mem_req_valid && mem_warp_id == ex_warp_id) &&
            warp_state[ex_warp_id] != WAITING_MEM) begin
            if (ex_exception_valid || ex_exit || ex_has_divergence || ex_is_branch || ex_sync)
                warp_flush_inhibit[ex_warp_id] = 1'b1;
        end
        if (mem_req_valid && warp_state[mem_warp_id] != WAITING_MEM)
            warp_flush_inhibit[mem_warp_id] = 1'b1;
    end

    integer w, t;
    always @(posedge clk) begin : sched_seq
        int threads_for_this_warp;
        logic found_var;
        logic [$clog2(NUM_WARPS)-1:0] next_rr_var;
        logic [$clog2(NUM_WARPS)-1:0] check_w_var;

        if (reset) begin
            done <= 0; valid_issue <= 0; flush_warp_mask <= 0;
            rr_ptr <= 0; if_pc <= 0; sched_active_mask <= 0;
            sched_warp_id <= 0; barrier_count <= 0;

            for (w = 0; w < NUM_WARPS; w++) begin
                warp_state[w] <= IDLE; current_pc[w] <= 0;
                current_mask[w] <= 0; stack_ptr[w] <= 0;
            end
        end else begin
            valid_issue <= 0; flush_warp_mask <= 0;

            if (start && warp_state[0] == IDLE && !done) begin
                for (w = 0; w < NUM_WARPS; w++) begin
                    threads_for_this_warp = thread_count - (w * THREADS_PER_BLOCK);
                    if (threads_for_this_warp > THREADS_PER_BLOCK)
                        threads_for_this_warp = THREADS_PER_BLOCK;
                    if (threads_for_this_warp > 0) begin
                        warp_state[w] <= READY; current_pc[w] <= 0; stack_ptr[w] <= 0;
                        current_mask[w] <= (1 << threads_for_this_warp) - 1;
                    end else begin
                        warp_state[w] <= DONE_STATE; current_mask[w] <= 0;
                    end
                end
            end

            for (w = 0; w < NUM_WARPS; w++) begin
                if (warp_state[w] == WAITING_MEM && warp_mem_ready[w])
                    warp_state[w] <= READY;
            end

            if (mem_req_valid && warp_state[mem_warp_id] != WAITING_MEM) begin
                warp_state[mem_warp_id] <= WAITING_MEM;
                flush_warp_mask[mem_warp_id] <= 1'b1;
                current_pc[mem_warp_id] <= mem_pc + 1;
            end

            if (ex_valid && ex_active_mask != 0 &&
                !(mem_req_valid && mem_warp_id == ex_warp_id) &&
                warp_state[ex_warp_id] != WAITING_MEM) begin
                
                if (ex_exception_valid) begin
                    warp_state[ex_warp_id] <= FAULTED;
                    flush_warp_mask[ex_warp_id] <= 1'b1;
                end else begin
                    logic [PROGRAM_MEM_ADDR_BITS-1:0] target_a, target_b;
                    logic [THREADS_PER_BLOCK-1:0] mask_a, mask_b;
                    logic is_divergent, is_branch, is_reconverge;
                    logic target_a_valid, target_b_valid;

                    target_a_valid = 1'b0; target_b_valid = 1'b0;
                    mask_a = 0; mask_b = 0;
                    is_divergent = 0; is_branch = 0;

                    for (t = 0; t < THREADS_PER_BLOCK; t++) begin
                        if (ex_active_mask[t]) begin
                            if (!ex_exit) begin
                                if (!target_a_valid) begin
                                    target_a = ex_next_pc[t]; 
                                    mask_a[t] = 1'b1;
                                    target_a_valid = 1'b1;
                                end else if (ex_next_pc[t] == target_a) begin
                                    mask_a[t] = 1'b1;
                                end else begin
                                    target_b = ex_next_pc[t]; 
                                    mask_b[t] = 1'b1;
                                    is_divergent = 1;
                                    target_b_valid = 1'b1;
                                end
                                if (ex_next_pc[t] != (ex_pc + 1)) is_branch = 1;
                            end
                        end
                    end

                    if (ex_exit) begin
                        if (stack_ptr[ex_warp_id] > 0) begin
                            stack_ptr[ex_warp_id] <= stack_ptr[ex_warp_id] - 1;
                            current_pc[ex_warp_id] <= stack_pc[ex_warp_id][stack_ptr[ex_warp_id] - 1];
                            current_mask[ex_warp_id] <= stack_mask[ex_warp_id][stack_ptr[ex_warp_id] - 1];
                            flush_warp_mask[ex_warp_id] <= 1'b1;
                        end else begin
                            warp_state[ex_warp_id] <= DONE_STATE;
                            current_mask[ex_warp_id] <= 0;
                            flush_warp_mask[ex_warp_id] <= 1'b1;
                        end
                    end else if (is_divergent) begin
                        stack_pc[ex_warp_id][stack_ptr[ex_warp_id]] <= target_b;
                        stack_mask[ex_warp_id][stack_ptr[ex_warp_id]] <= mask_b;
                        stack_ptr[ex_warp_id] <= stack_ptr[ex_warp_id] + 1;

                        current_pc[ex_warp_id] <= target_a;
                        current_mask[ex_warp_id] <= mask_a;
                        flush_warp_mask[ex_warp_id] <= 1'b1;
                    end else begin
                        is_reconverge = (stack_ptr[ex_warp_id] > 0 && target_a_valid &&
                                         target_a == stack_pc[ex_warp_id][stack_ptr[ex_warp_id]-1]);

                        if (is_reconverge) begin
                            current_pc[ex_warp_id] <= target_a;
                            current_mask[ex_warp_id] <= mask_a | stack_mask[ex_warp_id][stack_ptr[ex_warp_id]-1];
                            stack_ptr[ex_warp_id] <= stack_ptr[ex_warp_id] - 1;
                            flush_warp_mask[ex_warp_id] <= 1'b1;
                        end else if (is_branch || ex_sync) begin
                            current_pc[ex_warp_id] <= target_a;
                            current_mask[ex_warp_id] <= mask_a;
                            flush_warp_mask[ex_warp_id] <= 1'b1;
                            if (ex_sync) begin
                                warp_state[ex_warp_id] <= WAITING_BARRIER;
                                barrier_count <= barrier_count + 1;
                            end
                        end
                    end
                end
            end

            if (barrier_count >= num_active_warps_comb && num_active_warps_comb > 0) begin
                for (int w_rel = 0; w_rel < NUM_WARPS; w_rel++) begin
                    if (warp_state[w_rel] == WAITING_BARRIER)
                        warp_state[w_rel] <= READY;
                end
                barrier_count <= 0;
            end

            if (start && !done && (!frontend_stall || flush_warp_mask[sched_warp_id])) begin
                found_var = 1'b0;
                next_rr_var = rr_ptr;

                for (int i = 0; i < NUM_WARPS; i++) begin
                    check_w_var = (rr_ptr + i) % NUM_WARPS;
                    if (!found_var && warp_state[check_w_var] == READY &&
                        current_mask[check_w_var] != 0 &&
                        !warp_flush_inhibit[check_w_var]) begin
                        found_var = 1'b1; next_rr_var = check_w_var;
                    end
                end

                if (found_var) begin
                    if_pc <= current_pc[next_rr_var];
                    sched_active_mask <= current_mask[next_rr_var];
                    sched_warp_id <= next_rr_var;
                    valid_issue <= 1;
                    current_pc[next_rr_var] <= current_pc[next_rr_var] + 1; 
                    rr_ptr <= (next_rr_var + 1) % NUM_WARPS;
                end else begin
                    sched_active_mask <= 0; valid_issue <= 0;
                end
            end

            all_warps_done = 1;
            for (w = 0; w < NUM_WARPS; w++) begin
                if (warp_state[w] != DONE_STATE && warp_state[w] != IDLE && warp_state[w] != FAULTED)
                    all_warps_done = 0;
                    
                // <--- FIX: Do not allow the core to exit if the LSU is still working!
                if (mem_in_progress[w])
                    all_warps_done = 0;
            end
            if (start && all_warps_done && warp_state[0] != IDLE) done <= 1;
            if (!start) begin
                done <= 0;
                for (w = 0; w < NUM_WARPS; w++) warp_state[w] <= IDLE;
            end
        end
    end
    // --- 1-Bit PMU Event Pulses ---
    reg [$clog2(NUM_WARPS)-1:0] prev_issued_warp;
    always @(posedge clk) begin
        if (reset) prev_issued_warp <= 0;
        else if (start && !done && valid_issue) prev_issued_warp <= sched_warp_id;
    end

    assign ev_scheduler_idle = (start && !done && !valid_issue && !frontend_stall);
    assign ev_warp_switch    = (start && !done && valid_issue && (sched_warp_id != prev_issued_warp));
    assign ev_diverge        = (start && !done && ex_valid && ex_active_mask != 0 && 
                               !(mem_req_valid && mem_warp_id == ex_warp_id) && 
                               warp_state[ex_warp_id] != WAITING_MEM && 
                               !ex_exception_valid && !ex_exit && ex_has_divergence);

endmodule