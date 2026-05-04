`default_nettype none
`timescale 1ns/1ns
module core #(
    parameter DATA_MEM_ADDR_BITS = 32,
    parameter DATA_MEM_DATA_BITS = 32,
    parameter PROGRAM_MEM_ADDR_BITS = 32,
    parameter PROGRAM_MEM_DATA_BITS = 32,
    parameter THREADS_PER_BLOCK = 4,
    parameter NUM_WARPS = 4,
    parameter SHARED_MEM_ADDR_BITS      = 8, 
    parameter SHARED_MEM_SIZE           = 256,
    parameter DATA_BITS = 32,
    parameter DEBUG = 1
) (
    input wire clk,
    input wire reset,
    input wire start,
    output wire done,
    input wire [7:0] block_id,
    input wire [$clog2(THREADS_PER_BLOCK * NUM_WARPS):0] thread_count,
    output wire program_mem_read_valid,
    output wire [PROGRAM_MEM_ADDR_BITS-1:0] program_mem_read_address,
    input wire program_mem_read_ready,
    input wire [PROGRAM_MEM_DATA_BITS-1:0] program_mem_read_data,
    
    output wire data_mem_read_valid,
    output wire [DATA_MEM_ADDR_BITS-1:0] data_mem_read_address,
    input wire data_mem_read_ready,
    input wire [(DATA_MEM_DATA_BITS*4)-1:0] data_mem_read_data, // WORDS_PER_BLOCK = 4
    output wire data_mem_write_valid,
    output wire [DATA_MEM_ADDR_BITS-1:0] data_mem_write_address,
    output wire [(DATA_MEM_DATA_BITS*4)-1:0] data_mem_write_data,
    output wire [3:0] data_mem_write_strobe,
    input wire data_mem_write_ready
);

    wire [THREADS_PER_BLOCK-1:0] lsu_we_array;
    wire [$clog2(NUM_WARPS)-1:0] lsu_warp_id_array [THREADS_PER_BLOCK];
    wire [4:0] lsu_rd_array;
    wire [DATA_BITS-1:0] lsu_data_array [THREADS_PER_BLOCK];

    wire if_instruction_valid; 
    wire fetch_stall = !if_instruction_valid;
    wire core_running = start && !done;
    wire [NUM_WARPS-1:0] flush_warp_mask;
    wire [THREADS_PER_BLOCK-1:0] sched_active_mask;
    wire [$clog2(NUM_WARPS)-1:0] sched_warp_id;
    wire [31:0] if_pc; // FIX: 32-bit PC
    wire valid_issue;
    wire frontend_stall = fetch_stall;
    wire fetcher_stall = !core_running; 
    wire [31:0] if_instruction;

    fetcher #(
        .PROGRAM_MEM_ADDR_BITS(PROGRAM_MEM_ADDR_BITS),
        .PROGRAM_MEM_DATA_BITS(PROGRAM_MEM_DATA_BITS)
    ) fetcher_instance (
        .clk(clk), .reset(reset),
        .stall(fetcher_stall), 
        .flush(flush_warp_mask[sched_warp_id]), 
        .current_pc(if_pc),
        .mem_read_valid(program_mem_read_valid),
        .mem_read_address(program_mem_read_address),
        .mem_read_ready(program_mem_read_ready),
        .mem_read_data(program_mem_read_data),
        .instruction_valid(if_instruction_valid),
        .instruction(if_instruction)
    );
    reg [31:0] id_instruction;
    reg [31:0] id_pc; // FIX: 32-bit PC
    reg [THREADS_PER_BLOCK-1:0] id_active_mask;
    reg [$clog2(NUM_WARPS)-1:0] id_warp_id;
    reg [$clog2(NUM_WARPS)-1:0] issued_warp_id;

    always @(posedge clk) begin
        if (reset) begin
            id_instruction <= 0;
            id_pc <= 0;
            id_active_mask <= 0;
            id_warp_id <= 0;
            issued_warp_id <= 0;
        end else if (flush_warp_mask[sched_warp_id]) begin 
            id_active_mask <= 0;
        end else begin 
        if (valid_issue)
            issued_warp_id <= sched_warp_id;

        // When the fetched instruction becomes valid, latch its warp ID
        if (if_instruction_valid)
            id_warp_id <= issued_warp_id;   // correct warp for this instruction
        else
            id_warp_id <= id_warp_id;       // hold previous value (optional, but safe)            

            id_instruction <= if_instruction_valid ? if_instruction : 0;
            id_pc <= if_pc;
            id_warp_id <= if_instruction_valid ? issued_warp_id : id_warp_id; // same as above, simplified  
            id_active_mask <= if_instruction_valid ? sched_active_mask : 0; 
        end
    end
    wire [4:0] id_rd, id_rs, id_rt;
    wire [2:0] id_nzp;
    wire [DATA_BITS-1:0] id_imm;
    wire id_reg_we, id_mem_re, id_mem_we, id_nzp_we;
    wire id_rs_re, id_rt_re; 
    wire [1:0] id_reg_mux;
    wire [2:0] id_alu_arith_mux;
    wire id_alu_out_mux, id_pc_mux, id_call, id_ret_fn, id_exit, id_sync;
    wire id_shared_re, id_shared_we;
    wire id_use_mem_offset;
    wire [15:0] id_mem_addr_offset;
    decoder #( .DATA_BITS(DATA_BITS) ) decoder_inst (
        .instruction(id_instruction),
        .decoded_rd_address(id_rd), .decoded_rs_address(id_rs), .decoded_rt_address(id_rt),
        .decoded_nzp(id_nzp), .decoded_immediate(id_imm), .decoded_use_mem_offset(id_use_mem_offset), 
        .decoded_mem_addr_offset(id_mem_addr_offset),
        .decoded_rs_read_enable(id_rs_re), .decoded_rt_read_enable(id_rt_re),
        .decoded_reg_write_enable(id_reg_we), .decoded_mem_read_enable(id_mem_re),
        .decoded_mem_write_enable(id_mem_we), .decoded_nzp_write_enable(id_nzp_we),
        .decoded_reg_input_mux(id_reg_mux), .decoded_alu_arithmetic_mux(id_alu_arith_mux),
        .decoded_alu_output_mux(id_alu_out_mux), .decoded_pc_mux(id_pc_mux),
        .decoded_sync(id_sync),
        .decoded_shared_read_enable(id_shared_re), .decoded_shared_write_enable(id_shared_we),
        .decoded_ret_fn(id_ret_fn), .decoded_exit(id_exit), .decoded_call(id_call)
    );

    wire [DATA_BITS-1:0] id_rs_data [THREADS_PER_BLOCK];
    wire [DATA_BITS-1:0] id_rt_data [THREADS_PER_BLOCK];
    reg [THREADS_PER_BLOCK-1:0] ex_active_mask;
    reg [$clog2(NUM_WARPS)-1:0] ex_warp_id;
    reg [31:0] ex_pc; // FIX: 32-bit PC
    reg [4:0] ex_rd, ex_rs, ex_rt;
    reg ex_rs_re, ex_rt_re;
    reg [2:0] ex_nzp;
    reg [DATA_BITS-1:0] ex_imm;
    reg [DATA_BITS-1:0] ex_rs_data [THREADS_PER_BLOCK];
    reg [DATA_BITS-1:0] ex_rt_data [THREADS_PER_BLOCK];
    reg ex_reg_we, ex_mem_re, ex_mem_we, ex_nzp_we;
    reg [1:0] ex_reg_mux;
    reg [2:0] ex_alu_arith_mux;
    reg ex_alu_out_mux, ex_pc_mux, ex_sync;
    reg ex_shared_re, ex_shared_we;
    reg ex_use_mem_offset;
    reg [15:0] ex_mem_addr_offset;
    reg ex_call, ex_ret_fn, ex_exit;
    always @(posedge clk) begin
        if (reset) begin
            ex_active_mask <= 0; ex_warp_id <= 0; ex_reg_we <= 0; ex_mem_re <= 0; ex_mem_we <= 0;
            ex_shared_re <= 0; ex_shared_we <= 0; ex_nzp_we <= 0; ex_sync <= 0; ex_pc_mux <= 0;
            ex_rs_re <= 0; ex_rt_re <= 0; ex_call <= 0; ex_ret_fn <= 0; ex_exit <= 0;
        end else if (flush_warp_mask[id_warp_id]) begin
            ex_active_mask <= 0; ex_call <= 0; ex_ret_fn <= 0; ex_exit <= 0;
        end else begin
            ex_active_mask <= id_active_mask; ex_warp_id <= id_warp_id; ex_pc <= id_pc;
            ex_rd <= id_rd; ex_rs <= id_rs; ex_rt <= id_rt; ex_rs_re <= id_rs_re; ex_rt_re <= id_rt_re;
            ex_nzp <= id_nzp; ex_imm <= id_imm;
            for (int j = 0; j < THREADS_PER_BLOCK; j++) begin
                ex_rs_data[j] <= id_rs_data[j];
                ex_rt_data[j] <= id_rt_data[j];
            end
            ex_reg_we <= id_reg_we; ex_mem_re <= id_mem_re; ex_mem_we <= id_mem_we;
            ex_nzp_we <= id_nzp_we; ex_reg_mux <= id_reg_mux; 
            ex_alu_arith_mux <= id_alu_arith_mux; ex_alu_out_mux <= id_alu_out_mux;
            ex_pc_mux <= id_pc_mux; ex_sync <= id_sync;
            ex_shared_re <= id_shared_re; ex_shared_we <= id_shared_we;
            ex_use_mem_offset <= id_use_mem_offset; ex_mem_addr_offset <= id_mem_addr_offset;
            ex_call <= id_call; ex_ret_fn <= id_ret_fn; ex_exit <= id_exit;
        end
    end

    wire [DATA_BITS-1:0] ex_alu_out [THREADS_PER_BLOCK];
    wire [PROGRAM_MEM_ADDR_BITS-1:0] ex_next_pc [THREADS_PER_BLOCK];
    reg [THREADS_PER_BLOCK-1:0] mem_active_mask;
    reg [$clog2(NUM_WARPS)-1:0] mem_warp_id;
    reg [31:0] mem_pc; // FIX: 32-bit PC
    reg [4:0] mem_rd;
    reg [DATA_BITS-1:0] mem_imm;
    reg [DATA_BITS-1:0] mem_alu_out [THREADS_PER_BLOCK];
    reg [DATA_BITS-1:0] mem_rs_data [THREADS_PER_BLOCK];
    reg [DATA_BITS-1:0] mem_rt_data [THREADS_PER_BLOCK]; 
    reg mem_reg_we, mem_mem_re, mem_mem_we, mem_shared_re, mem_shared_we, mem_ret;
    reg [1:0] mem_reg_mux;
    reg mem_use_mem_offset;
    reg [15:0] mem_mem_addr_offset;

    reg [THREADS_PER_BLOCK-1:0] wb_active_mask;
    reg [$clog2(NUM_WARPS)-1:0] wb_warp_id;
    reg [4:0] wb_rd;
    reg [DATA_BITS-1:0] wb_imm;
    reg [DATA_BITS-1:0] wb_alu_out [THREADS_PER_BLOCK];
    reg wb_reg_we;
    reg [1:0] wb_reg_mux;
    wire [DATA_BITS-1:0] fwd_ex_rs_data [THREADS_PER_BLOCK];
    wire [DATA_BITS-1:0] fwd_ex_rt_data [THREADS_PER_BLOCK];

    always @(posedge clk) begin
        if (reset) begin
            mem_active_mask <= 0; mem_warp_id <= 0; mem_reg_we <= 0; mem_mem_re <= 0; 
            mem_mem_we <= 0; mem_shared_re <= 0; mem_shared_we <= 0; mem_ret <= 0; mem_use_mem_offset <= 0;
        end else begin 
            mem_active_mask <= ex_active_mask; mem_warp_id <= ex_warp_id; mem_pc <= ex_pc;
            mem_rd <= ex_rd; mem_imm <= ex_imm;
            for (int j = 0; j < THREADS_PER_BLOCK; j++) begin
                mem_alu_out[j] <= ex_alu_out[j];
                mem_rs_data[j] <= fwd_ex_rs_data[j]; 
                mem_rt_data[j] <= fwd_ex_rt_data[j]; 
            end
            mem_reg_we <= ex_reg_we; mem_mem_re <= ex_mem_re; mem_mem_we <= ex_mem_we;
            mem_shared_re <= ex_shared_re; mem_shared_we <= ex_shared_we;
            mem_reg_mux <= ex_reg_mux; mem_use_mem_offset <= ex_use_mem_offset;
            mem_mem_addr_offset <= ex_mem_addr_offset;
        end
    end
    
    wire [THREADS_PER_BLOCK-1:0] sh_read_valid, sh_read_ready, sh_write_valid, sh_write_ready;
    wire [31:0] sh_read_address [THREADS_PER_BLOCK]; // FIX: 32-bit Array
    wire [31:0] sh_write_address [THREADS_PER_BLOCK]; // FIX: 32-bit Array
    wire [DATA_MEM_DATA_BITS-1:0] sh_read_data [THREADS_PER_BLOCK];
    wire [DATA_MEM_DATA_BITS-1:0] sh_write_data [THREADS_PER_BLOCK];
    
    shared_mem #( .DATA_BITS(DATA_MEM_DATA_BITS), .ADDR_BITS(32), .SIZE(SHARED_MEM_SIZE), .THREADS_PER_BLOCK(THREADS_PER_BLOCK) ) shared_mem_instance (
        .clk(clk), .reset(reset),
        .read_valid(sh_read_valid), .read_address(sh_read_address), .read_ready(sh_read_ready), .read_data(sh_read_data),
        .write_valid(sh_write_valid), .write_address(sh_write_address), .write_data(sh_write_data), .write_ready(sh_write_ready)
    );

    always @(posedge clk) begin
        if (reset) begin
            wb_active_mask <= 0; wb_warp_id <= 0; wb_reg_we <= 0;
        end else begin 
            if (mem_mem_re || mem_mem_we || mem_shared_re || mem_shared_we) begin
                wb_active_mask <= 0; wb_reg_we <= 0;
            end else begin
                wb_active_mask <= mem_active_mask; wb_warp_id <= mem_warp_id;
                wb_rd <= mem_rd; wb_imm <= mem_imm; wb_reg_we <= mem_reg_we; wb_reg_mux <= mem_reg_mux;
                for (int j = 0; j < THREADS_PER_BLOCK; j++) wb_alu_out[j] <= mem_alu_out[j];
            end
        end
    end
    wire is_mem_op = mem_mem_re | mem_mem_we | mem_shared_re | mem_shared_we;

    // Memory completion tracking – added for correct handshaking
    reg [NUM_WARPS-1:0] mem_in_progress;
    reg [3:0]           mem_pending_cnt [NUM_WARPS];

    // mem_req_valid goes high only when a warp starts a new memory operation.
