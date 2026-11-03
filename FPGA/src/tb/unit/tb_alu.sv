`default_nettype none
`timescale 1ns/1ns

// Unit test for alu.sv: every op vs. an SV reference, with corner + random
// vectors. DIV/MOD are checked against real division when built with
// -DUSE_COMB_DIV, and against the documented "stub returns 0" otherwise.
module tb_alu;
    localparam W = gpu_pkg::DATA_BITS;
    reg enable = 1, outmux = 0;
    reg [4:0] op = 0;
    reg [W-1:0] rs = 0, rt = 0, rdv = 0;
    wire [W-1:0] y; wire div0, fc, fv, fz, fn, fsat;
    integer errors = 0, nvec = 0;

    alu dut (.enable(enable), .decoded_alu_arithmetic_mux(op), .decoded_alu_output_mux(outmux),
             .rs(rs), .rt(rt), .rd_val(rdv), .alu_out(y), .div_by_zero(div0),
             .flag_c(fc), .flag_v(fv), .flag_z(fz), .flag_n(fn), .flag_sat(fsat));

    localparam ADD=0, SUB=1, MUL=2, DIV=3, AND=4, OR=5, XOR=6, SHL=7, SHR=8, MOD=9,
               MIN=10, MAX=11, ABS=12, NEG=13, MAC=14, POPCNT=15, CLZ=16, BREV=17;

    // expected-value state
    reg [W-1:0] ey; reg ec, ev, edz;
    reg signed [63:0] p;
    reg signed [W-1:0] srs, srt;
    reg [W:0] t33;
    integer k;

    task compute;
        begin
            srs = rs; srt = rt; ey = 0; ec = 0; ev = 0; edz = 0;
            case (op)
                ADD: begin t33 = {1'b0,rs} + {1'b0,rt}; ey = t33[W-1:0]; ec = t33[W];
                     ev = (rs[W-1] == rt[W-1]) && (ey[W-1] != rs[W-1]); end
                SUB: begin t33 = {1'b0,rs} - {1'b0,rt}; ey = t33[W-1:0]; ec = t33[W];
                     ev = (rs[W-1] != rt[W-1]) && (ey[W-1] != rs[W-1]); end
                MUL: begin p = srs * srt; ey = p[W-1:0]; ev = (p > 64'sd2147483647) || (p < -64'sd2147483648); end
                DIV: begin if (rt == 0) edz = 1;
`ifdef USE_COMB_DIV
                     else ey = rs / rt;
`endif
                     end
                MOD: begin if (rt == 0) edz = 1;
`ifdef USE_COMB_DIV
                     else ey = rs % rt;
`endif
                     end
                AND: ey = rs & rt;
                OR:  ey = rs | rt;
                XOR: ey = rs ^ rt;
                SHL: begin ey = rs << rt; ec = (rt > 0 && rt <= W) ? rs[W - rt] : 1'b0; end
                SHR: begin ey = rs >> rt; ec = (rt > 0 && rt <= W) ? rs[rt - 1] : 1'b0; end
                MIN: ey = (srs < srt) ? rs : rt;
                MAX: ey = (srs > srt) ? rs : rt;
                ABS: ey = (srs < 0) ? -srs : srs;
                NEG: begin ey = -srs; ev = (rs == 32'h80000000); end
                MAC: begin p = $signed(rdv) + srs * srt; ey = p[W-1:0]; ev = (p > 64'sd2147483647) || (p < -64'sd2147483648); end
                POPCNT: begin ey = 0; for (k = 0; k < W; k = k + 1) ey = ey + rs[k]; end
                CLZ: begin ey = W; for (k = W-1; k >= 0; k = k - 1) if (rs[k] && ey == W) ey = (W-1) - k; end
                BREV: for (k = 0; k < W; k = k + 1) ey[k] = rs[W-1-k];
                default: ey = 0;
            endcase
        end
    endtask

    task check;
        begin
            compute; #1; nvec = nvec + 1;
            if (y !== ey || div0 !== edz) begin
                errors = errors + 1;
                if (errors < 20) $display("[FAIL] op=%0d rs=%h rt=%h rd=%h: y=%h exp=%h div0=%b exp=%b", op, rs, rt, rdv, y, ey, div0, edz);
            end
            if (op <= SUB || op == SHL || op == SHR) if (fc !== ec) begin
                errors = errors + 1; if (errors < 20) $display("[FAIL] op=%0d rs=%h rt=%h carry=%b exp=%b", op, rs, rt, fc, ec); end
            if (op == ADD || op == SUB || op == MUL || op == NEG || op == MAC) if (fv !== ev) begin
                errors = errors + 1; if (errors < 20) $display("[FAIL] op=%0d rs=%h rt=%h ovf=%b exp=%b", op, rs, rt, fv, ev); end
            if (op <= BREV && op != SHL && op != SHR || 1) begin
                if (fz !== (y == 0) || fn !== y[W-1]) begin
                    errors = errors + 1; if (errors < 20) $display("[FAIL] op=%0d z/n flags: z=%b n=%b y=%h", op, fz, fn, y); end
            end
        end
    endtask

    reg [W-1:0] corners [0:11];
    integer i, j, o;
    initial begin
        corners[0]=0; corners[1]=1; corners[2]=2; corners[3]=32'hFFFFFFFF; corners[4]=32'h7FFFFFFF;
        corners[5]=32'h80000000; corners[6]=32'h80000001; corners[7]=31; corners[8]=32; corners[9]=33;
        corners[10]=32'h0000FFFF; corners[11]=32'hAAAAAAAA;
        #1;
        for (o = 0; o <= BREV; o = o + 1) begin
            op = o;
            for (i = 0; i < 12; i = i + 1) for (j = 0; j < 12; j = j + 1) begin
                rs = corners[i]; rt = corners[j]; rdv = corners[(i+j)%12]; check;
            end
            for (i = 0; i < 3000; i = i + 1) begin
                rs = $urandom; rt = (i % 4 == 0) ? ($urandom % 40) : $urandom; rdv = $urandom; check;
            end
        end

        // CMP output mux: {rs<rt, rs==rt, rs>rt}, unsigned compare
        outmux = 1;
        for (i = 0; i < 12; i = i + 1) for (j = 0; j < 12; j = j + 1) begin
            rs = corners[i]; rt = corners[j]; #1; nvec = nvec + 1;
            if (y !== {{(W-3){1'b0}}, (rs < rt), (rs == rt), (rs > rt)}) begin
                errors = errors + 1; $display("[FAIL] CMP rs=%h rt=%h y=%h", rs, rt, y); end
        end
        outmux = 0;

        // disabled -> zero output
        enable = 0; op = ADD; rs = 5; rt = 6; #1;
        if (y !== 0) begin errors = errors + 1; $display("[FAIL] disabled alu_out=%h", y); end

        if (errors == 0) $display("tb_alu: ALL PASSED (%0d vectors)", nvec);
        else $fatal(1, "tb_alu: %0d errors", errors);
        $finish;
    end
endmodule
