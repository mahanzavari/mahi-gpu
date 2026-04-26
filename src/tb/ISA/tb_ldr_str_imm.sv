`default_nettype none
`timescale 1ns/1ns

module tb_ldr_str_imm;

    // ──────────────────────────────────────────────────────
    //  Parameters (minimal configuration for quick test)
    // ──────────────────────────────────────────────────────
    localparam DATA_MEM_ADDR_BITS   = 8;
    localparam DATA_MEM_DATA_BITS   = 16;
    localparam DATA_MEM_NUM_CHANNELS = 4;          // 1 core * 4 threads
    localparam PROGRAM_MEM_ADDR_BITS   = 8;
    localparam PROGRAM_MEM_DATA_BITS   = 16;
    localparam PROGRAM_MEM_NUM_CHANNELS = 1;        // 1 core
    localparam NUM_CORES          = 1;
    localparam THREADS_PER_BLOCK  = 4;
    localparam NUM_WARPS          = 1;             // 1 warp → 4 threads

    // ──────────────────────────────────────────────────────
    //  Signals
    // ──────────────────────────────────────────────────────
    reg clk;
    reg reset;
    reg start;
    wire done;
    reg device_control_write_enable;
    reg [7:0] device_control_data;

    wire [PROGRAM_MEM_NUM_CHANNELS-1:0] program_mem_read_valid;
    wire [PROGRAM_MEM_ADDR_BITS-1:0] program_mem_read_address [PROGRAM_MEM_NUM_CHANNELS];
    reg [PROGRAM_MEM_NUM_CHANNELS-1:0] program_mem_read_ready;
    reg [PROGRAM_MEM_DATA_BITS-1:0] program_mem_read_data [PROGRAM_MEM_NUM_CHANNELS];

    wire [DATA_MEM_NUM_CHANNELS-1:0] data_mem_read_valid;
    wire [DATA_MEM_ADDR_BITS-1:0] data_mem_read_address [DATA_MEM_NUM_CHANNELS];
    reg [DATA_MEM_NUM_CHANNELS-1:0] data_mem_read_ready;
    reg [DATA_MEM_DATA_BITS-1:0] data_mem_read_data [DATA_MEM_NUM_CHANNELS];

    wire [DATA_MEM_NUM_CHANNELS-1:0] data_mem_write_valid;
    wire [DATA_MEM_ADDR_BITS-1:0] data_mem_write_address [DATA_MEM_NUM_CHANNELS];
    wire [DATA_MEM_DATA_BITS-1:0] data_mem_write_data [DATA_MEM_NUM_CHANNELS];
    reg [DATA_MEM_NUM_CHANNELS-1:0] data_mem_write_ready;

    // ──────────────────────────────────────────────────────
    //  DUT instantiation
    // ──────────────────────────────────────────────────────
    gpu #(
        .DATA_MEM_ADDR_BITS(DATA_MEM_ADDR_BITS),
        .DATA_MEM_DATA_BITS(DATA_MEM_DATA_BITS),
        .DATA_MEM_NUM_CHANNELS(DATA_MEM_NUM_CHANNELS),
        .PROGRAM_MEM_ADDR_BITS(PROGRAM_MEM_ADDR_BITS),
        .PROGRAM_MEM_DATA_BITS(PROGRAM_MEM_DATA_BITS),
        .PROGRAM_MEM_NUM_CHANNELS(PROGRAM_MEM_NUM_CHANNELS),
        .NUM_CORES(NUM_CORES),
        .THREADS_PER_BLOCK(THREADS_PER_BLOCK),
        .NUM_WARPS(NUM_WARPS)
    ) dut (
        .clk(clk),
        .reset(reset),
        .start(start),
        .done(done),
        .device_control_write_enable(device_control_write_enable),
        .device_control_data(device_control_data),

        .program_mem_read_valid(program_mem_read_valid),
        .program_mem_read_address(program_mem_read_address),
        .program_mem_read_ready(program_mem_read_ready),
        .program_mem_read_data(program_mem_read_data),

        .data_mem_read_valid(data_mem_read_valid),
        .data_mem_read_address(data_mem_read_address),
        .data_mem_read_ready(data_mem_read_ready),
        .data_mem_read_data(data_mem_read_data),

        .data_mem_write_valid(data_mem_write_valid),
        .data_mem_write_address(data_mem_write_address),
        .data_mem_write_data(data_mem_write_data),
        .data_mem_write_ready(data_mem_write_ready)
    );

    // ──────────────────────────────────────────────────────
    //  Program & Data memories (simple immediate response)
    // ──────────────────────────────────────────────────────
    reg [PROGRAM_MEM_DATA_BITS-1:0] p_mem [0:255];
    reg [DATA_MEM_DATA_BITS-1:0]    d_mem [0:255];

    always @(posedge clk) begin
        // Program memory – 1 cycle ready
        for (int i = 0; i < PROGRAM_MEM_NUM_CHANNELS; i++) begin
            program_mem_read_ready[i] <= program_mem_read_valid[i];
            if (program_mem_read_valid[i])
                program_mem_read_data[i] <= p_mem[program_mem_read_address[i]];
        end

        // Data memory – 1 cycle ready (no latency hiding test)
        for (int i = 0; i < DATA_MEM_NUM_CHANNELS; i++) begin
            data_mem_read_ready[i]  <= data_mem_read_valid[i];
            if (data_mem_read_valid[i])
                data_mem_read_data[i] <= d_mem[data_mem_read_address[i]];

            data_mem_write_ready[i] <= data_mem_write_valid[i];
            if (data_mem_write_valid[i])
                d_mem[data_mem_write_address[i]] <= data_mem_write_data[i];
        end
    end

    // ──────────────────────────────────────────────────────
    //  Clock generation
    // ──────────────────────────────────────────────────────
    initial begin
        clk = 0;
        forever #5 clk = ~clk;   // 10 ns period
    end

    // ──────────────────────────────────────────────────────
    //  Test sequence
    // ──────────────────────────────────────────────────────
    initial begin
        $display("===================================================");
        $display("  TEST: LDR_IMM & STR_IMM (Immediate Offset)");
        $display("===================================================");

        // Initialize memories
        for (int i = 0; i < 256; i++) begin
            d_mem[i] = 0;
            p_mem[i] = 16'h0000;
        end

        // Set test data: d_mem[225] = 123 (base 220 + offset 5)
        d_mem[225] = 16'd123;

        // ──────────────────────────────────────────────────
        //  Assembly program (single warp, 4 threads)
        //  All threads execute identically.
        // ──────────────────────────────────────────────────
        // PC  0: CONST R1, 220        ; base address
        p_mem[0] = 16'h91DC;   // 1001_0001_1101_1100

        // PC  1: LDR_IMM R2, [R1 + 5] ; load from base+5
        p_mem[1] = 16'hD215;   // 1101_0010_0001_0101

        // PC  2: STR_IMM [R1 + 10], R2 ; store to base+10
        p_mem[2] = 16'hEA12;   // 1110_1010_0001_0010

        // PC  3: ADD R3, R2, R2       ; dummy ALU op (verifies pipeline)
        p_mem[3] = 16'h3322;   // 0011_0011_0010_0010

        // PC  4: RET
        p_mem[4] = 16'hF000;   // 1111_0000_0000_0000

        // ──────────────────────────────────────────────────
        //  Reset and configure
        // ──────────────────────────────────────────────────
        reset = 1;
        start = 0;
        device_control_write_enable = 0;
        device_control_data = 0;

        #100 reset = 0;
        #50;

        // Set thread count to 4 (4 threads, 1 warp)
        device_control_write_enable = 1;
        device_control_data = 8'd4;
        #50 device_control_write_enable = 0;
        #50;

        // Launch kernel
        start = 1;
        #50 start = 0;

        // Wait for done or timeout (10,000 ns = 1000 cycles)
        fork
            begin
                wait(done == 1'b1);
                $display("[%0t] TESTBENCH: DONE asserted.", $time);
            end
            begin
                #10000;
                $display("[%0t] TESTBENCH: ERROR – Timeout waiting for DONE!", $time);
                $finish;
            end
        join_any

        // ──────────────────────────────────────────────────
        //  Verify results
        // ──────────────────────────────────────────────────
        $display("===================================================");
        $display("  VERIFICATION");
        $display("===================================================");

        if (d_mem[230] == 16'd123)
            $display("d_mem[230] = %0d [PASS]", d_mem[230]);
        else
            $display("d_mem[230] = %0d, EXPECTED 123 [FAIL]", d_mem[230]);

        if (d_mem[225] == 16'd123)
            $display("d_mem[225] remains %0d [PASS]", d_mem[225]);
        else
            $display("d_mem[225] = %0d, EXPECTED 123 [FAIL]", d_mem[225]);

        #20 $finish;
    end
endmodule