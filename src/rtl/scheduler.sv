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
    
    input wire fp_req_valid,
    input wire [$clog2(NUM_WARPS)-1:0] fp_warp_id,
    input wire [PROGRAM_MEM_ADDR_BITS-1:0] fp_pc,
    input wire fp_wb_valid,
    input wire [$clog2(NUM_WARPS)-1:0] fp_wb_warp_id,
    
    input wire frontend_stall,
    output reg [NUM_WARPS-1:0] flush_warp_mask,
    
    // --- Now Combinational Outputs ---
    output logic [PROGRAM_MEM_ADDR_BITS-1:0] if_pc,
    output logic [THREADS_PER_BLOCK-1:0] sched_active_mask,
    output logic [$clog2(NUM_WARPS)-1:0] sched_warp_id,
    output logic valid_issue,
    output logic found_var_comb,
    
    input wire ex_valid,
    input wire [$clog2(NUM_WARPS)-1:0] ex_warp_id,
    input wire [THREADS_PER_BLOCK-1:0] ex_active_mask,
    input wire [PROGRAM_MEM_ADDR_BITS-1:0] ex_pc,
    input wire [PROGRAM_MEM_ADDR_BITS-1:0] ex_next_pc [THREADS_PER_BLOCK],
    input wire ex_exit,
    input wire ex_sync,
    input wire ex_exception_valid,
    output reg done,

    output wire ev_scheduler_idle,
    output wire ev_warp_switch,
    output wire ev_diverge,
    output wire ev_stall_mem,      
    output wire ev_stall_barrier,  
    output wire ev_stall_noready   
);

    typedef enum logic [2:0] { IDLE, READY, WAITING_MEM, WAITING_BARRIER, WAITING_FP, DONE_STATE, FAULTED } warp_state_t;
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
        
        ex_is_branch = 1'b0; ex_has_divergence = 1'b0; comb_target_a_valid = 1'b0; warp_flush_inhibit = '0; num_active_warps_comb = 0;
        
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
                            comb_target_a = ex_next_pc[t]; comb_target_a_valid = 1'b1;
                        end else if (ex_next_pc[t] != comb_target_a) begin
                            ex_has_divergence = 1;
                        end
                        if (ex_next_pc[t] != (ex_pc + 1)) ex_is_branch = 1;
                    end
                end
            end
        end

        if (ex_valid && ex_active_mask != 0 && 
            !(mem_req_valid && mem_warp_id == ex_warp_id) && 
            !(fp_req_valid && fp_warp_id == ex_warp_id) && 
            warp_state[ex_warp_id] != WAITING_MEM && 
            warp_state[ex_warp_id] != WAITING_FP) begin
            if (ex_exception_valid || ex_exit || ex_has_divergence || ex_is_branch || ex_sync) warp_flush_inhibit[ex_warp_id] = 1'b1;
        end
        
        if (mem_req_valid && warp_state[mem_warp_id] != WAITING_MEM) warp_flush_inhibit[mem_warp_id] = 1'b1;
        if (fp_req_valid && warp_state[fp_warp_id] != WAITING_FP) warp_flush_inhibit[fp_warp_id] = 1'b1;
    end

    // --- NEW: Combinational Next-Warp & Issue Logic ---
    logic [$clog2(NUM_WARPS)-1:0] next_rr_var_comb;

    always_comb begin
        found_var_comb = 1'b0;
        next_rr_var_comb = rr_ptr;
        if (start && !done) begin
            for (int i = 0; i < NUM_WARPS; i++) begin
                logic [$clog2(NUM_WARPS)-1:0] check_w_var = (rr_ptr + i) % NUM_WARPS;
                logic will_flush = (ex_valid && ex_active_mask != 0 && ex_warp_id == check_w_var && warp_flush_inhibit[check_w_var]);
                if (!found_var_comb && warp_state[check_w_var] == READY && current_mask[check_w_var] != 0 && !warp_flush_inhibit[check_w_var] && !will_flush && !flush_warp_mask[check_w_var]) begin
                    found_var_comb = 1'b1;
                    next_rr_var_comb = check_w_var;
                end
            end
        end
    end

    // Point the memory fetch directly to the target PC combinationally
    assign if_pc = found_var_comb ? current_pc[next_rr_var_comb] : 0;

    always_comb begin
        if (found_var_comb && !frontend_stall) begin
            valid_issue = 1'b1;
            sched_active_mask = current_mask[next_rr_var_comb];
            sched_warp_id = next_rr_var_comb;
        end else begin
            valid_issue = 1'b0;
            sched_active_mask = 0;
            sched_warp_id = 0;
        end
    end

    integer w, t;
    always @(posedge clk) begin : sched_seq
        int threads_for_this_warp; 

        if (reset) begin
            done <= 0; flush_warp_mask <= 0;
            rr_ptr <= 0; barrier_count <= 0;

            for (w = 0; w < NUM_WARPS; w++) begin
                warp_state[w] <= IDLE; current_pc[w] <= 0;
                current_mask[w] <= 0; stack_ptr[w] <= 0;
            end
        end else begin
            flush_warp_mask <= 0;

            if (start && warp_state[0] == IDLE && !done) begin
                for (w = 0; w < NUM_WARPS; w++) begin
                    threads_for_this_warp = thread_count - (w * THREADS_PER_BLOCK);
                    if (threads_for_this_warp > THREADS_PER_BLOCK) threads_for_this_warp = THREADS_PER_BLOCK;
                    if (threads_for_this_warp > 0) begin
                        warp_state[w] <= READY; current_pc[w] <= 0; stack_ptr[w] <= 0;
                        current_mask[w] <= (1 << threads_for_this_warp) - 1;
                    end else begin
                        warp_state[w] <= DONE_STATE; current_mask[w] <= 0;
                    end
                end
            end

            for (w = 0; w < NUM_WARPS; w++) begin
                if (warp_state[w] == WAITING_MEM && warp_mem_ready[w]) warp_state[w] <= READY;
                if (warp_state[w] == WAITING_FP && fp_wb_valid && fp_wb_warp_id == w) warp_state[w] <= READY;
            end

            if (mem_req_valid && warp_state[mem_warp_id] != WAITING_MEM) begin
                warp_state[mem_warp_id] <= WAITING_MEM;
                flush_warp_mask[mem_warp_id] <= 1'b1;
                current_pc[mem_warp_id] <= mem_pc + 1;
            end

            if (fp_req_valid && warp_state[fp_warp_id] != WAITING_FP) begin
                warp_state[fp_warp_id] <= WAITING_FP;
                flush_warp_mask[fp_warp_id] <= 1'b1;
                current_pc[fp_warp_id] <= fp_pc + 1;
            end

            if (ex_valid && ex_active_mask != 0 && 
                !(mem_req_valid && mem_warp_id == ex_warp_id) && 
                !(fp_req_valid && fp_warp_id == ex_warp_id) && 
                warp_state[ex_warp_id] != WAITING_MEM && 
                warp_state[ex_warp_id] != WAITING_FP) begin
                
                if (ex_exception_valid) begin
                    $display("[%0t] [SCHED-FAULT] Warp %0d Faulted!", $time, ex_warp_id);
                    warp_state[ex_warp_id] <= FAULTED; flush_warp_mask[ex_warp_id] <= 1'b1;
                end else begin
                    logic [PROGRAM_MEM_ADDR_BITS-1:0] target_a, target_b;
                    logic [THREADS_PER_BLOCK-1:0] mask_a, mask_b;
                    logic is_divergent, is_branch, is_reconverge;
                    logic target_a_valid, target_b_valid;

                    target_a_valid = 1'b0; target_b_valid = 1'b0; mask_a = 0; mask_b = 0; is_divergent = 0; is_branch = 0;

                    for (t = 0; t < THREADS_PER_BLOCK; t++) begin
                        if (ex_active_mask[t]) begin
                            if (!ex_exit) begin
                                if (!target_a_valid) begin target_a = ex_next_pc[t]; mask_a[t] = 1'b1; target_a_valid = 1'b1;
                                end else if (ex_next_pc[t] == target_a) begin mask_a[t] = 1'b1;
                                end else begin target_b = ex_next_pc[t]; mask_b[t] = 1'b1; is_divergent = 1; target_b_valid = 1'b1; end
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
                            warp_state[ex_warp_id] <= DONE_STATE; current_mask[ex_warp_id] <= 0; flush_warp_mask[ex_warp_id] <= 1'b1;
                        end
                    end else if (is_divergent) begin
                        stack_pc[ex_warp_id][stack_ptr[ex_warp_id]] <= target_b; stack_mask[ex_warp_id][stack_ptr[ex_warp_id]] <= mask_b;
                        stack_ptr[ex_warp_id] <= stack_ptr[ex_warp_id] + 1;
                        current_pc[ex_warp_id] <= target_a; current_mask[ex_warp_id] <= mask_a; flush_warp_mask[ex_warp_id] <= 1'b1;
                    end else begin
                        is_reconverge = (stack_ptr[ex_warp_id] > 0 && target_a_valid && target_a == stack_pc[ex_warp_id][stack_ptr[ex_warp_id]-1]);
                        if (is_reconverge) begin
                            current_pc[ex_warp_id] <= target_a; current_mask[ex_warp_id] <= mask_a | stack_mask[ex_warp_id][stack_ptr[ex_warp_id]-1];
                            stack_ptr[ex_warp_id] <= stack_ptr[ex_warp_id] - 1; flush_warp_mask[ex_warp_id] <= 1'b1;
                        end else if (is_branch || ex_sync) begin
                            current_pc[ex_warp_id] <= target_a; current_mask[ex_warp_id] <= mask_a; flush_warp_mask[ex_warp_id] <= 1'b1;
                            if (ex_sync) begin 
                                if (warp_state[ex_warp_id] != WAITING_BARRIER) begin
                                    warp_state[ex_warp_id] <= WAITING_BARRIER; 
                                    barrier_count <= barrier_count + 1; 
                                end
                            end
                        end
                    end
                end
            end

            if (barrier_count >= num_active_warps_comb && num_active_warps_comb > 0) begin
                for (int w_rel = 0; w_rel < NUM_WARPS; w_rel++) if (warp_state[w_rel] == WAITING_BARRIER) warp_state[w_rel] <= READY;
                barrier_count <= 0;
            end

            // IF an instruction was physically accepted by the pipeline this cycle, increment PC!
            if (valid_issue) begin
                current_pc[next_rr_var_comb] <= current_pc[next_rr_var_comb] + 1;
                rr_ptr <= (next_rr_var_comb + 1) % NUM_WARPS;
            end

            all_warps_done = 1;
            for (w = 0; w < NUM_WARPS; w++) begin
                if (warp_state[w] != DONE_STATE && warp_state[w] != IDLE && warp_state[w] != FAULTED) all_warps_done = 0;
                if (mem_in_progress[w]) all_warps_done = 0;
            end
            if (start && all_warps_done && warp_state[0] != IDLE) done <= 1;
            if (!start) begin done <= 0; for (w = 0; w < NUM_WARPS; w++) warp_state[w] <= IDLE; end
        end
    end

    reg [$clog2(NUM_WARPS)-1:0] prev_issued_warp;
    always @(posedge clk) begin
        if (reset) prev_issued_warp <= 0;
        else if (start && !done && valid_issue) prev_issued_warp <= sched_warp_id;
    end

    logic any_waiting_mem, any_waiting_barrier, any_waiting_fp;
    always_comb begin
        any_waiting_mem = 0; any_waiting_barrier = 0; any_waiting_fp = 0;
        for (int i=0; i<NUM_WARPS; i++) begin
            if (warp_state[i] == WAITING_MEM) any_waiting_mem = 1;
            if (warp_state[i] == WAITING_BARRIER) any_waiting_barrier = 1;
            if (warp_state[i] == WAITING_FP) any_waiting_fp = 1;
        end
    end

    assign ev_scheduler_idle = (start && !done && !valid_issue && !frontend_stall);
    assign ev_warp_switch    = (start && !done && valid_issue && (sched_warp_id != prev_issued_warp));
    assign ev_diverge        = (start && !done && ex_valid && ex_active_mask != 0 && 
                               !(mem_req_valid && mem_warp_id == ex_warp_id) && 
                               !(fp_req_valid && fp_warp_id == ex_warp_id) && 
                               warp_state[ex_warp_id] != WAITING_MEM && 
                               warp_state[ex_warp_id] != WAITING_FP && 
                               !ex_exception_valid && !ex_exit && ex_has_divergence);
                               
    assign ev_stall_mem      = start && !done && any_waiting_mem;
    assign ev_stall_barrier  = start && !done && any_waiting_barrier;
    assign ev_stall_noready  = start && !done && !valid_issue && !frontend_stall && !(any_waiting_mem || any_waiting_barrier || any_waiting_fp);

endmodule