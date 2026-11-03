`default_nettype none
`timescale 1ns/1ns

// Unit test for fp32_fma.sv (FMA/FADD/FMUL/FSUB, truncating, flush-to-zero,
// no Inf/NaN). Pipelined: issue one op per cycle, check results in order
// against a double-precision reference.
//   op 00: a*b+c   01: a+b   10: a*b   11: a-b
module tb_fp32_fma;
    reg clk = 0, reset = 1, valid_in = 0;
    reg [31:0] a = 0, b = 0, c = 0; reg [1:0] op = 0;
    wire valid_out; wire [31:0] result;
    integer errors = 0, checked = 0, latency = -1;

    fp32_fma dut (.clk(clk), .reset(reset), .valid_in(valid_in), .a_in(a), .b_in(b), .c_in(c),
                  .op_in(op), .valid_out(valid_out), .result_out(result));
    always #5 clk = ~clk;

    // expected-result FIFO
    real  exp_q [0:4095]; real mag_q [0:4095]; reg [31:0] bits_q [0:4095];
    integer wr = 0, rd = 0;

    // Explicit IEEE-754 binary32 -> real (Verilator's $bitstoshortreal is unreliable).
    // Denormals flush to zero, matching the DUT.
    function real f2r(input [31:0] x);
        real m; integer e;
        begin
            e = x[30:23];
            if (e == 0) f2r = 0.0;
            else begin
                m = 1.0 + $itor(x[22:0]) / 8388608.0;
                f2r = m * (2.0 ** (e - 127));
                if (x[31]) f2r = -f2r;
            end
        end
    endfunction

    real ra, rb, rc, ref_v, mag, err, tol;
    task issue(input [1:0] o, input [31:0] x, input [31:0] y, input [31:0] z);
        begin
            op = o; a = x; b = y; c = z; valid_in = 1;
            ra = f2r(x); rb = f2r(y); rc = f2r(z);
            case (o)
                2'b00: begin ref_v = ra*rb + rc; mag = (ra*rb < 0 ? -ra*rb : ra*rb) + (rc < 0 ? -rc : rc); end
                2'b01: begin ref_v = ra + rb;    mag = (ra < 0 ? -ra : ra) + (rb < 0 ? -rb : rb); end
                2'b10: begin ref_v = ra * rb;    mag = (ra*rb < 0) ? -ra*rb : ra*rb; end
                2'b11: begin ref_v = ra - rb;    mag = (ra < 0 ? -ra : ra) + (rb < 0 ? -rb : rb); end
            endcase
            exp_q[wr % 4096] = ref_v; mag_q[wr % 4096] = mag; bits_q[wr % 4096] = x; wr = wr + 1;
            @(posedge clk); #1; valid_in = 0;
        end
    endtask

    // checker
    real got;
    always @(posedge clk) if (!reset && valid_out) begin
        got = f2r(result);
        err = got - exp_q[rd % 4096]; if (err < 0) err = -err;
        ref_v = exp_q[rd % 4096]; if (ref_v < 0) ref_v = -ref_v;
        tol = ref_v * 4.8e-7 + mag_q[rd % 4096] * 5.0e-14;
        // results below the normal range flush to zero in the DUT
        if (ref_v < 1.2e-38) tol = 1.2e-38;
        if (err > tol || result[30:23] == 8'hFF) begin
            errors = errors + 1;
            if (errors < 20) $display("[FAIL] #%0d got=%e (%h) exp=%e err=%e tol=%e", rd, got, result, exp_q[rd % 4096], err, tol);
        end
        checked = checked + 1; rd = rd + 1;
    end

    function [31:0] mk(input s, input integer e, input [22:0] m);
        mk = {s, 8'(e), m};
    endfunction

    integer i;
    reg [31:0] x, y, z;
    initial begin
        repeat (3) @(posedge clk); #1; reset = 0;

        // directed exact cases
        issue(2'b01, 32'h3F800000, 32'h3F800000, 0);          // 1+1 = 2
        issue(2'b10, 32'h40400000, 32'h40800000, 0);          // 3*4 = 12
        issue(2'b11, 32'h3F800000, 32'h3F800000, 0);          // 1-1 = 0
        issue(2'b00, 32'h40000000, 32'h40400000, 32'h40800000); // 2*3+4 = 10
        issue(2'b01, 0, 32'h40490FDB, 0);                      // 0 + pi
        issue(2'b10, 0, 32'h40490FDB, 0);                      // 0 * pi
        issue(2'b11, 32'h40490FDB, 32'h40490FDB, 0);           // pi - pi
        issue(2'b00, 32'h3F800000, 32'h3F800000, 32'hBF800000); // 1*1-1 = 0
        issue(2'b01, 32'h00400000, 32'h3F800000, 0);           // denormal input flushes: 0+1
        issue(2'b10, 32'hC0000000, 32'h40400000, 0);           // -2*3 = -6
        issue(2'b11, 32'h3F800000, 32'h40000000, 0);           // 1-2 = -1
        issue(2'b01, 32'h4B800000, 32'h3F800000, 0);           // 2^24 + 1 (large exponent gap)
        issue(2'b01, 32'h3F800000, 32'h33800000, 0);           // 1 + 2^-24

        // randomized, back-to-back, all ops, mixed signs, exponent windows
        for (i = 0; i < 4000; i = i + 1) begin
            x = mk($urandom, 100 + ($urandom % 56), $urandom);
            y = mk($urandom, 100 + ($urandom % 56), $urandom);
            z = mk($urandom, 100 + ($urandom % 56), $urandom);
            if (i % 5 == 0) z = {~x[31], x[30:0]} ^ (32'($urandom) & 32'h7);  // near-cancellation for a+c
            issue($urandom % 4, x, y, z);
            if (i % 7 == 0) begin valid_in = 0; @(posedge clk); #1; end    // bubbles
        end
        repeat (20) @(posedge clk);

        if (checked != wr) begin errors = errors + 1; $display("[FAIL] issued %0d results %0d", wr, checked); end
        if (errors == 0) $display("tb_fp32_fma: ALL PASSED (%0d results)", checked);
        else $fatal(1, "tb_fp32_fma: %0d errors", errors);
        $finish;
    end
endmodule
