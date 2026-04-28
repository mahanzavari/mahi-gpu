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
    input wire [31:0] mem_pc, // FIX: 32-bit PC
    input wire [NUM_WARPS-1:0] warp_mem_ready,
    input wire frontend_stall,
    output reg [NUM_WARPS-1:0] flush_warp_mask,
    output reg [31:0] if_pc, // FIX: 32-bit PC
    output reg [THREADS_PER_BLOCK-1:0] sched_active_mask,
    output reg [$clog2(NUM_WARPS)-1:0] sched_warp_id,
    output reg valid_issue,
    input wire ex_valid,
    input wire [$clog2(NUM_WARPS)-1:0] ex_warp_id,
    input wire [THREADS_PER_BLOCK-1:0] ex_active_mask,
    input wire [31:0] ex_pc, // FIX: 32-bit PC
    input wire [31:0] ex_next_pc [THREADS_PER_BLOCK], // FIX: 32-bit PC Array
    input wire ex_exit,
    input wire ex_sync,
    output reg done
);

    typedef enum logic [2:0] { IDLE, READY, WAITING_MEM, WAITING_BARRIER, DONE_STATE } warp_state_t;
    warp_state_t warp_state [NUM_WARPS];

    // --- HARDWARE SIMT RECONVERGENCE STACK ---
    localparam STACK_DEPTH = 4;
    reg [31:0] current_pc [NUM_WARPS]; // FIX: 32-bit PC
    reg [THREADS_PER_BLOCK-1:0] current_mask [NUM_WARPS];
    
    reg [31:0] stack_pc [NUM_WARPS][STACK_DEPTH]; // FIX: 32-bit PC
    reg [THREADS_PER_BLOCK-1:0] stack_mask [NUM_WARPS][STACK_DEPTH];
    reg [$clog2(STACK_DEPTH+1)-1:0] stack_ptr [NUM_WARPS];

    reg [$clog2(NUM_WARPS)-1:0] rr_ptr;
    reg [$clog2(NUM_WARPS+1):0] barrier_count;
    logic [$clog2(NUM_WARPS+1):0] num_active_warps_comb;
    logic all_warps_done;

    integer w, t;

    always_comb begin
        num_active_warps_comb = 0;
        for (int i = 0; i < NUM_WARPS; i++) begin
            if (warp_state[i] != IDLE && warp_state[i] != DONE_STATE)
                num_active_warps_comb = num_active_warps_comb + 1;
        end
    end

    always @(posedge clk) begin
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
                    int threads_for_this_warp = thread_count - (w * THREADS_PER_BLOCK);
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
            end

            if (mem_req_valid) begin
                warp_state[mem_warp_id] <= WAITING_MEM;
                flush_warp_mask[mem_warp_id] <= 1'b1;
                current_pc[mem_warp_id] <= mem_pc + 1;
            end

            if (ex_valid && ex_active_mask != 0 && !(mem_req_valid && mem_warp_id == ex_warp_id) && warp_state[ex_warp_id] != WAITING_MEM) begin
                
                logic [31:0] target_a, target_b; // FIX: 32-bit PC
                logic [THREADS_PER_BLOCK-1:0] mask_a, mask_b;
                logic is_divergent, is_branch, is_reconverge;

                target_a = 32'hFFFFFFFF; target_b = 32'hFFFFFFFF;
                mask_a = 0; mask_b = 0;
                is_divergent = 0; is_branch = 0;

                for (t = 0; t < THREADS_PER_BLOCK; t++) begin
                    if (ex_active_mask[t]) begin
                        if (!ex_exit) begin
                            if (target_a == 32'hFFFFFFFF) begin
                                target_a = ex_next_pc[t]; mask_a[t] = 1'b1;
                            end else if (ex_next_pc[t] == target_a) begin
                                mask_a[t] = 1'b1;
                            end else begin
                                target_b = ex_next_pc[t]; mask_b[t] = 1'b1; is_divergent = 1;
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
                        warp_state[ex_warp_id] <= DONE_STATE; current_mask[ex_warp_id] <= 0;
                        flush_warp_mask[ex_warp_id] <= 1'b1;
                    end
                end else if (is_divergent) begin
                    stack_pc[ex_warp_id][stack_ptr[ex_warp_id]] <= target_b;
                    stack_mask[ex_warp_id][stack_ptr[ex_warp_id]] <= mask_b;
                    stack_ptr[ex_warp_id] <= stack_ptr[ex_warp_id] + 1;

                    current_pc[ex_warp_id] <= target_a; current_mask[ex_warp_id] <= mask_a;
                    flush_warp_mask[ex_warp_id] <= 1'b1;
                end else begin
                    is_reconverge = (stack_ptr[ex_warp_id] > 0 && target_a == stack_pc[ex_warp_id][stack_ptr[ex_warp_id]-1]);

                    if (is_reconverge) begin
                        current_pc[ex_warp_id] <= target_a;
                        current_mask[ex_warp_id] <= mask_a | stack_mask[ex_warp_id][stack_ptr[ex_warp_id]-1];
                        stack_ptr[ex_warp_id] <= stack_ptr[ex_warp_id] - 1;
                        flush_warp_mask[ex_warp_id] <= 1'b1;
                    end else if (is_branch || ex_sync) begin
                        current_pc[ex_warp_id] <= target_a; current_mask[ex_warp_id] <= mask_a;
                        flush_warp_mask[ex_warp_id] <= 1'b1;
                        if (ex_sync) begin
                            warp_state[ex_warp_id] <= WAITING_BARRIER; barrier_count <= barrier_count + 1;
                        end
                    end
                end
            end

            if (barrier_count >= num_active_warps_comb && num_active_warps_comb > 0) begin
                for (int w_rel = 0; w_rel < NUM_WARPS; w_rel++) begin
                    if (warp_state[w_rel] == WAITING_BARRIER) warp_state[w_rel] <= READY;
                end
                barrier_count <= 0;
            end

            if (start && !done && (!frontend_stall || flush_warp_mask[sched_warp_id])) begin
                logic found = 0; logic [$clog2(NUM_WARPS)-1:0] next_rr = rr_ptr;

                for (int i = 0; i < NUM_WARPS; i++) begin
                    logic [$clog2(NUM_WARPS)-1:0] check_w = (rr_ptr + i) % NUM_WARPS;
                    if (!found && warp_state[check_w] == READY && current_mask[check_w] != 0) begin
                        found = 1; next_rr = check_w;
                    end
                end

                if (found) begin
                    if_pc <= current_pc[next_rr]; sched_active_mask <= current_mask[next_rr];
                    sched_warp_id <= next_rr; valid_issue <= 1;
                    current_pc[next_rr] <= current_pc[next_rr] + 1; 
                    rr_ptr <= (next_rr + 1) % NUM_WARPS;
                end else begin
                    sched_active_mask <= 0; valid_issue <= 0;
                end
            end

            all_warps_done = 1;
            for (w = 0; w < NUM_WARPS; w++) begin
                if (warp_state[w] != DONE_STATE && warp_state[w] != IDLE) all_warps_done = 0;
            end
            if (start && all_warps_done && warp_state[0] != IDLE) done <= 1;
            if (!start) begin
                done <= 0;
                for (w = 0; w < NUM_WARPS; w++) warp_state[w] <= IDLE;
            end
        end
    end
endmodule