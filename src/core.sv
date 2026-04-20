`default_nettype none
`timescale 1ns/1ns

module core #(
    parameter DATA_MEM_ADDR_BITS = 8,
    parameter DATA_MEM_DATA_BITS = 16,
    parameter PROGRAM_MEM_ADDR_BITS = 8,
    parameter PROGRAM_MEM_DATA_BITS = 16,
    parameter THREADS_PER_BLOCK = 4,
    parameter SHARED_MEM_ADDR_BITS      = 8, 
    parameter SHARED_MEM_SIZE           = 256,
    parameter DATA_BITS = 16,
    parameter DEBUG = 1 // Enable verbose logging
) (
    input wire clk,
    input wire reset,
    input wire start,
    output wire done,
    input wire [7:0] block_id,
    input wire [$clog2(THREADS_PER_BLOCK):0] thread_count,

    output wire program_mem_read_valid,
    output wire [PROGRAM_MEM_ADDR_BITS-1:0] program_mem_read_address,
    input wire program_mem_read_ready,
    input wire [PROGRAM_MEM_DATA_BITS-1:0] program_mem_read_data,

    output wire [THREADS_PER_BLOCK-1:0] data_mem_read_valid,
    output wire [DATA_MEM_ADDR_BITS-1:0] data_mem_read_address [THREADS_PER_BLOCK],
    input wire [THREADS_PER_BLOCK-1:0] data_mem_read_ready,
    input wire [DATA_MEM_DATA_BITS-1:0] data_mem_read_data [THREADS_PER_BLOCK],
    output wire [THREADS_PER_BLOCK-1:0] data_mem_write_valid,
    output wire [DATA_MEM_ADDR_BITS-1:0] data_mem_write_address [THREADS_PER_BLOCK],
    output wire [DATA_MEM_DATA_BITS-1:0] data_mem_write_data [THREADS_PER_BLOCK],
    input wire [THREADS_PER_BLOCK-1:0] data_mem_write_ready
);

    // -------------------------------------------------------------------------
    // 0. PIPELINE CONTROL SIGNALS
    // -------------------------------------------------------------------------
    wire [THREADS_PER_BLOCK-1:0] lsu_stall;
    wire if_instruction_valid; 
    wire load_use_stall; 
    
    wire lsu_any_stall = |lsu_stall; 
    wire fetch_stall = !if_instruction_valid;
    
    wire scheduler_stall = lsu_any_stall || fetch_stall || load_use_stall;

    wire core_running = start && !done;
    wire fetcher_stall = lsu_any_stall || !core_running; 

    wire pipeline_flush;
    wire [THREADS_PER_BLOCK-1:0] sched_active_mask;
    wire [7:0] if_pc; 

    always @(posedge clk) begin
        if (DEBUG && !reset && start && !done) begin
            if (lsu_any_stall) $display("[%0t] [STALL] Backend (LSU) Memory Stall triggered", $time);
            if (load_use_stall) $display("[%0t] [STALL] Load-Use Hazard! Injecting Bubble into ID/EX.", $time);
            if (fetch_stall) $display("[%0t] [STALL] Fetch Stall! Waiting for instruction from memory.", $time);
        end
    end

    // -------------------------------------------------------------------------
    // 1. INSTRUCTION FETCH (IF) STAGE
    // -------------------------------------------------------------------------
    wire [15:0] if_instruction;

    fetcher #(
        .PROGRAM_MEM_ADDR_BITS(PROGRAM_MEM_ADDR_BITS),
        .PROGRAM_MEM_DATA_BITS(PROGRAM_MEM_DATA_BITS)
    ) fetcher_instance (
        .clk(clk),
        .reset(reset),
        .stall(fetcher_stall), 
        .flush(pipeline_flush),
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

    always @(posedge clk) begin
        if (reset || pipeline_flush) begin
            if (DEBUG && pipeline_flush && core_running) $display("[%0t] [FLUSH] IF/ID Pipeline Register Flushed", $time);
            id_instruction <= 16'h0000;
            id_pc <= 0;
            id_active_mask <= 0;
        end else if (!lsu_any_stall && !load_use_stall) begin 
            id_instruction <= if_instruction_valid ? if_instruction : 16'h0000;
            id_pc <= if_pc;
            id_active_mask <= if_instruction_valid ? sched_active_mask : 0; 
            if (DEBUG && if_instruction_valid && sched_active_mask != 0) begin
                $display("[%0t] [IF->ID] Latching PC=%0d, Instr=%04h, Mask=%b", $time, if_pc, if_instruction, sched_active_mask);
            end
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

    wire [DATA_BITS-1:0] id_rs_data [THREADS_PER_BLOCK-1:0];
    wire [DATA_BITS-1:0] id_rt_data [THREADS_PER_BLOCK-1:0];

    // ==================== ID/EX PIPELINE REGISTER ====================
    reg [THREADS_PER_BLOCK-1:0] ex_active_mask;
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

    assign load_use_stall = (ex_mem_re || ex_shared_re) && ex_reg_we && 
                            ((id_rs_re && (id_rs == ex_rd)) || (id_rt_re && (id_rt == ex_rd)));

    always @(posedge clk) begin
        if (reset || pipeline_flush) begin
            if (DEBUG && pipeline_flush && core_running) $display("[%0t] [FLUSH] ID/EX Pipeline Register Flushed", $time);
            ex_active_mask <= 0;
            ex_reg_we <= 0; ex_mem_re <= 0; ex_mem_we <= 0;
            ex_shared_re <= 0; ex_shared_we <= 0;
            ex_nzp_we <= 0; ex_ret <= 0; ex_sync <= 0; ex_pc_mux <= 0;
            ex_rs_re <= 0; ex_rt_re <= 0;
        end else if (!lsu_any_stall) begin
            if (load_use_stall) begin
                ex_active_mask <= 0;
                ex_reg_we <= 0; ex_mem_re <= 0; ex_mem_we <= 0;
                ex_shared_re <= 0; ex_shared_we <= 0;
                ex_nzp_we <= 0; ex_ret <= 0; ex_sync <= 0; ex_pc_mux <= 0;
                ex_rs_re <= 0; ex_rt_re <= 0;
            end else begin
                ex_active_mask <= id_active_mask;
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
                
                if (DEBUG && id_active_mask != 0) begin
                    $display("[%0t] [ID->EX] PC=%0d, Mask=%b | Decode: Rd=R%0d, Rs=R%0d, Rt=R%0d, Imm=%0d, RegWE=%b, MemWE=%b", 
                             $time, id_pc, id_active_mask, id_rd, id_rs, id_rt, id_imm, id_reg_we, id_mem_we);
                end
            end
        end
    end

    // -------------------------------------------------------------------------
    // 3. EXECUTE (EX) STAGE & FORWARDING
    // -------------------------------------------------------------------------
    wire [DATA_BITS-1:0] ex_alu_out [THREADS_PER_BLOCK-1:0];
    wire [PROGRAM_MEM_ADDR_BITS-1:0] ex_next_pc [THREADS_PER_BLOCK-1:0];

    reg [THREADS_PER_BLOCK-1:0] mem_active_mask;
    reg [3:0] mem_rd;
    reg [DATA_BITS-1:0] mem_imm;
    reg [DATA_BITS-1:0] mem_alu_out [THREADS_PER_BLOCK-1:0];
    reg [DATA_BITS-1:0] mem_rs_data [THREADS_PER_BLOCK-1:0];
    reg [DATA_BITS-1:0] mem_rt_data [THREADS_PER_BLOCK-1:0]; 
    reg mem_reg_we, mem_mem_re, mem_mem_we, mem_shared_re, mem_shared_we, mem_ret;
    reg [1:0] mem_reg_mux;

    reg [THREADS_PER_BLOCK-1:0] wb_active_mask;
    reg [3:0] wb_rd;
    reg [DATA_BITS-1:0] wb_imm;
    reg [DATA_BITS-1:0] wb_alu_out [THREADS_PER_BLOCK-1:0];
    reg [DATA_BITS-1:0] wb_lsu_out [THREADS_PER_BLOCK-1:0];
    reg wb_reg_we;
    reg [1:0] wb_reg_mux;

    wire [DATA_BITS-1:0] fwd_ex_rs_data [THREADS_PER_BLOCK-1:0];
    wire [DATA_BITS-1:0] fwd_ex_rt_data [THREADS_PER_BLOCK-1:0];

    // ==================== EX/MEM PIPELINE REGISTER ====================
    always @(posedge clk) begin
        if (reset || pipeline_flush) begin
            if (DEBUG && pipeline_flush && core_running) $display("[%0t] [FLUSH] EX/MEM Pipeline Register Flushed", $time);
            mem_active_mask <= 0;
            mem_reg_we <= 0; mem_mem_re <= 0; mem_mem_we <= 0;
            mem_shared_re <= 0; mem_shared_we <= 0; mem_ret <= 0;
        end else if (!lsu_any_stall) begin 
            mem_active_mask <= ex_active_mask;
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

            if (DEBUG && ex_active_mask != 0) begin
                $display("[%0t] [EX->MEM] PC=%0d, Mask=%b Latching to MEM", $time, ex_pc, ex_active_mask);
            end
        end
    end

    // -------------------------------------------------------------------------
    // 4. MEMORY (MEM) STAGE
    // -------------------------------------------------------------------------
    wire [DATA_BITS-1:0] mem_lsu_out [THREADS_PER_BLOCK-1:0];
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
        if (reset || pipeline_flush) begin
            if (DEBUG && pipeline_flush && core_running) $display("[%0t] [FLUSH] MEM/WB Pipeline Register Flushed", $time);
            wb_active_mask <= 0;
            wb_reg_we <= 0;
        end else if (!lsu_any_stall) begin 
            wb_active_mask <= mem_active_mask;
            wb_rd <= mem_rd;
            wb_imm <= mem_imm;
            for (int j = 0; j < THREADS_PER_BLOCK; j++) begin
                wb_alu_out[j] <= mem_alu_out[j];
                wb_lsu_out[j] <= mem_lsu_out[j];
            end
            wb_reg_we <= mem_reg_we;
            wb_reg_mux <= mem_reg_mux;
            
            if (DEBUG && mem_active_mask != 0) begin
                $display("[%0t] [MEM->WB] Mask=%b Latching to WB", $time, mem_active_mask);
            end
        end
    end

    // -------------------------------------------------------------------------
    // 5. WRITE-BACK (WB) STAGE & THREAD INSTANTIATION
    // -------------------------------------------------------------------------
    genvar i;
    generate
        for (i = 0; i < THREADS_PER_BLOCK; i = i + 1) begin : threads
            
            wire fwd_mem_rs_i = mem_active_mask[i] && mem_reg_we && (mem_rd == ex_rs) && (mem_rd < 13) && ex_rs_re;
            wire fwd_mem_rt_i = mem_active_mask[i] && mem_reg_we && (mem_rd == ex_rt) && (mem_rd < 13) && ex_rt_re;
            wire fwd_wb_rs_i  = wb_active_mask[i]  && wb_reg_we  && (wb_rd == ex_rs)  && (wb_rd < 13)  && ex_rs_re && !fwd_mem_rs_i;
            wire fwd_wb_rt_i  = wb_active_mask[i]  && wb_reg_we  && (wb_rd == ex_rt)  && (wb_rd < 13)  && ex_rt_re && !fwd_mem_rt_i;

            wire [DATA_BITS-1:0] fwd_mem_data_i = (mem_reg_mux == 2'b10) ? mem_imm : mem_alu_out[i];
            wire [DATA_BITS-1:0] fwd_wb_data_i  = (wb_reg_mux == 2'b10) ? wb_imm :
                                                  (wb_reg_mux == 2'b01 || wb_reg_mux == 2'b11) ? wb_lsu_out[i] :
                                                  wb_alu_out[i];

            assign fwd_ex_rs_data[i] = fwd_mem_rs_i ? fwd_mem_data_i :
                                       fwd_wb_rs_i  ? fwd_wb_data_i  :
                                       ex_rs_data[i];

            assign fwd_ex_rt_data[i] = fwd_mem_rt_i ? fwd_mem_data_i :
                                       fwd_wb_rt_i  ? fwd_wb_data_i  :
                                       ex_rt_data[i];

            always @(posedge clk) begin
                if (DEBUG && !reset && ex_active_mask[i]) begin
                    $display("[%0t] [EX/EVAL] Thread %0d | Inputs: RS=%0d, RT=%0d | ALU Out=%0d | NextPC=%0d", 
                             $time, i, fwd_ex_rs_data[i], fwd_ex_rt_data[i], ex_alu_out[i], ex_next_pc[i]);
                             
                    if (fwd_mem_rs_i) $display("[%0t]   [FWD] T%0d RS bypassed from MEM: %0d", $time, i, fwd_mem_data_i);
                    if (fwd_mem_rt_i) $display("[%0t]   [FWD] T%0d RT bypassed from MEM: %0d", $time, i, fwd_mem_data_i);
                    if (fwd_wb_rs_i)  $display("[%0t]   [FWD] T%0d RS bypassed from WB: %0d", $time, i, fwd_wb_data_i);
                    if (fwd_wb_rt_i)  $display("[%0t]   [FWD] T%0d RT bypassed from WB: %0d", $time, i, fwd_wb_data_i);
                end

                if (DEBUG && !reset && mem_active_mask[i]) begin
                    if (mem_mem_we) $display("[%0t] [MEM/WRITE] Thread %0d | Addr=%0d, Data=%0d", $time, i, mem_rs_data[i], mem_rt_data[i]);
                    if (mem_mem_re) $display("[%0t] [MEM/READ]  Thread %0d | Addr=%0d | LSU Out=%0d", $time, i, mem_rs_data[i], mem_lsu_out[i]);
                end
                
                if (DEBUG && !reset && wb_active_mask[i] && wb_reg_we && (wb_rd < 13)) begin
                    $display("[%0t] [WB/WRITE]  Thread %0d | R%0d <= %0d (Mux: %b)", $time, i, wb_rd,
                             (wb_reg_mux == 2'b00) ? wb_alu_out[i] :
                             (wb_reg_mux == 2'b01 || wb_reg_mux == 2'b11) ? wb_lsu_out[i] :
                             wb_imm, wb_reg_mux);
                end
            end

            alu #( .DATA_BITS(DATA_BITS) ) alu_inst (
                .enable(ex_active_mask[i]),
                .decoded_alu_arithmetic_mux(ex_alu_arith_mux), .decoded_alu_output_mux(ex_alu_out_mux),
                .rs(fwd_ex_rs_data[i]), .rt(fwd_ex_rt_data[i]), .alu_out(ex_alu_out[i])
            );

            pc #( .DATA_MEM_DATA_BITS(DATA_BITS), .PROGRAM_MEM_ADDR_BITS(PROGRAM_MEM_ADDR_BITS) ) pc_inst (
                .clk(clk), .reset(reset), .enable(ex_active_mask[i]),
                .decoded_nzp(ex_nzp), .decoded_immediate(ex_imm),
                .decoded_nzp_write_enable(ex_nzp_we), .decoded_pc_mux(ex_pc_mux),
                .alu_out(ex_alu_out[i]), .current_pc(ex_pc), .next_pc(ex_next_pc[i])
            );

            lsu #( .DATA_BITS(DATA_BITS) ) lsu_inst (
                .clk(clk), .reset(reset), .enable(mem_active_mask[i]),
                .decoded_mem_read_enable(mem_mem_re), .decoded_mem_write_enable(mem_mem_we),
                .decoded_shared_read_enable(mem_shared_re), .decoded_shared_write_enable(mem_shared_we),
                .rs(mem_rs_data[i]), .rt(mem_rt_data[i]), 
                
                .mem_read_valid(data_mem_read_valid[i]), .mem_read_address(data_mem_read_address[i]),
                .mem_read_ready(data_mem_read_ready[i]), .mem_read_data(data_mem_read_data[i]),
                .mem_write_valid(data_mem_write_valid[i]), .mem_write_address(data_mem_write_address[i]),
                .mem_write_data(data_mem_write_data[i]), .mem_write_ready(data_mem_write_ready[i]),
                
                .shared_mem_read_valid(sh_read_valid[i]), .shared_mem_read_address(sh_read_address[i]),
                .shared_mem_read_ready(sh_read_ready[i]), .shared_mem_read_data(sh_read_data[i]),
                .shared_mem_write_valid(sh_write_valid[i]), .shared_mem_write_address(sh_write_address[i]),
                .shared_mem_write_data(sh_write_data[i]), .shared_mem_write_ready(sh_write_ready[i]),
                
                .stall(lsu_stall[i]), .lsu_out(mem_lsu_out[i])
            );
            
            wire [7:0] physical_thread_id = i; 
            
            registers #( .THREADS_PER_BLOCK(THREADS_PER_BLOCK), .DATA_BITS(DATA_BITS) ) reg_inst (
                .clk(clk), .reset(reset), .enable(wb_active_mask[i]), .block_id(block_id),
                .thread_id(physical_thread_id),
                .decoded_rs_address(id_rs), .decoded_rt_address(id_rt), .rs(id_rs_data[i]), .rt(id_rt_data[i]),
                .decoded_rd_address(wb_rd), .decoded_reg_write_enable(wb_reg_we), .decoded_reg_input_mux(wb_reg_mux),
                .decoded_immediate(wb_imm), .alu_out(wb_alu_out[i]), .lsu_out(wb_lsu_out[i])
            );
        end
    endgenerate

    // -------------------------------------------------------------------------
    // 6. SCHEDULER / PIPELINE CONTROLLER
    // -------------------------------------------------------------------------
    scheduler #(
        .THREADS_PER_BLOCK(THREADS_PER_BLOCK)
    ) scheduler_instance (
        .clk(clk), .reset(reset), .start(start), .thread_count(thread_count),
        
        .frontend_stall(scheduler_stall), 
        .backend_stall(lsu_any_stall),
        .pipeline_flush(pipeline_flush),
        
        .if_pc(if_pc), .sched_active_mask(sched_active_mask),
        
        .ex_active_mask(ex_active_mask), .ex_pc(ex_pc), .ex_next_pc(ex_next_pc),
        .ex_ret(ex_ret), .ex_sync(ex_sync), .done(done)
    );

endmodule