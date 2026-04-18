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
    parameter DATA_BITS = 16
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
    output wire [DATA_MEM_ADDR_BITS-1:0] data_mem_read_address [THREADS_PER_BLOCK-1:0],
    input wire [THREADS_PER_BLOCK-1:0] data_mem_read_ready,
    input wire [DATA_MEM_DATA_BITS-1:0] data_mem_read_data [THREADS_PER_BLOCK-1:0],
    output wire [THREADS_PER_BLOCK-1:0] data_mem_write_valid,
    output wire [DATA_MEM_ADDR_BITS-1:0] data_mem_write_address [THREADS_PER_BLOCK-1:0],
    output wire [DATA_MEM_DATA_BITS-1:0] data_mem_write_data [THREADS_PER_BLOCK-1:0],
    input wire [THREADS_PER_BLOCK-1:0] data_mem_write_ready
);

    // -------------------------------------------------------------------------
    // 0. PIPELINE CONTROL SIGNALS (Ordered explicitly for combinational eval)
    // -------------------------------------------------------------------------
    wire [THREADS_PER_BLOCK-1:0] lsu_stall;
    wire if_instruction_valid; // Declared early so it can be evaluated
    
    // LSU Stall: Memory is busy. Freezes EVERYTHING (Backend + Fetcher)
    wire lsu_any_stall = |lsu_stall; 
    
    // Fetch Stall: Fetcher is waiting for instruction memory. PC must freeze.
    wire fetch_stall = !if_instruction_valid;
    
    // Scheduler Stall: PC freezes if either memory is stalling, or fetch is waiting
    wire scheduler_stall = lsu_any_stall || fetch_stall;

    // Fetcher Enable: Shut off the fetcher completely to release the bus when finished!
    wire core_running = start && !done;
    wire fetcher_stall = lsu_any_stall || !core_running; // <--- FIXED TYPO HERE

    wire pipeline_flush;
    wire [THREADS_PER_BLOCK-1:0] sched_active_mask;
    wire [7:0] if_pc; 

    always @(posedge clk) begin
        if (!reset && start && !done) begin
            if (lsu_any_stall) $display("[%0t] [STALL] Backend (LSU) Memory Stall triggered", $time);
            else if (fetch_stall) $display("[%0t] [STALL] Fetcher waiting on Program Memory...", $time);
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
        .stall(fetcher_stall), // Fetcher only pauses if the backend is congested or core is done
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
            id_instruction <= 16'h0000;
            id_pc <= 0;
            id_active_mask <= 0;
            if (pipeline_flush && !reset) $display("[%0t] [IF/ID] Flush!", $time);
        end else if (!lsu_any_stall) begin
            id_instruction <= if_instruction_valid ? if_instruction : 16'h0000;
            id_pc <= if_pc;
            id_active_mask <= if_instruction_valid ? sched_active_mask : 0; 
            
            if (if_instruction_valid) begin
                $display("[%0t] [IF]  Fetched PC=%0d, Instr=%04h", $time, if_pc, if_instruction);
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
    wire [1:0] id_reg_mux;
    wire [2:0] id_alu_arith_mux;
    wire id_alu_out_mux, id_pc_mux, id_ret, id_sync;
    wire id_shared_re, id_shared_we;

    decoder #( .DATA_BITS(DATA_BITS) ) decoder_inst (
        .instruction(id_instruction),
        .decoded_rd_address(id_rd), .decoded_rs_address(id_rs), .decoded_rt_address(id_rt),
        .decoded_nzp(id_nzp), .decoded_immediate(id_imm),
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
    reg [3:0] ex_rd;
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
        if (reset || pipeline_flush) begin
            ex_active_mask <= 0;
            ex_reg_we <= 0; ex_mem_re <= 0; ex_mem_we <= 0;
            ex_shared_re <= 0; ex_shared_we <= 0;
            ex_nzp_we <= 0; ex_ret <= 0; ex_sync <= 0; ex_pc_mux <= 0;
        end else if (!lsu_any_stall) begin
            ex_active_mask <= id_active_mask;
            ex_pc <= id_pc;
            ex_rd <= id_rd;
            ex_nzp <= id_nzp;
            ex_imm <= id_imm;
            for (int i = 0; i < THREADS_PER_BLOCK; i++) begin
                ex_rs_data[i] <= id_rs_data[i];
                ex_rt_data[i] <= id_rt_data[i];
            end
            ex_reg_we <= id_reg_we; ex_mem_re <= id_mem_re; ex_mem_we <= id_mem_we;
            ex_nzp_we <= id_nzp_we; ex_reg_mux <= id_reg_mux; 
            ex_alu_arith_mux <= id_alu_arith_mux; ex_alu_out_mux <= id_alu_out_mux;
            ex_pc_mux <= id_pc_mux; ex_ret <= id_ret; ex_sync <= id_sync;
            ex_shared_re <= id_shared_re; ex_shared_we <= id_shared_we;
            
            if (|id_active_mask) $display("[%0t] [ID]  Decoded PC=%0d", $time, id_pc);
        end
    end

    // -------------------------------------------------------------------------
    // 3. EXECUTE (EX) STAGE
    // -------------------------------------------------------------------------
    wire [DATA_BITS-1:0] ex_alu_out [THREADS_PER_BLOCK-1:0];
    wire [PROGRAM_MEM_ADDR_BITS-1:0] ex_next_pc [THREADS_PER_BLOCK-1:0];

    // ==================== EX/MEM PIPELINE REGISTER ====================
    reg [THREADS_PER_BLOCK-1:0] mem_active_mask;
    reg [3:0] mem_rd;
    reg [DATA_BITS-1:0] mem_imm;
    reg [DATA_BITS-1:0] mem_alu_out [THREADS_PER_BLOCK-1:0];
    reg [DATA_BITS-1:0] mem_rs_data [THREADS_PER_BLOCK-1:0];
    reg [DATA_BITS-1:0] mem_rt_data [THREADS_PER_BLOCK-1:0]; 
    
    reg mem_reg_we, mem_mem_re, mem_mem_we;
    reg mem_shared_re, mem_shared_we;
    reg [1:0] mem_reg_mux;
    reg mem_ret;

    always @(posedge clk) begin
        if (reset) begin
            mem_active_mask <= 0;
            mem_reg_we <= 0; mem_mem_re <= 0; mem_mem_we <= 0;
            mem_shared_re <= 0; mem_shared_we <= 0; mem_ret <= 0;
        end else if (!lsu_any_stall) begin 
            mem_active_mask <= ex_active_mask;
            mem_rd <= ex_rd;
            mem_imm <= ex_imm;
            for (int i = 0; i < THREADS_PER_BLOCK; i++) begin
                mem_alu_out[i] <= ex_alu_out[i];
                mem_rs_data[i] <= ex_rs_data[i];
                mem_rt_data[i] <= ex_rt_data[i];
            end
            mem_reg_we <= ex_reg_we; mem_mem_re <= ex_mem_re; mem_mem_we <= ex_mem_we;
            mem_shared_re <= ex_shared_re; mem_shared_we <= ex_shared_we;
            mem_reg_mux <= ex_reg_mux; mem_ret <= ex_ret;
            
            if (|ex_active_mask) $display("[%0t] [EX]  Executing PC=%0d, Mask=%b", $time, ex_pc, ex_active_mask);
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
    reg [THREADS_PER_BLOCK-1:0] wb_active_mask;
    reg [3:0] wb_rd;
    reg [DATA_BITS-1:0] wb_imm;
    reg [DATA_BITS-1:0] wb_alu_out [THREADS_PER_BLOCK-1:0];
    reg [DATA_BITS-1:0] wb_lsu_out [THREADS_PER_BLOCK-1:0];
    reg wb_reg_we;
    reg [1:0] wb_reg_mux;

    always @(posedge clk) begin
        if (reset) begin
            wb_active_mask <= 0;
            wb_reg_we <= 0;
        end else if (!lsu_any_stall) begin 
            wb_active_mask <= mem_active_mask;
            wb_rd <= mem_rd;
            wb_imm <= mem_imm;
            for (int i = 0; i < THREADS_PER_BLOCK; i++) begin
                wb_alu_out[i] <= mem_alu_out[i];
                wb_lsu_out[i] <= mem_lsu_out[i];
            end
            wb_reg_we <= mem_reg_we;
            wb_reg_mux <= mem_reg_mux;
            
            if (|mem_active_mask) $display("[%0t] [MEM] Bypassing/Completing Memory Stage", $time);
        end
    end

    // -------------------------------------------------------------------------
    // 5. WRITE-BACK (WB) STAGE & THREAD INSTANTIATION
    // -------------------------------------------------------------------------
    genvar i;
    generate
        for (i = 0; i < THREADS_PER_BLOCK; i = i + 1) begin : threads
            
            alu #( .DATA_BITS(DATA_BITS) ) alu_inst (
                .enable(ex_active_mask[i]),
                .decoded_alu_arithmetic_mux(ex_alu_arith_mux), .decoded_alu_output_mux(ex_alu_out_mux),
                .rs(ex_rs_data[i]), .rt(ex_rt_data[i]), .alu_out(ex_alu_out[i])
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
            
            registers #( .THREADS_PER_BLOCK(THREADS_PER_BLOCK), .THREAD_ID(i), .DATA_BITS(DATA_BITS) ) reg_inst (
                .clk(clk), .reset(reset), .enable(wb_active_mask[i]), .block_id(block_id),
                .decoded_rs_address(id_rs), .decoded_rt_address(id_rt), .rs(id_rs_data[i]), .rt(id_rt_data[i]),
                .decoded_rd_address(wb_rd), .decoded_reg_write_enable(wb_reg_we), .decoded_reg_input_mux(wb_reg_mux),
                .decoded_immediate(wb_imm), .alu_out(wb_alu_out[i]), .lsu_out(wb_lsu_out[i])
            );

            always @(posedge clk) begin
                if (!reset && start && wb_active_mask[i] && wb_reg_we && wb_rd < 13) begin
                    $display("[%0t] [WB]  Thread %0d: Writing rd(%0d) <= %0d", $time, i, wb_rd, 
                        (wb_reg_mux == 2'b00) ? wb_alu_out[i] :
                        (wb_reg_mux == 2'b01) ? wb_lsu_out[i] :
                        (wb_reg_mux == 2'b10) ? wb_imm :
                        (wb_reg_mux == 2'b11) ? wb_lsu_out[i] : 16'bx);
                end
            end
        end
    endgenerate

    // -------------------------------------------------------------------------
    // 6. SCHEDULER / PIPELINE CONTROLLER
    // -------------------------------------------------------------------------
    scheduler #(
        .THREADS_PER_BLOCK(THREADS_PER_BLOCK)
    ) scheduler_instance (
        .clk(clk), .reset(reset), .start(start), .thread_count(thread_count),
        
        .pipeline_stall(scheduler_stall), // Perfectly protects the PC from incrementing!
        .pipeline_flush(pipeline_flush),
        
        .if_pc(if_pc), .sched_active_mask(sched_active_mask),
        
        .ex_active_mask(ex_active_mask), .ex_pc(ex_pc), .ex_next_pc(ex_next_pc),
        .ex_ret(ex_ret), .ex_sync(ex_sync), .done(done)
    );

endmodule