`default_nettype none
`timescale 1ns/1ns

// Unit test for pc.sv: NZP latch, CALL push, RET pop, nesting, per-warp
// isolation, and next_pc selection. Regression for the ASIC-port bug where the
// nzp/return_stack/stack_ptr updates were deleted. Run via `make unit-pc`.
module tb_pc;
    localparam AW = gpu_pkg::CFG_PMEM_ADDR_BITS;
    localparam DW = gpu_pkg::CFG_DMEM_DATA_BITS;
    localparam NW = gpu_pkg::CFG_NUM_WARPS;

    reg clk = 0, reset = 1, enable = 0;
    reg [$clog2(NW)-1:0] warp_id = 0;
    reg [2:0] decoded_nzp = 0;
    reg [DW-1:0] decoded_immediate = 0, alu_out = 0;
    reg decoded_nzp_write_enable = 0, decoded_pc_mux = 0, decoded_call = 0, decoded_ret_fn = 0;
    reg [AW-1:0] current_pc = 0;
    wire [AW-1:0] next_pc;
    integer errors = 0;

    pc dut (.clk(clk), .reset(reset), .enable(enable), .warp_id(warp_id),
            .decoded_nzp(decoded_nzp), .decoded_immediate(decoded_immediate),
            .decoded_nzp_write_enable(decoded_nzp_write_enable), .decoded_pc_mux(decoded_pc_mux),
            .decoded_call(decoded_call), .decoded_ret_fn(decoded_ret_fn),
            .alu_out(alu_out), .current_pc(current_pc), .next_pc(next_pc));

    always #5 clk = ~clk;

    task check(input [AW-1:0] got, input [AW-1:0] exp, input [255:0] what);
        if (got !== exp) begin
            $display("[FAIL] %0s: got %0d expected %0d", what, got, exp);
            errors = errors + 1;
        end
    endtask

    task idle; begin
        decoded_nzp_write_enable = 0; decoded_call = 0; decoded_ret_fn = 0; decoded_pc_mux = 0;
    end endtask

    task do_cmp(input [2:0] flags); begin
        decoded_nzp_write_enable = 1; alu_out = flags; @(posedge clk); #1; idle;
    end endtask

    task do_call(input [AW-1:0] pc_at, input [AW-1:0] target); begin
        current_pc = pc_at; decoded_immediate = target; decoded_call = 1;
        #1 check(next_pc, target, "CALL next_pc");
        @(posedge clk); #1; idle;
    end endtask

    task do_ret(input [AW-1:0] exp_ret); begin
        decoded_ret_fn = 1;
        #1 check(next_pc, exp_ret, "RET next_pc");
        @(posedge clk); #1; idle;
    end endtask

    integer i;
    initial begin
        repeat (2) @(posedge clk);
        reset = 0; enable = 1;

        // --- NZP latch + branch taken / not taken ---
        do_cmp(3'b010); // Z
        decoded_pc_mux = 1; decoded_nzp = 3'b010; decoded_immediate = 100; current_pc = 7;
        #1 check(next_pc, 100, "BRz taken");
        decoded_nzp = 3'b100;
        #1 check(next_pc, 8, "BRn not taken");
        idle;

        // --- nested CALL/RET returns in LIFO order ---
        do_call(10, 50);
        do_call(51, 80);
        do_call(81, 90);
        do_ret(82);
        do_ret(52);
        do_ret(11);

        // --- per-warp isolation (NZP and stack) ---
        warp_id = 0; do_cmp(3'b001);
        warp_id = 1; do_cmp(3'b100);
        decoded_pc_mux = 1; decoded_nzp = 3'b001; decoded_immediate = 33; current_pc = 1;
        warp_id = 0; #1 check(next_pc, 33, "warp0 P taken");
        warp_id = 1; #1 check(next_pc, 2, "warp1 P not taken");
        idle;
        warp_id = 0; do_call(200, 300);
        warp_id = 1; do_call(400, 500);
        warp_id = 0; do_ret(201);
        warp_id = 1; do_ret(401);

        // --- full 8-deep stack ---
        warp_id = 0;
        for (i = 0; i < 8; i = i + 1) do_call(100 + i, 600 + i);
        for (i = 7; i >= 0; i = i - 1) do_ret(101 + i);

        // --- disabled: no state change, next_pc holds ---
        enable = 0; decoded_call = 1; current_pc = 9; #1 check(next_pc, 9, "disabled holds pc");
        @(posedge clk); #1; idle; enable = 1;
        decoded_ret_fn = 0;

        if (errors == 0) $display("tb_pc: ALL PASSED");
        else $fatal(1, "tb_pc: %0d errors", errors);
        $finish;
    end
endmodule
