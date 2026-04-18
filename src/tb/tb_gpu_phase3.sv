`default_nettype none
`timescale 1ns/1ns

module tb_gpu_phase3;

    // GPU Parameters
    localparam DATA_MEM_ADDR_BITS = 8;
    localparam DATA_MEM_DATA_BITS = 16;
    localparam DATA_MEM_NUM_CHANNELS = 4;
    localparam PROGRAM_MEM_ADDR_BITS = 8;
    localparam PROGRAM_MEM_DATA_BITS = 16;
    localparam PROGRAM_MEM_NUM_CHANNELS = 1;
    localparam NUM_CORES = 2;
    localparam THREADS_PER_BLOCK = 4;

    // Clock and reset
    logic clk;
    logic reset;
    logic start;
    logic done;

    // Device control
    logic device_control_write_enable;
    logic [7:0] device_control_data;

    // Program memory interface
    logic [PROGRAM_MEM_NUM_CHANNELS-1:0] program_mem_read_valid;
    logic [PROGRAM_MEM_ADDR_BITS-1:0] program_mem_read_address [PROGRAM_MEM_NUM_CHANNELS];
    logic [PROGRAM_MEM_NUM_CHANNELS-1:0] program_mem_read_ready;
    logic [PROGRAM_MEM_DATA_BITS-1:0] program_mem_read_data [PROGRAM_MEM_NUM_CHANNELS];

    // Data memory interface (unused but must be connected)
    logic [DATA_MEM_NUM_CHANNELS-1:0] data_mem_read_valid;
    logic [DATA_MEM_ADDR_BITS-1:0] data_mem_read_address [DATA_MEM_NUM_CHANNELS];
    logic [DATA_MEM_NUM_CHANNELS-1:0] data_mem_read_ready;
    logic [DATA_MEM_DATA_BITS-1:0] data_mem_read_data [DATA_MEM_NUM_CHANNELS];
    logic [DATA_MEM_NUM_CHANNELS-1:0] data_mem_write_valid;
    logic [DATA_MEM_ADDR_BITS-1:0] data_mem_write_address [DATA_MEM_NUM_CHANNELS];
    logic [DATA_MEM_DATA_BITS-1:0] data_mem_write_data [DATA_MEM_NUM_CHANNELS];
    logic [DATA_MEM_NUM_CHANNELS-1:0] data_mem_write_ready;

    // Program memory model
    logic [15:0] prog_mem [0:255];

    // Clock generation (10 ns period)
    always #5 clk = ~clk;

    // Instantiate GPU
    gpu #(
        .DATA_MEM_ADDR_BITS(DATA_MEM_ADDR_BITS),
        .DATA_MEM_DATA_BITS(DATA_MEM_DATA_BITS),
        .DATA_MEM_NUM_CHANNELS(DATA_MEM_NUM_CHANNELS),
        .PROGRAM_MEM_ADDR_BITS(PROGRAM_MEM_ADDR_BITS),
        .PROGRAM_MEM_DATA_BITS(PROGRAM_MEM_DATA_BITS),
        .PROGRAM_MEM_NUM_CHANNELS(PROGRAM_MEM_NUM_CHANNELS),
        .NUM_CORES(NUM_CORES),
        .THREADS_PER_BLOCK(THREADS_PER_BLOCK)
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

    // Program memory behavioral model (single channel, zero-wait-state)
    assign program_mem_read_ready = program_mem_read_valid;
    assign program_mem_read_data[0] = prog_mem[program_mem_read_address[0]];

    // Data memory (tie off)
    assign data_mem_read_ready = '0;
    assign data_mem_read_data = '{default: '0};
    assign data_mem_write_ready = '0;

    // Load test program into memory
    task load_program();
        // CONST R1, #5
        prog_mem[0] = 16'h9105;
        // CONST R2, #3
        prog_mem[1] = 16'h9203;
        // ADD R3, R1, R2
        prog_mem[2] = 16'h3312;
        // SUB R4, R3, R1
        prog_mem[3] = 16'h4431;
        // MUL R5, R4, R2
        prog_mem[4] = 16'h5542;
        // NOP
        prog_mem[5] = 16'h0000;
        // NOP
        prog_mem[6] = 16'h0000;
        // RET
        prog_mem[7] = 16'hF000;
        // Fill rest with NOPs
        for (int i = 8; i < 256; i++) begin
            prog_mem[i] = 16'h0000;
        end
    endtask

    // Main test sequence
    initial begin
        clk = 0;
        reset = 1;
        start = 0;
        device_control_write_enable = 0;
        device_control_data = 0;

        load_program();

        // Hold reset for a few cycles
        repeat (5) @(posedge clk);
        reset = 0;
        @(posedge clk);

        // Configure thread count = 4 (all threads active)
        device_control_write_enable = 1;
        device_control_data = 8'd4;
        @(posedge clk);
        device_control_write_enable = 0;

        $display("[%0t] Starting GPU execution", $time);
        start = 1;
        @(posedge clk);
        start = 0;

        // Wait for the global done signal (from dispatch unit)
        wait (done == 1);
        $display("[%0t] GPU top-level done asserted", $time);

        // Allow time for final writebacks
        repeat (10) @(posedge clk);

        $display("========================================");
        $display("Phase 3 Simulation Completed Successfully");
        $display("Check log for register write messages:");
        $display("  R1 = 5, R2 = 3, R3 = 8, R4 = 3, R5 = 9");
        $display("========================================");
        $finish;
    end

    // Timeout watchdog
    initial begin
        #200000; // 2000 ns (200 cycles at 10ns)
        $error("Timeout: GPU did not finish within 2000 ns");
        $finish;
    end

endmodule