`default_nettype none
`timescale 1ns/1ps

module tb_fp32_fma;
    reg        clk;
    reg        reset;
    reg        valid_in;
    reg [31:0] a_in;
    reg [31:0] b_in;
    reg [31:0] c_in;
    reg [1:0]  op_in;

    wire        valid_out;
    wire [31:0] result_out;

    // Instantiate DUT
    fp32_fma dut (
        .clk(clk),
        .reset(reset),
        .valid_in(valid_in),
        .a_in(a_in),
        .b_in(b_in),
        .c_in(c_in),
        .op_in(op_in),
        .valid_out(valid_out),
        .result_out(result_out)
    );

    // Clock generation (100 MHz)
    initial begin
        clk = 0;
        forever #5 clk = ~clk;
    end

    // Test tracking scoreboard
    typedef struct {
        string name;
        reg [1:0]  op;
        reg [31:0] a;
        reg [31:0] b;
        reg [31:0] c;
        reg [31:0] expected;
    } test_case_t;

    test_case_t test_queue[$];
    test_case_t active_checks[$];

    int pass_count = 0;
    int fail_count = 0;

    // Helper task to push test
    task queue_test(input string name, input [1:0] op, input [31:0] a, input [31:0] b, input [31:0] c, input [31:0] exp);
        test_case_t tc;
        tc.name = name;
        tc.op = op;
        tc.a = a;
        tc.b = b;
        tc.c = c;
        tc.expected = exp;
        test_queue.push_back(tc);
    endtask

    // Monitor logic: FPU has a 5-cycle pipeline latency
    always @(posedge clk) begin
        if (!reset && valid_out) begin
            if (active_checks.size() > 0) begin
                test_case_t check = active_checks.pop_front();
                if (result_out === check.expected) begin
                    $display("[PASS] %-24s | Result: 0x%08h (Expected: 0x%08h)", check.name, result_out, check.expected);
                    pass_count++;
                end else begin
                    $display("[FAIL] %-24s | Result: 0x%08h | Expected: 0x%08h | A: %h, B: %h, C: %h, Op: %0d", 
                             check.name, result_out, check.expected, check.a, check.b, check.c, check.op);
                    fail_count++;
                end
            end else begin
                $display("[ERROR] Unexpected valid_out with empty check queue! Result: %h", result_out);
                fail_count++;
            end
        end
    end

    initial begin
        reset = 1;
        valid_in = 0;
        a_in = 0; b_in = 0; c_in = 0; op_in = 0;
        #50;
        @(posedge clk);
        reset = 0;
        @(posedge clk);

        // IEEE-754 Single-Precision Constants:
        // 1.0f = 0x3F800000, 2.0f = 0x40000000, 3.0f = 0x40400000
        // 4.0f = 0x40800000, 5.0f = 0x40A00000, 6.0f = 0x40C00000
        // 7.0f = 0x40E00000, 0.5f = 0x3F000000, 0.0f = 0x00000000
        // -2.0f = 0xC0000000, -1.0f = 0xBF800000

        // 1. FADD Tests (op = 2'b01 -> a + b)
        queue_test("FADD: 2.0 + 3.0 = 5.0",    2'b01, 32'h40000000, 32'h40400000, 32'h0, 32'h40A00000);
        queue_test("FADD: 1.0 + 0.0 = 1.0",    2'b01, 32'h3F800000, 32'h00000000, 32'h0, 32'h3F800000);
        queue_test("FADD: 3.0 + (-2.0) = 1.0", 2'b01, 32'h40400000, 32'hC0000000, 32'h0, 32'h3F800000);

        // 2. FSUB Tests (op = 2'b11 -> a - b)
        queue_test("FSUB: 3.0 - 2.0 = 1.0",    2'b11, 32'h40400000, 32'h40000000, 32'h0, 32'h3F800000);
        queue_test("FSUB: 2.0 - 3.0 = -1.0",   2'b11, 32'h40000000, 32'h40400000, 32'h0, 32'hBF800000);
        queue_test("FSUB: 2.0 - 2.0 = 0.0",    2'b11, 32'h40000000, 32'h40000000, 32'h0, 32'h00000000);

        // 3. FMUL Tests (op = 2'b10 -> a * b)
        queue_test("FMUL: 2.0 * 3.0 = 6.0",    2'b10, 32'h40000000, 32'h40400000, 32'h0, 32'h40C00000);
        queue_test("FMUL: 4.0 * 0.5 = 2.0",    2'b10, 32'h40800000, 32'h3F000000, 32'h0, 32'h40000000);
        queue_test("FMUL: 2.0 * (-1.0) = -2.0",2'b10, 32'h40000000, 32'hBF800000, 32'h0, 32'hC0000000);

        // 4. FMA Tests (op = 2'b00 -> a * b + c)
        queue_test("FMA: 2.0*3.0 + 1.0 = 7.0", 2'b00, 32'h40000000, 32'h40400000, 32'h3F800000, 32'h40E00000);
        queue_test("FMA: 2.0*3.0 + (-2.0)=4.0",2'b00, 32'h40000000, 32'h40400000, 32'hC0000000, 32'h40800000);
        queue_test("FMA: 0.5*4.0 + 3.0 = 5.0", 2'b00, 32'h3F000000, 32'h40800000, 32'h40400000, 32'h40A00000);

        // Feed test cases consecutively (Tests pipelined back-to-back throughput)
        $display("\n>>> Starting FPU Pipeline Simulation (12 vectors)...");
        while (test_queue.size() > 0) begin
            test_case_t cur = test_queue.pop_front();
            @(posedge clk);
            valid_in <= 1'b1;
            op_in    <= cur.op;
            a_in     <= cur.a;
            b_in     <= cur.b;
            c_in     <= cur.c;
            active_checks.push_back(cur);
        end

        @(posedge clk);
        valid_in <= 1'b0;

        // Drain pipeline
        repeat(15) @(posedge clk);

        $display("\n==================================================");
        $display("   FPU UNIT TEST SUMMARY");
        $display("   Passed: %0d", pass_count);
        $display("   Failed: %0d", fail_count);
        $display("==================================================");

        if (fail_count == 0 && pass_count > 0) begin
            $display("   STATUS: ALL UNIT TESTS PASSED!\n");
        end else begin
            $display("   STATUS: UNIT TESTS FAILED!\n");
        end

        $finish;
    end
endmodule