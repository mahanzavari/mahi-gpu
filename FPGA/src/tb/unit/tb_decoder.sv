`default_nettype none
`timescale 1ns/1ns

// Unit test for decoder.sv: control-signal table for every opcode, operand
// field extraction (including the STR/STSH rt-in-rd-slot special case), and
// immediate sign extension.
module tb_decoder;
    localparam DW = gpu_pkg::DATA_BITS;
    reg [31:0] inst = 0;
    wire [4:0] rd, rs, rt; wire [2:0] nzp; wire [DW-1:0] imm;
    wire use_off; wire [15:0] off;
    wire rs_re, rt_re, rd_re, reg_we, mem_re, mem_we, nzp_we; wire [1:0] reg_mux;
    wire [4:0] alu_mux; wire alu_out_mux, pc_mux, call, ret, ex_exit, sync, sh_re, sh_we;
    wire [1:0] atomic; wire flags_we, is_fp; wire [1:0] fp_op;

    decoder dut (.instruction(inst), .decoded_rd_address(rd), .decoded_rs_address(rs), .decoded_rt_address(rt),
        .decoded_nzp(nzp), .decoded_immediate(imm), .decoded_use_mem_offset(use_off), .decoded_mem_addr_offset(off),
        .decoded_rs_read_enable(rs_re), .decoded_rt_read_enable(rt_re), .decoded_rd_read_enable(rd_re),
        .decoded_reg_write_enable(reg_we), .decoded_mem_read_enable(mem_re), .decoded_mem_write_enable(mem_we),
        .decoded_nzp_write_enable(nzp_we), .decoded_reg_input_mux(reg_mux), .decoded_alu_arithmetic_mux(alu_mux),
        .decoded_alu_output_mux(alu_out_mux), .decoded_pc_mux(pc_mux), .decoded_call(call), .decoded_ret_fn(ret),
        .decoded_exit(ex_exit), .decoded_sync(sync), .decoded_shared_read_enable(sh_re),
        .decoded_shared_write_enable(sh_we), .decoded_atomic(atomic), .decoded_flags_write_enable(flags_we),
        .decoded_is_fp(is_fp), .decoded_fp_op(fp_op));

    integer errors = 0;
    // Expected control word per opcode, packed:
    // {rs_re,rt_re,rd_re,reg_we,mem_re,mem_we,nzp_we,pc_mux,call,ret,exit,sync,sh_re,sh_we,flags_we,is_fp}
    reg [15:0] ctl [0:63];
    reg [4:0]  amux [0:63];
    reg [1:0]  rmux [0:63];
    reg [1:0]  atom [0:63];
    reg [1:0]  fpo  [0:63];
    reg        known [0:63];

    function [15:0] pk(input a,b,c,d,e,f,g,h,i,j,k,l,m,n,o,p);
        pk = {a,b,c,d,e,f,g,h,i,j,k,l,m,n,o,p};
    endfunction
    task def(input integer opc, input [15:0] c, input [4:0] am, input [1:0] rm, input [1:0] at, input [1:0] fo);
        begin ctl[opc]=c; amux[opc]=am; rmux[opc]=rm; atom[opc]=at; fpo[opc]=fo; known[opc]=1; end
    endtask

    integer o, i;
    reg [15:0] got;
    initial begin
        for (o = 0; o < 64; o = o + 1) begin ctl[o]=0; amux[o]=0; rmux[o]=0; atom[o]=0; fpo[o]=0; known[o]=0; end
        //                  rs rt rd we mr mw nz pm ca re ex sy sr sw fl fp
        def(0,  pk(0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0), 0,0,0,0); // NOP
        def(1,  pk(0,0,0,0,0,0,0,1,0,0,0,0,0,0,0,0), 0,0,0,0); // BRnzp
        def(2,  pk(1,1,0,0,0,0,1,0,0,0,0,0,0,0,0,0), 0,0,0,0); // CMP (alu_out_mux checked below)
        for (o = 3; o <= 6; o = o + 1) def(o, pk(1,1,0,1,0,0,0,0,0,0,0,0,0,0,1,0), o-3, 0,0,0); // ADD SUB MUL DIV
        def(7,  pk(1,0,0,1,1,0,0,0,0,0,0,0,0,0,0,0), 0,1,0,0); // LDR
        def(8,  pk(1,1,0,0,0,1,0,0,0,0,0,0,0,0,0,0), 0,0,0,0); // STR
        def(9,  pk(0,0,0,1,0,0,0,0,0,0,0,0,0,0,0,0), 0,2,0,0); // CONST
        def(10, pk(0,0,0,0,0,0,0,0,0,0,0,1,0,0,0,0), 0,0,0,0); // SYNC
        def(11, pk(1,0,0,1,0,0,0,0,0,0,0,0,1,0,0,0), 0,3,0,0); // LDSH
        def(12, pk(1,1,0,0,0,0,0,0,0,0,0,0,0,1,0,0), 0,0,0,0); // STSH
        def(13, pk(0,0,0,0,0,0,0,1,1,0,0,0,0,0,0,0), 0,0,0,0); // CALL
        def(14, pk(0,0,0,0,0,0,0,0,0,1,0,0,0,0,0,0), 0,0,0,0); // RET_FN
        def(15, pk(0,0,0,0,0,0,0,0,0,0,1,0,0,0,0,0), 0,0,0,0); // EXIT
        def(16, pk(1,1,0,1,0,0,0,0,0,0,0,0,0,0,0,0), 0,1,1,0); // ATOM_ADD
        for (o = 17; o <= 24; o = o + 1) def(o, pk(1,1,0,1,0,0,0,0,0,0,0,0,0,0,1,0), (o==17)?4:(o==18)?5:(o==19)?6:(o==20)?7:(o==21)?8:(o==22)?9:(o==23)?10:11, 0,0,0);
        def(25, pk(1,0,0,1,0,0,0,0,0,0,0,0,0,0,1,0), 12,0,0,0); // ABS
        def(26, pk(1,0,0,1,0,0,0,0,0,0,0,0,0,0,1,0), 13,0,0,0); // NEG
        def(27, pk(1,1,1,1,0,0,0,0,0,0,0,0,0,0,1,0), 14,0,0,0); // MAC
        def(28, pk(1,1,1,1,0,0,0,0,0,0,0,0,0,0,0,0), 0,1,2,0); // ATOM_CAS
        def(29, pk(0,0,0,1,0,0,0,0,0,0,0,0,0,0,0,0), 0,2,0,0); // LUI
        def(30, pk(1,0,0,1,0,0,0,0,0,0,0,0,0,0,1,0), 15,0,0,0); // POPCNT
        def(31, pk(1,0,0,1,0,0,0,0,0,0,0,0,0,0,1,0), 16,0,0,0); // CLZ
        def(32, pk(1,0,0,1,0,0,0,0,0,0,0,0,0,0,1,0), 17,0,0,0); // BREV
        def(33, pk(1,1,0,1,0,0,0,0,0,0,0,0,0,0,0,1), 0,0,0,1); // FADD
        def(34, pk(1,1,0,1,0,0,0,0,0,0,0,0,0,0,0,1), 0,0,0,3); // FSUB
        def(35, pk(1,1,0,1,0,0,0,0,0,0,0,0,0,0,0,1), 0,0,0,2); // FMUL
        def(36, pk(1,1,1,1,0,0,0,0,0,0,0,0,0,0,0,1), 0,0,0,0); // FMA

        for (o = 0; o < 64; o = o + 1) begin
            inst = {o[5:0], 26'h0155A5A}; #1;
            got = {rs_re,rt_re,rd_re,reg_we,mem_re,mem_we,nzp_we,pc_mux,call,ret,ex_exit,sync,sh_re,sh_we,flags_we,is_fp};
            if (known[o]) begin
                if (got !== ctl[o] || alu_mux !== amux[o]
                    || reg_mux !== rmux[o] || atomic !== atom[o] || fp_op !== fpo[o]) begin
                    errors = errors + 1;
                    $display("[FAIL] opcode %0d: ctl=%b exp=%b amux=%0d/%0d rmux=%0d/%0d atomic=%0d/%0d fp_op=%0d/%0d",
                             o, got, ctl[o], alu_mux, amux[o], reg_mux, rmux[o], atomic, atom[o], fp_op, fpo[o]);
                end
            end else begin
                // reserved opcodes must be inert (no side effects)
                if (got !== 16'b0 || atomic !== 0) begin errors = errors + 1; $display("[FAIL] reserved opcode %0d not inert: %b", o, got); end
            end
        end

        // CMP selects the flag output; LDR/STR use the memory offset; others don't
        inst = {6'd2, 26'h0}; #1; if (alu_out_mux !== 1) begin errors = errors + 1; $display("[FAIL] CMP alu_out_mux"); end
        inst = {6'd3, 26'h0}; #1; if (alu_out_mux !== 0) begin errors = errors + 1; $display("[FAIL] ADD alu_out_mux"); end
        inst = {6'd7, 26'h0}; #1; if (use_off !== 1) begin errors = errors + 1; $display("[FAIL] LDR use_mem_offset"); end
        inst = {6'd8, 26'h0}; #1; if (use_off !== 1) begin errors = errors + 1; $display("[FAIL] STR use_mem_offset"); end
        inst = {6'd16, 26'h0}; #1; if (use_off !== 0) begin errors = errors + 1; $display("[FAIL] ATOM use_mem_offset"); end

        // Field extraction. R-type: [25:21]=rd [20:16]=rs [15:11]=rt
        inst = {6'd3, 5'd7, 5'd8, 5'd9, 11'h0}; #1;
        if (rd !== 7 || rs !== 8 || rt !== 9) begin errors = errors + 1; $display("[FAIL] R fields %0d %0d %0d", rd, rs, rt); end
        // STR: rt comes from the rd slot, rs is the address register
        inst = {6'd8, 5'd7, 5'd31, 16'h0}; #1;
        if (rs !== 31 || rt !== 7) begin errors = errors + 1; $display("[FAIL] STR fields rs=%0d rt=%0d", rs, rt); end
        inst = {6'd12, 5'd6, 5'd2, 16'h0}; #1;
        if (rs !== 2 || rt !== 6) begin errors = errors + 1; $display("[FAIL] STSH fields rs=%0d rt=%0d", rs, rt); end
        // NZP field of a branch
        inst = {6'd1, 3'b101, 23'h0}; #1; if (nzp !== 3'b101) begin errors = errors + 1; $display("[FAIL] nzp=%b", nzp); end
        // immediate sign extension and LUI
        inst = {6'd9, 5'd1, 5'd0, 16'h8000}; #1;
        if (imm !== 32'hFFFF8000) begin errors = errors + 1; $display("[FAIL] imm sext %h", imm); end
        inst = {6'd9, 5'd1, 5'd0, 16'h7FFF}; #1;
        if (imm !== 32'h00007FFF) begin errors = errors + 1; $display("[FAIL] imm pos %h", imm); end
        inst = {6'd29, 5'd1, 20'hABCDE, 1'b0}; #1; // LUI: imm = instr[20:1] << 12
        if (imm !== {20'hABCDE, 12'b0}) begin errors = errors + 1; $display("[FAIL] LUI imm %h", imm); end

        if (errors == 0) $display("tb_decoder: ALL PASSED");
        else $fatal(1, "tb_decoder: %0d errors", errors);
        $finish;
    end
endmodule
