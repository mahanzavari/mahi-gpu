`default_nettype none
`timescale 1ns/1ns

// Unit test for the shared iterative divider (src/rtl/divider.sv).
// Random and corner operands, random lane masks, DIV and MOD; checks every active lane against / and %,
// inactive lanes are don't-care. Also reports the worst observed latency (cycles from start to done).
module tb_divider;
    localparam LANES = 4, W = 32;
    reg clk = 0, reset = 1;
    always #5 clk = ~clk;

    reg start = 0, is_mod = 0, ack = 0;
    reg [LANES-1:0] mask = 0;
    reg [0:0] warp = 0; reg [4:0] rd = 0;
    reg [W-1:0] a [LANES], b [LANES];
    wire busy, done; wire [W-1:0] result [LANES]; wire [LANES-1:0] out_mask; wire [0:0] out_warp; wire [4:0] out_rd;

    divider #(.LANES(LANES), .DATA_BITS(W), .WARP_BITS(1)) dut (
        .clk(clk), .reset(reset), .start(start), .is_mod(is_mod), .mask(mask), .warp(warp), .rd(rd), .a(a), .b(b),
        .busy(busy), .done(done), .ack(ack), .result(result), .out_mask(out_mask), .out_warp(out_warp), .out_rd(out_rd));

    integer errors = 0, n, l, cyc, worst = 0, tests = 0;
    reg [W-1:0] exp_v;
    reg [31:0] rng = 32'h1;
    function [31:0] xs(input [31:0] x); begin x = x ^ (x << 13); x = x ^ (x >> 17); x = x ^ (x << 5); xs = x; end endfunction
    function [31:0] pick(input [31:0] r, input [31:0] s);
        case (r[2:0])
            3'd0: pick = 0;
            3'd1: pick = 1;
            3'd2: pick = 32'hFFFF_FFFF;
            3'd3: pick = 32'h1 << s[4:0];
            3'd4: pick = s & 32'h0000_00FF;
            default: pick = s;
        endcase
    endfunction

    task run_one;
        begin
            @(posedge clk); #1 start = 1; @(posedge clk); #1 start = 0;
            cyc = 1;
            while (!done && cyc < 2000) begin @(posedge clk); cyc = cyc + 1; end
            if (!done) begin $display("TB_FAIL: divider never finished"); errors = errors + 1; end
            if (cyc > worst) worst = cyc;
            if (out_mask !== mask || out_rd !== rd || out_warp !== warp) begin $display("TB_FAIL: tag mismatch"); errors = errors + 1; end
            for (l = 0; l < LANES; l = l + 1) if (mask[l]) begin
                exp_v = is_mod ? a[l] % b[l] : a[l] / b[l];
                if (result[l] !== exp_v) begin
                    errors = errors + 1;
                    if (errors < 10) $display("TB_FAIL lane %0d: %0d %s %0d = %0d, got %0d", l, a[l], is_mod ? "%" : "/", b[l], exp_v, result[l]);
                end
            end
            tests = tests + 1;
            #1 ack = 1; @(posedge clk); #1 ack = 0;
            @(posedge clk);
            if (busy || done) begin $display("TB_FAIL: not idle after ack"); errors = errors + 1; end
        end
    endtask

    initial begin
        for (l = 0; l < LANES; l = l + 1) begin a[l] = 0; b[l] = 1; end
        repeat (3) @(posedge clk); #1 reset = 0;
        // worst case: all lanes, MSB-set dividends, divisor 1
        mask = 4'hF; is_mod = 0;
        for (l = 0; l < LANES; l = l + 1) begin a[l] = 32'hFFFF_FFFF; b[l] = 1; end
        run_one;
        $display("worst-case latency (4 lanes, full-width dividends): %0d cycles", worst);
        for (n = 0; n < 4000; n = n + 1) begin
            rng = xs(rng); mask = rng[3:0]; is_mod = rng[4]; rd = rng[9:5]; warp = rng[10];
            for (l = 0; l < LANES; l = l + 1) begin
                rng = xs(rng); a[l] = pick(rng, xs(rng ^ 32'h9E37_79B9));
                rng = xs(rng); b[l] = pick(rng, xs(rng ^ 32'h7F4A_7C15)); if (b[l] == 0) b[l] = 3;
            end
            run_one;
        end
        if (errors == 0) $display("tb_divider: ALL PASSED (%0d operations, worst latency %0d cycles)", tests, worst);
        else $display("tb_divider: FAILED errors=%0d", errors);
        $finish;
    end
endmodule