wire mem_req_valid = (|mem_active_mask) && is_mem_op && !mem_in_progress[mem_warp_id];
    wire [THREADS_PER_BLOCK-1:0] lsu_done_pulse;
    wire [$clog2(NUM_WARPS)-1:0] lsu_done_warp [THREADS_PER_BLOCK];
    // --------------------------------------------------------------------
    // Correct memory completion tracking
// --------------------------------------------------------------------
// Correct memory completion tracking
reg [NUM_WARPS-1:0] warp_mem_ready;   // pulsed when a warp’s memory operation finishes
integer w, t;
integer cnt;

always @(posedge clk) begin
    if (reset) begin
        mem_in_progress <= 0;
        for (w = 0; w < NUM_WARPS; w++) mem_pending_cnt[w] <= 0;
        warp_mem_ready <= 0;
    end else begin
        warp_mem_ready <= 0;   // default – will be pulsed only when a warp finishes

        for (w = 0; w < NUM_WARPS; w = w + 1) begin

            // Detect a fresh memory request (the first cycle it appears)
            if ((|mem_active_mask) && is_mem_op && mem_warp_id == w && !mem_in_progress[w]) begin
                mem_in_progress[w] <= 1;
                // Count how many threads are active in this warp
                cnt = 0;
                for (t = 0; t < THREADS_PER_BLOCK; t = t + 1)
                    if (mem_active_mask[t]) cnt = cnt + 1;
                mem_pending_cnt[w] <= cnt;
            end

            // Process finishing memory requests
            else if (mem_in_progress[w]) begin
                
                // 1) Accumulate how many threads finished THIS specific cycle
                cnt = 0;
                for (t = 0; t < THREADS_PER_BLOCK; t = t + 1) begin
                    if (lsu_done_pulse[t] && lsu_done_warp[t] == w) begin
                        cnt = cnt + 1;
                    end
                end
                
                // 2) Deduct the accumulated amount from the pending threads tracker
                if (cnt > 0) begin
                    if (mem_pending_cnt[w] <= cnt) begin
                        mem_pending_cnt[w] <= 0;
                        mem_in_progress[w] <= 0;
                        warp_mem_ready[w] <= 1;
                    end else begin
                        mem_pending_cnt[w] <= mem_pending_cnt[w] - cnt;
                    end
                end else if (mem_pending_cnt[w] == 0) begin
                    // Fallback to safely clear the state in case it already hit 0
                    mem_in_progress[w] <= 0;
                    warp_mem_ready[w] <= 1;
                end
            end
            
        end
    end
