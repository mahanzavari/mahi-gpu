`default_nettype none
`timescale 1ns/1ns

// Unit test for registers.sv: reset values of the special registers, write
// ports and their priority (FP > LSU > ALU), forwarding into the read ports,
// protection of r29..r31, and per-warp isolation.
module tb_registers;
    localparam NW = gpu_pkg::CFG_NUM_WARPS, TPB = gpu_pkg::CFG_THREADS_PER_BLOCK, W = gpu_pkg::DATA_BITS;
    localparam WB = $clog2(NW);
    reg clk = 0, reset = 1, enable = 0;
    reg [WB-1:0] warp_id = 0, read_warp_id = 0;
    reg [7:0] block_id = 8'd5, thread_id = 8'd2;
    reg [4:0] wr_rd = 0, rd_addr = 0, rs_addr = 0, rt_addr = 0;
    reg reg_we = 0; reg [1:0] mux = 0;
    reg [W-1:0] imm = 0, alu_out = 0, lsu_out = 0;
    reg lsu_we = 0; reg [WB-1:0] lsu_warp = 0; reg [4:0] lsu_rd = 0; reg [W-1:0] lsu_data = 0;
    reg fp_valid = 0; reg [WB-1:0] fp_warp = 0; reg [4:0] fp_rd = 0; reg [W-1:0] fp_data = 0;
    wire [W-1:0] rs, rt, rdv;
    integer errors = 0;

    registers dut (.clk(clk), .reset(reset), .enable(enable), .warp_id(warp_id), .read_warp_id(read_warp_id),
        .block_id(block_id), .thread_id(thread_id), .decoded_rd_address(wr_rd), .read_rd_address(rd_addr),
        .decoded_rs_address(rs_addr), .decoded_rt_address(rt_addr), .decoded_reg_write_enable(reg_we),
        .decoded_reg_input_mux(mux), .decoded_immediate(imm), .alu_out(alu_out), .lsu_out(lsu_out),
        .lsu_we(lsu_we), .lsu_warp_id(lsu_warp), .lsu_rd(lsu_rd), .lsu_data(lsu_data),
        .rs(rs), .rt(rt), .rd_val(rdv),
        .fp_wb_valid(fp_valid), .fp_wb_warp_id(fp_warp), .fp_wb_rd(fp_rd), .fp_wb_data(fp_data));

    always #5 clk = ~clk;

    task expect32(input [W-1:0] got, input [W-1:0] exp, input [255:0] what);
        if (got !== exp) begin errors = errors + 1; $display("[FAIL] %0s: got %h exp %h", what, got, exp); end
    endtask
    task idle; begin enable = 0; reg_we = 0; lsu_we = 0; fp_valid = 0; end endtask
    task tick; begin @(posedge clk); #1; end endtask
    task alu_write(input [WB-1:0] w, input [4:0] r, input [W-1:0] v);
        begin warp_id = w; wr_rd = r; alu_out = v; mux = 0; enable = 1; reg_we = 1; tick; enable = 0; reg_we = 0; end
    endtask
    task read1(input [WB-1:0] w, input [4:0] r);
        begin read_warp_id = w; rs_addr = r; rt_addr = r; rd_addr = r; #1; end
    endtask

    integer w, r;
    initial begin
        tick; tick; reset = 0; tick;
        // reset values
        for (w = 0; w < NW; w = w + 1) begin
            read1(w, 0);  expect32(rs, 0, "r0 reset");
            read1(w, 30); expect32(rs, TPB*NW, "r30 reset (threads/block)");
            read1(w, 31); expect32(rs, w*TPB + 2, "r31 reset (thread id)");
            read1(w, 29); expect32(rs, 5, "r29 block_id");
        end
        block_id = 8'd9; tick; read1(0, 29); expect32(rs, 9, "r29 follows block_id");

        // ALU write, visible next cycle; isolation across warps
        alu_write(0, 3, 32'hAAAA0003);
        read1(0, 3); expect32(rs, 32'hAAAA0003, "alu write w0.r3");
        read1(NW-1, 3); expect32(rs, 0, "other warp r3 untouched");
        alu_write(NW-1, 3, 32'hBBBB0003);
        read1(0, 3); expect32(rs, 32'hAAAA0003, "w0.r3 intact");
        read1(NW-1, 3); expect32(rs, 32'hBBBB0003, "wN.r3 written");

        // input mux: memory, constant
        warp_id = 0; wr_rd = 4; mux = 2'b01; lsu_out = 32'h11110004; enable = 1; reg_we = 1; tick; idle;
        read1(0, 4); expect32(rs, 32'h11110004, "mux MEMORY");
        warp_id = 0; wr_rd = 5; mux = 2'b10; imm = 32'hFFFF8000; enable = 1; reg_we = 1; tick; idle;
        read1(0, 5); expect32(rs, 32'hFFFF8000, "mux CONSTANT");

        // r29..r31 are read-only to every write port
        alu_write(0, 31, 32'hDEAD); alu_write(0, 30, 32'hDEAD); alu_write(0, 29, 32'hDEAD);
        lsu_we = 1; lsu_warp = 0; lsu_rd = 31; lsu_data = 32'hDEAD; tick; idle;
        fp_valid = 1; fp_warp = 0; fp_rd = 30; fp_data = 32'hDEAD; tick; idle;
        read1(0, 31); expect32(rs, 2, "r31 protected");
        read1(0, 30); expect32(rs, TPB*NW, "r30 protected");

        // write-through forwarding: reading the register being written this cycle
        warp_id = 0; wr_rd = 7; alu_out = 32'h77770007; mux = 0; enable = 1; reg_we = 1;
        read_warp_id = 0; rs_addr = 7; rt_addr = 7; rd_addr = 7; #1;
        expect32(rs, 32'h77770007, "fwd rs from WB"); expect32(rt, 32'h77770007, "fwd rt from WB");
        expect32(rdv, 32'h77770007, "fwd rd_val from WB");
        read_warp_id = NW-1; #1; // same reg index but different warp: no forward
        if (NW > 1) expect32(rs, 0, "no fwd across warps");
        tick; idle;

        // LSU forwarding
        lsu_we = 1; lsu_warp = 0; lsu_rd = 8; lsu_data = 32'h88880008;
        read_warp_id = 0; rs_addr = 8; #1; expect32(rs, 32'h88880008, "fwd from LSU");
        tick; idle;
        read1(0, 8); expect32(rs, 32'h88880008, "LSU write landed");

        // collision priority on one register: FP > LSU > ALU
        warp_id = 0; wr_rd = 9; alu_out = 32'hA1; mux = 0; enable = 1; reg_we = 1;
        lsu_we = 1; lsu_warp = 0; lsu_rd = 9; lsu_data = 32'hB2;
        fp_valid = 1; fp_warp = 0; fp_rd = 9; fp_data = 32'hC3; tick; idle;
        read1(0, 9); expect32(rs, 32'hC3, "FP wins over LSU and ALU");
        warp_id = 0; wr_rd = 10; alu_out = 32'hA1; enable = 1; reg_we = 1;
        lsu_we = 1; lsu_warp = 0; lsu_rd = 10; lsu_data = 32'hB2; tick; idle;
        read1(0, 10); expect32(rs, 32'hB2, "LSU wins over ALU");

        // independent simultaneous writes to different registers all land
        warp_id = 0; wr_rd = 11; alu_out = 32'h11; enable = 1; reg_we = 1;
        lsu_we = 1; lsu_warp = 0; lsu_rd = 12; lsu_data = 32'h22;
        fp_valid = 1; fp_warp = 0; fp_rd = 13; fp_data = 32'h33; tick; idle;
        read1(0, 11); expect32(rs, 32'h11, "parallel alu"); read1(0, 12); expect32(rs, 32'h22, "parallel lsu");
        read1(0, 13); expect32(rs, 32'h33, "parallel fp");

        // reg_we=0 or enable=0 must not write
        warp_id = 0; wr_rd = 14; alu_out = 32'h99; enable = 1; reg_we = 0; tick; idle;
        enable = 0; reg_we = 1; tick; idle;
        read1(0, 14); expect32(rs, 0, "no write without enable&we");

        // a different-warp FP/LSU write to the same index must not suppress the ALU write
        if (NW > 1) begin
            warp_id = 0; wr_rd = 15; alu_out = 32'h5555; enable = 1; reg_we = 1;
            fp_valid = 1; fp_warp = NW-1; fp_rd = 15; fp_data = 32'h6666; tick; idle;
            read1(0, 15); expect32(rs, 32'h5555, "alu write survives other-warp fp same index");
            read1(NW-1, 15); expect32(rs, 32'h6666, "other-warp fp write landed");
        end

        // reset clears everything
        reset = 1; tick; reset = 0; tick;
        read1(0, 3); expect32(rs, 0, "reset clears r3");

        if (errors == 0) $display("tb_registers: ALL PASSED");
        else $fatal(1, "tb_registers: %0d errors", errors);
        $finish;
    end
endmodule
