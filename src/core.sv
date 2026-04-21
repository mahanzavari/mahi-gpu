`default_nettype none
`timescale 1ns/1ns

module core #(
    parameter DATA_MEM_ADDR_BITS = 8,
    parameter DATA_MEM_DATA_BITS = 16,
    parameter PROGRAM_MEM_ADDR_BITS = 8,
    parameter PROGRAM_MEM_DATA_BITS = 16,
    parameter THREADS_PER_BLOCK = 4,
    parameter NUM_WARPS = 4,
    parameter SHARED_MEM_ADDR_BITS      = 8, 
    parameter SHARED_MEM_SIZE           = 256,
    parameter DATA_BITS = 16,
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

    output wire [THREADS_PER_BLOCK-1:0] data_mem_read_valid,
    output wire [DATA_MEM_ADDR_BITS-1:0] data_mem_read_address [THREADS_PER_BLOCK-1:0],
    input wire [THREADS_PER_BLOCK-1:0] data_mem_read_ready,
    input wire [DATA_MEM_DATA_BITS-1:0] data_mem_read_data [THREADS_PER_BLOCK-1:0],
    output wire [THREADS_PER_BLOCK-1:0] data_mem_write_valid,
    output wire [DATA_MEM_ADDR_BITS-1:0] data_mem_write_address [THREADS_PER_BLOCK-1:0],
    output wire [DATA_MEM_DATA_BITS-1:0] data_mem_write_data [THREADS_PER_BLOCK-1:0],
    input wire [THREADS_PER_BLOCK-1:0] data_mem_write_ready
);

    wire if_instruction_valid; 
    wire fetch_stall = !if_instruction_valid;
    
    wire core_running = start && !done;

    wire [NUM_WARPS-1:0] flush_warp_mask;
    wire [THREADS_PER_BLOCK-1:0] sched_active_mask;
    wire [$clog2(NUM_WARPS)-1:0] sched_warp_id;
    wire [7:0] if_pc; 
    wire valid_issue;

    wire frontend_stall = fetch_stall;
    wire fetcher_stall = !core_running; 

    // -------------------------------------------------------------------------
    // 1. INSTRUCTION FETCH (IF) STAGE
    // -------------------------------------------------------------------------
    wire [15:0] if_instruction;

    fetcher #(
        .PROGRAM_MEM_ADDR_BITS(PROGRAM_MEM_ADDR_BITS),
        .PROGRAM_MEM_DATA_BITS(PROGRAM_MEM_DATA_BITS)
    ) fetcher_instance (
        .clk(clk), .reset(reset),
        .stall(fetcher_stall), 
        .flush(flush_warp_mask[sched_warp_id]), // FIX: Abort the fetcher if the active warp diverges
        .current_pc(if_pc),
        .mem_read_valid(program_mem_read_valid),
        .mem_read_address(program_mem_read_address),
        .mem_read_ready(program_mem_read_ready),
        .mem_read_data(program_mem_read_data),
        .instruction_valid(if_instruction_valid),
        .instruction(if_instruction)
    );

    // ==================== IF/ID PIPELINE REGISTER ====================
    reg [15:0] id_instruction;
    reg [7:0]  id_pc;
    reg [THREADS_PER_BLOCK-1:0] id_active_mask;
    reg [$clog2(NUM_WARPS)-1:0] id_warp_id;

    always @(posedge clk) begin
        if (reset) begin
            id_instruction <= 16'h0000;
            id_pc <= 0;
            id_active_mask <= 0;
            id_warp_id <= 0;
        end else if (flush_warp_mask[sched_warp_id]) begin // FIX: Clear the register based on sched_warp_id
            id_active_mask <= 0;
        end else begin 
            id_instruction <= if_instruction_valid ? if_instruction : 16'h0000;
            id_pc <= if_pc;
            id_warp_id <= sched_warp_id;
            id_active_mask <= if_instruction_valid ? sched_active_mask : 0; 
        end
    end

    // -------------------------------------------------------------------------
    // 2. INSTRUCTION DECODE (ID) STAGE
    // -------------------------------------------------------------------------
    wire [3:0] id_rd, id_rs, id_rt;
    wire [2:0] id_nzp;
    wire [DATA_BITS-1:0] id_imm;
    
    wire id_reg_we, id_mem_re, id_mem_we, id_nzp_we;
    wire id_rs_re, id_rt_re; 
    wire [1:0] id_reg_mux;
    wire [2:0] id_alu_arith_mux;
    wire id_alu_out_mux, id_pc_mux, id_ret, id_sync;
    wire id_shared_re, id_shared_we;

    decoder #( .DATA_BITS(DATA_BITS) ) decoder_inst (
        .instruction(id_instruction),
        .decoded_rd_address(id_rd), .decoded_rs_address(id_rs), .decoded_rt_address(id_rt),
        .decoded_nzp(id_nzp), .decoded_immediate(id_imm),
        .decoded_rs_read_enable(id_rs_re), .decoded_rt_read_enable(id_rt_re),
        .decoded_reg_write_enable(id_reg_we), .decoded_mem_read_enable(id_mem_re),
        .decoded_mem_write_enable(id_mem_we), .decoded_nzp_write_enable(id_nzp_we),
        .decoded_reg_input_mux(id_reg_mux), .decoded_alu_arithmetic_mux(id_alu_arith_mux),
        .decoded_alu_output_mux(id_alu_out_mux), .decoded_pc_mux(id_pc_mux),
        .decoded_ret(id_ret), .decoded_sync(id_sync),
        .decoded_shared_read_enable(id_shared_re), .decoded_shared_write_enable(id_shared_we)
    );
        always @(posedge clk) if (!reset) $display("[%0t] [PIPE ID->EX] warp=%0d pc=%0d instr=0x%04h act=%b rd=%0d rs=%0d rt=%0d memR=%0b memW=%0b ret=%0b",
        $time, id_warp_id, id_pc, id_instruction, id_active_mask, id_rd, id_rs, id_rt, id_mem_re, id_mem_we, id_ret);
    wire [DATA_BITS-1:0] id_rs_data [THREADS_PER_BLOCK-1:0];
    wire [DATA_BITS-1:0] id_rt_data [THREADS_PER_BLOCK-1:0];

    // ==================== ID/EX PIPELINE REGISTER ====================
    reg [THREADS_PER_BLOCK-1:0] ex_active_mask;
    reg [$clog2(NUM_WARPS)-1:0] ex_warp_id;
    reg [7:0] ex_pc;
    reg [3:0] ex_rd, ex_rs, ex_rt;
    reg ex_rs_re, ex_rt_re;
    reg [2:0] ex_nzp;
    reg [DATA_BITS-1:0] ex_imm;
    reg [DATA_BITS-1:0] ex_rs_data [THREADS_PER_BLOCK-1:0];
    reg [DATA_BITS-1:0] ex_rt_data [THREADS_PER_BLOCK-1:0];
    
    reg ex_reg_we, ex_mem_re, ex_mem_we, ex_nzp_we;
    reg [1:0] ex_reg_mux;
    reg [2:0] ex_alu_arith_mux;
    reg ex_alu_out_mux, ex_pc_mux, ex_ret, ex_sync;
    reg ex_shared_re, ex_shared_we;

    always @(posedge clk) begin
        if (reset) begin
            ex_active_mask <= 0;
            ex_warp_id <= 0;
            ex_reg_we <= 0; ex_mem_re <= 0; ex_mem_we <= 0;
            ex_shared_re <= 0; ex_shared_we <= 0;
            ex_nzp_we <= 0; ex_ret <= 0; ex_sync <= 0; ex_pc_mux <= 0;
            ex_rs_re <= 0; ex_rt_re <= 0;
        end else if (flush_warp_mask[id_warp_id]) begin
            ex_active_mask <= 0;
        end else begin
            ex_active_mask <= id_active_mask;
            ex_warp_id <= id_warp_id;
            ex_pc <= id_pc;
            ex_rd <= id_rd; ex_rs <= id_rs; ex_rt <= id_rt;
            ex_rs_re <= id_rs_re; ex_rt_re <= id_rt_re;
            ex_nzp <= id_nzp; ex_imm <= id_imm;
            for (int j = 0; j < THREADS_PER_BLOCK; j++) begin
                ex_rs_data[j] <= id_rs_data[j];
                ex_rt_data[j] <= id_rt_data[j];
            end
            ex_reg_we <= id_reg_we; ex_mem_re <= id_mem_re; ex_mem_we <= id_mem_we;
            ex_nzp_we <= id_nzp_we; ex_reg_mux <= id_reg_mux; 
            ex_alu_arith_mux <= id_alu_arith_mux; ex_alu_out_mux <= id_alu_out_mux;
            ex_pc_mux <= id_pc_mux; ex_ret <= id_ret; ex_sync <= id_sync;
            ex_shared_re <= id_shared_re; ex_shared_we <= id_shared_we;
        end
    end

    // -------------------------------------------------------------------------
    // 3. EXECUTE (EX) STAGE & FORWARDING
    // -------------------------------------------------------------------------
    wire [DATA_BITS-1:0] ex_alu_out [THREADS_PER_BLOCK-1:0];
    wire [PROGRAM_MEM_ADDR_BITS-1:0] ex_next_pc [THREADS_PER_BLOCK-1:0];

    reg [THREADS_PER_BLOCK-1:0] mem_active_mask;
    reg [$clog2(NUM_WARPS)-1:0] mem_warp_id;
    reg [7:0] mem_pc; // NEW: Passed to Scheduler to rewind PC on Yield
    reg [3:0] mem_rd;
    reg [DATA_BITS-1:0] mem_imm;
    reg [DATA_BITS-1:0] mem_alu_out [THREADS_PER_BLOCK-1:0];
    reg [DATA_BITS-1:0] mem_rs_data [THREADS_PER_BLOCK-1:0];
    reg [DATA_BITS-1:0] mem_rt_data [THREADS_PER_BLOCK-1:0]; 
    reg mem_reg_we, mem_mem_re, mem_mem_we, mem_shared_re, mem_shared_we, mem_ret;
    reg [1:0] mem_reg_mux;

    reg [THREADS_PER_BLOCK-1:0] wb_active_mask;
    reg [$clog2(NUM_WARPS)-1:0] wb_warp_id;
    reg [3:0] wb_rd;
    reg [DATA_BITS-1:0] wb_imm;
    reg [DATA_BITS-1:0] wb_alu_out [THREADS_PER_BLOCK-1:0];
    reg wb_reg_we;
    reg [1:0] wb_reg_mux;

    wire [DATA_BITS-1:0] fwd_ex_rs_data [THREADS_PER_BLOCK-1:0];
    wire [DATA_BITS-1:0] fwd_ex_rt_data [THREADS_PER_BLOCK-1:0];

    // ==================== EX/MEM PIPELINE REGISTER ====================
    always @(posedge clk) begin
        if (reset) begin
            mem_active_mask <= 0;
            mem_warp_id <= 0;
            mem_reg_we <= 0; mem_mem_re <= 0; mem_mem_we <= 0;
            mem_shared_re <= 0; mem_shared_we <= 0; mem_ret <= 0;
        end else begin 
            mem_active_mask <= ex_active_mask;
            mem_warp_id <= ex_warp_id;
            mem_pc <= ex_pc;
            mem_rd <= ex_rd;
            mem_imm <= ex_imm;
            for (int j = 0; j < THREADS_PER_BLOCK; j++) begin
                mem_alu_out[j] <= ex_alu_out[j];
                mem_rs_data[j] <= fwd_ex_rs_data[j]; 
                mem_rt_data[j] <= fwd_ex_rt_data[j]; 
            end
            mem_reg_we <= ex_reg_we; mem_mem_re <= ex_mem_re; mem_mem_we <= ex_mem_we;
            mem_shared_re <= ex_shared_re; mem_shared_we <= ex_shared_we;
            mem_reg_mux <= ex_reg_mux; mem_ret <= ex_ret;
        end
    end

    // -------------------------------------------------------------------------
    // 4. MEMORY (MEM) STAGE
    // -------------------------------------------------------------------------
    wire [THREADS_PER_BLOCK-1:0] sh_read_valid, sh_read_ready, sh_write_valid, sh_write_ready;
    wire [SHARED_MEM_ADDR_BITS-1:0] sh_read_address [THREADS_PER_BLOCK];
    wire [SHARED_MEM_ADDR_BITS-1:0] sh_write_address [THREADS_PER_BLOCK];
    wire [DATA_MEM_DATA_BITS-1:0] sh_read_data [THREADS_PER_BLOCK];
    wire [DATA_MEM_DATA_BITS-1:0] sh_write_data [THREADS_PER_BLOCK];

    shared_mem #( .DATA_BITS(DATA_MEM_DATA_BITS), .ADDR_BITS(SHARED_MEM_ADDR_BITS), .SIZE(SHARED_MEM_SIZE), .THREADS_PER_BLOCK(THREADS_PER_BLOCK)
    ) shared_mem_instance (
        .clk(clk), .reset(reset),
        .read_valid(sh_read_valid), .read_address(sh_read_address), .read_ready(sh_read_ready), .read_data(sh_read_data),
        .write_valid(sh_write_valid), .write_address(sh_write_address), .write_data(sh_write_data), .write_ready(sh_write_ready)
    );

    // ==================== MEM/WB PIPELINE REGISTER ====================
    always @(posedge clk) begin
        if (reset) begin
            wb_active_mask <= 0;
            wb_warp_id <= 0;
            wb_reg_we <= 0;
        end else begin 
            if (mem_mem_re || mem_mem_we || mem_shared_re || mem_shared_we) begin
                wb_active_mask <= 0;
                wb_reg_we <= 0;
            end else begin
                wb_active_mask <= mem_active_mask;
                wb_warp_id <= mem_warp_id;
                wb_rd <= mem_rd;
                wb_imm <= mem_imm;
                for (int j = 0; j < THREADS_PER_BLOCK; j++) wb_alu_out[j] <= mem_alu_out[j];
                wb_reg_we <= mem_reg_we;
                wb_reg_mux <= mem_reg_mux;
            end
        end
    end

    // -------------------------------------------------------------------------
    // LSU Tracking & Warp Wakeup Logic
    // -------------------------------------------------------------------------
    wire is_mem_op = mem_mem_re | mem_mem_we | mem_shared_re | mem_shared_we;
    wire mem_req_valid = (|mem_active_mask) && is_mem_op;

    wire [THREADS_PER_BLOCK-1:0] lsu_done_pulse;
    wire [$clog2(NUM_WARPS)-1:0] lsu_done_warp [THREADS_PER_BLOCK-1:0];

    reg [3:0] mem_pending_count [NUM_WARPS-1:0];
    reg [NUM_WARPS-1:0] warp_mem_ready;

    integer w, t;
    reg [3:0] done_sum;
    always @(posedge clk) begin
        if (reset) begin
            for (w = 0; w < NUM_WARPS; w++) mem_pending_count[w] <= 0;
            warp_mem_ready <= 0;
        end else begin
            for (w = 0; w < NUM_WARPS; w++) begin
                done_sum = 0;
                for (t = 0; t < THREADS_PER_BLOCK; t++) begin
                    if (lsu_done_pulse[t] && lsu_done_warp[t] == w) done_sum = done_sum + 1;
                end

                if (mem_req_valid && mem_warp_id == w) begin
                    reg [3:0] active_count;
                    active_count = 0;
                    for (int b=0; b<THREADS_PER_BLOCK; b++) if (mem_active_mask[b]) active_count++;
                    
                    mem_pending_count[w] <= active_count - done_sum;
                    warp_mem_ready[w] <= 0;
                end else begin
                    mem_pending_count[w] <= mem_pending_count[w] - done_sum;
                    if (mem_pending_count[w] > 0 && (mem_pending_count[w] - done_sum) == 0) begin
                        warp_mem_ready[w] <= 1;
                    end else begin
                        warp_mem_ready[w] <= 0;
                    end
                end
            end
        end
    end

    // -------------------------------------------------------------------------
    // 5. WRITE-BACK (WB) STAGE & THREAD INSTANTIATION
    // -------------------------------------------------------------------------
    genvar i;
    generate
        for (i = 0; i < THREADS_PER_BLOCK; i = i + 1) begin : threads
            
            wire fwd_mem_rs_i = mem_active_mask[i] && mem_reg_we && (mem_rd == ex_rs) && (mem_rd < 13) && ex_rs_re && (mem_warp_id == ex_warp_id);
            wire fwd_mem_rt_i = mem_active_mask[i] && mem_reg_we && (mem_rd == ex_rt) && (mem_rd < 13) && ex_rt_re && (mem_warp_id == ex_warp_id);
            wire fwd_wb_rs_i  = wb_active_mask[i]  && wb_reg_we  && (wb_rd == ex_rs)  && (wb_rd < 13)  && ex_rs_re && !fwd_mem_rs_i && (wb_warp_id == ex_warp_id);
            wire fwd_wb_rt_i  = wb_active_mask[i]  && wb_reg_we  && (wb_rd == ex_rt)  && (wb_rd < 13)  && ex_rt_re && !fwd_mem_rt_i && (wb_warp_id == ex_warp_id);

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
                .alu_out(ex_alu_out[i]), .current_pc(ex_pc), .next_pc(ex_next_pc[i])
            );

            wire lsu_we;
            wire [$clog2(NUM_WARPS)-1:0] lsu_warp_id;
            wire [3:0] lsu_rd;
            wire [DATA_BITS-1:0] lsu_data;

            lsu #( .DATA_BITS(DATA_BITS), .NUM_WARPS(NUM_WARPS) ) lsu_inst (
                .clk(clk), .reset(reset), .enable(mem_active_mask[i]), .warp_id(mem_warp_id),
                .decoded_mem_read_enable(mem_mem_re), .decoded_mem_write_enable(mem_mem_we),
                .decoded_shared_read_enable(mem_shared_re), .decoded_shared_write_enable(mem_shared_we),
                .decoded_rd(mem_rd), .rs(mem_rs_data[i]), .rt(mem_rt_data[i]), 
                
                .mem_read_valid(data_mem_read_valid[i]), .mem_read_address(data_mem_read_address[i]),
                .mem_read_ready(data_mem_read_ready[i]), .mem_read_data(data_mem_read_data[i]),
                .mem_write_valid(data_mem_write_valid[i]), .mem_write_address(data_mem_write_address[i]),
                .mem_write_data(data_mem_write_data[i]), .mem_write_ready(data_mem_write_ready[i]),
                
                .shared_mem_read_valid(sh_read_valid[i]), .shared_mem_read_address(sh_read_address[i]),
                .shared_mem_read_ready(sh_read_ready[i]), .shared_mem_read_data(sh_read_data[i]),
                .shared_mem_write_valid(sh_write_valid[i]), .shared_mem_write_address(sh_write_address[i]),
                .shared_mem_write_data(sh_write_data[i]), .shared_mem_write_ready(sh_write_ready[i]),
                
                .lsu_we(lsu_we), .lsu_warp_id(lsu_warp_id), .lsu_rd(lsu_rd), .lsu_data(lsu_data),
                .done_pulse(lsu_done_pulse[i]), .done_warp_id(lsu_done_warp[i])
            );
            
            wire [7:0] physical_thread_id = i; 
            
            registers #( .THREADS_PER_BLOCK(THREADS_PER_BLOCK), .NUM_WARPS(NUM_WARPS), .DATA_BITS(DATA_BITS) ) reg_inst (
                .clk(clk), .reset(reset), .enable(wb_active_mask[i]), .warp_id(wb_warp_id), .block_id(block_id),
                .thread_id(physical_thread_id),
                
                .decoded_rs_address(id_rs), .decoded_rt_address(id_rt), .rs(id_rs_data[i]), .rt(id_rt_data[i]),
                .decoded_rd_address(wb_rd), .decoded_reg_write_enable(wb_reg_we), .decoded_reg_input_mux(wb_reg_mux),
                .decoded_immediate(wb_imm), .alu_out(wb_alu_out[i]), .lsu_out(16'h0), 
                
                .lsu_we(lsu_we), .lsu_warp_id(lsu_warp_id), .lsu_rd(lsu_rd), .lsu_data(lsu_data) 
            );
            
        end
    endgenerate

    // -------------------------------------------------------------------------
    // 6. SCHEDULER / PIPELINE CONTROLLER
    // -------------------------------------------------------------------------
    scheduler #(
        .THREADS_PER_BLOCK(THREADS_PER_BLOCK), .NUM_WARPS(NUM_WARPS)
    ) scheduler_instance (
        .clk(clk), .reset(reset), .start(start), .thread_count(thread_count),
        
        .mem_req_valid(mem_req_valid), .mem_warp_id(mem_warp_id), .mem_pc(mem_pc), .warp_mem_ready(warp_mem_ready),
        .frontend_stall(frontend_stall), 
        
        .flush_warp_mask(flush_warp_mask),
        .if_pc(if_pc), .sched_active_mask(sched_active_mask), .sched_warp_id(sched_warp_id), .valid_issue(valid_issue),
        
        .ex_valid(|ex_active_mask), .ex_warp_id(ex_warp_id), .ex_active_mask(ex_active_mask),
        .ex_pc(ex_pc), .ex_next_pc(ex_next_pc), .ex_ret(ex_ret),
        
        .done(done)
    );

endmodule