end

    lsu #( .DATA_BITS(DATA_BITS), .NUM_WARPS(NUM_WARPS), .THREADS_PER_BLOCK(THREADS_PER_BLOCK), .WORDS_PER_BLOCK(4) ) lsu_inst (
        .clk(clk), .reset(reset), .enable_mask(mem_active_mask), .warp_id(mem_warp_id),
        .decoded_mem_read_enable(mem_mem_re), .decoded_mem_write_enable(mem_mem_we),
        .decoded_shared_read_enable(mem_shared_re), .decoded_shared_write_enable(mem_shared_we),
        .decoded_rd(mem_rd), .rs(mem_rs_data), .rt(mem_rt_data), 
        .mem_read_valid(data_mem_read_valid), .mem_read_block_address(data_mem_read_address),
        .mem_read_ready(data_mem_read_ready), .mem_read_block_data(data_mem_read_data),
        .mem_write_valid(data_mem_write_valid), .mem_write_block_address(data_mem_write_address),
        .mem_write_block_data(data_mem_write_data), .mem_write_strobe(data_mem_write_strobe), .mem_write_ready(data_mem_write_ready),
        .shared_mem_read_valid(sh_read_valid), .shared_mem_read_address(sh_read_address),
        .shared_mem_read_ready(sh_read_ready), .shared_mem_read_data(sh_read_data),
        .shared_mem_write_valid(sh_write_valid), .shared_mem_write_address(sh_write_address),
        .shared_mem_write_data(sh_write_data), .shared_mem_write_ready(sh_write_ready),
        .lsu_we(lsu_we_array), .lsu_warp_id(lsu_warp_id_array[0]), .lsu_rd(lsu_rd_array), .lsu_data(lsu_data_array),
        .done_pulse(lsu_done_pulse), .done_warp_id(lsu_done_warp),
        .addr_offset(mem_mem_addr_offset), .use_offset(mem_use_mem_offset) // FIX: Passes 16-bits
    );

    genvar i;
    generate
        for (i = 0; i < THREADS_PER_BLOCK; i = i + 1) begin : threads
            wire fwd_mem_rs_i = mem_active_mask[i] && mem_reg_we && (mem_rd == ex_rs) && (mem_rd < 29) && ex_rs_re && (mem_warp_id == ex_warp_id);
            wire fwd_mem_rt_i = mem_active_mask[i] && mem_reg_we && (mem_rd == ex_rt) && (mem_rd < 29) && ex_rt_re && (mem_warp_id == ex_warp_id);
            wire fwd_wb_rs_i  = wb_active_mask[i]  && wb_reg_we  && (wb_rd == ex_rs)  && (wb_rd < 29)  && ex_rs_re && !fwd_mem_rs_i && (wb_warp_id == ex_warp_id);
            wire fwd_wb_rt_i  = wb_active_mask[i]  && wb_reg_we  && (wb_rd == ex_rt)  && (wb_rd < 29)  && ex_rt_re && !fwd_mem_rt_i && (wb_warp_id == ex_warp_id);
            wire [DATA_BITS-1:0] fwd_mem_data_i = (mem_reg_mux == 2'b10) ? mem_imm : mem_alu_out[i];
            wire [DATA_BITS-1:0] fwd_wb_data_i  = (wb_reg_mux == 2'b10) ? wb_imm : wb_alu_out[i];
            assign fwd_ex_rs_data[i] = fwd_mem_rs_i ? fwd_mem_data_i : fwd_wb_rs_i ? fwd_wb_data_i : ex_rs_data[i];
            assign fwd_ex_rt_data[i] = fwd_mem_rt_i ? fwd_mem_data_i : fwd_wb_rt_i ? fwd_wb_data_i : ex_rt_data[i];
            alu #( .DATA_BITS(DATA_BITS) ) alu_inst (
                .enable(ex_active_mask[i]),
                .decoded_alu_arithmetic_mux(ex_alu_arith_mux), .decoded_alu_output_mux(ex_alu_out_mux),
                .rs(fwd_ex_rs_data[i]), .rt(fwd_ex_rt_data[i]), .alu_out(ex_alu_out[i])
            );
            pc #( .DATA_MEM_DATA_BITS(DATA_BITS), .PROGRAM_MEM_ADDR_BITS(PROGRAM_MEM_ADDR_BITS), .NUM_WARPS(NUM_WARPS) ) pc_inst (
                .clk(clk), .reset(reset), .enable(ex_active_mask[i]),
                .warp_id(ex_warp_id),
                .decoded_nzp(ex_nzp), .decoded_immediate(ex_imm),
                .decoded_nzp_write_enable(ex_nzp_we), .decoded_pc_mux(ex_pc_mux),
                .decoded_call(ex_call), .decoded_ret_fn(ex_ret_fn),
                .alu_out(ex_alu_out[i]), .current_pc(ex_pc), .next_pc(ex_next_pc[i])
            );
            wire [7:0] physical_thread_id = i; 
            registers #( .THREADS_PER_BLOCK(THREADS_PER_BLOCK), .NUM_WARPS(NUM_WARPS), .DATA_BITS(DATA_BITS) ) reg_inst (
                .clk(clk), .reset(reset), .enable(wb_active_mask[i]), .warp_id(wb_warp_id), 
                .read_warp_id(id_warp_id), .block_id(block_id), .thread_id(physical_thread_id),
                .decoded_rs_address(id_rs), .decoded_rt_address(id_rt), .rs(id_rs_data[i]), .rt(id_rt_data[i]),
                .decoded_rd_address(wb_rd), .decoded_reg_write_enable(wb_reg_we), .decoded_reg_input_mux(wb_reg_mux),
                .decoded_immediate(wb_imm), .alu_out(wb_alu_out[i]), .lsu_out(0), 
                .lsu_we(lsu_we_array[i]), .lsu_warp_id(lsu_warp_id_array[0]), .lsu_rd(lsu_rd_array), .lsu_data(lsu_data_array[i])
            );
        end
    endgenerate

    scheduler #( .THREADS_PER_BLOCK(THREADS_PER_BLOCK), .NUM_WARPS(NUM_WARPS) ) scheduler_instance (
        .clk(clk), .reset(reset), .start(start), .thread_count(thread_count),
        .mem_req_valid(mem_req_valid), .mem_warp_id(mem_warp_id), .mem_pc(mem_pc), .warp_mem_ready(warp_mem_ready),
        .frontend_stall(frontend_stall), .flush_warp_mask(flush_warp_mask),
        .if_pc(if_pc), .sched_active_mask(sched_active_mask), .sched_warp_id(sched_warp_id), .valid_issue(valid_issue),
        .ex_valid(|ex_active_mask), .ex_warp_id(ex_warp_id), .ex_active_mask(ex_active_mask),
        .ex_pc(ex_pc), .ex_next_pc(ex_next_pc), .ex_exit(ex_exit), .ex_sync(ex_sync), .done(done)
    );
endmodule