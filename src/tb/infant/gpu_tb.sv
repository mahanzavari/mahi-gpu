`default_nettype none
`timescale 1ns/1ns

module gpu_tb;
    // Parameters
    localparam DATA_MEM_ADDR_BITS       = 8;
    localparam DATA_MEM_DATA_BITS       = 16;
    localparam DATA_MEM_NUM_CHANNELS    = 4;
    localparam PROGRAM_MEM_ADDR_BITS    = 8;
    localparam PROGRAM_MEM_DATA_BITS    = 16;
    localparam PROGRAM_MEM_NUM_CHANNELS = 1;
    localparam NUM_CORES                = 2;
    localparam THREADS_PER_BLOCK        = 4;
    localparam NUM_THREADS              = 8; // 2 blocks x 4 threads

    // Clock & control
    reg clk, reset, start;
    wire done;

    // DCR
    reg        device_control_write_enable;
    reg  [7:0] device_control_data;

    // Program memory (single channel)
    wire [PROGRAM_MEM_NUM_CHANNELS-1:0]                          program_mem_read_valid;
    wire [PROGRAM_MEM_ADDR_BITS-1:0] program_mem_read_address    [PROGRAM_MEM_NUM_CHANNELS-1:0];
    reg  [PROGRAM_MEM_NUM_CHANNELS-1:0]                          program_mem_read_ready;
    reg  [PROGRAM_MEM_DATA_BITS-1:0] program_mem_read_data       [PROGRAM_MEM_NUM_CHANNELS-1:0];

    // Data memory (4 channels)
    wire [DATA_MEM_NUM_CHANNELS-1:0]                             data_mem_read_valid;
    wire [DATA_MEM_ADDR_BITS-1:0]    data_mem_read_address       [DATA_MEM_NUM_CHANNELS-1:0];
    reg  [DATA_MEM_NUM_CHANNELS-1:0]                             data_mem_read_ready;
    reg  [DATA_MEM_DATA_BITS-1:0]    data_mem_read_data          [DATA_MEM_NUM_CHANNELS-1:0];
    wire [DATA_MEM_NUM_CHANNELS-1:0]                             data_mem_write_valid;
    wire [DATA_MEM_ADDR_BITS-1:0]    data_mem_write_address      [DATA_MEM_NUM_CHANNELS-1:0];
    wire [DATA_MEM_DATA_BITS-1:0]    data_mem_write_data         [DATA_MEM_NUM_CHANNELS-1:0];
    reg  [DATA_MEM_NUM_CHANNELS-1:0]                             data_mem_write_ready;

    // -----------------------------------------------------------------------
    // Memory models
    // -----------------------------------------------------------------------
    // Program memory: 16 locations
    reg [PROGRAM_MEM_DATA_BITS-1:0] prog_mem [0:255];

    // Data memory layout:
    //   [0..7]   = A[0..7]  (input)
    //   [8..15]  = B[0..7]  (input)
    //   [16..23] = C[0..7]  (output, A+B)
    reg [DATA_MEM_DATA_BITS-1:0] data_mem [0:255];

    // -----------------------------------------------------------------------
    // DUT
    // -----------------------------------------------------------------------
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

    // -----------------------------------------------------------------------
    // Clock
    // -----------------------------------------------------------------------
    initial clk = 0;
    always #5 clk = ~clk;

    // -----------------------------------------------------------------------
    // Program memory response (1-cycle latency)
    // -----------------------------------------------------------------------
    always @(posedge clk) begin
        program_mem_read_ready[0] <= 0;
        program_mem_read_data[0]  <= 0;
        if (program_mem_read_valid[0]) begin
            program_mem_read_ready[0] <= 1;
            program_mem_read_data[0]  <= prog_mem[program_mem_read_address[0]];
        end
    end

    // -----------------------------------------------------------------------
    // Data memory response (2-cycle latency to be more realistic)
    // -----------------------------------------------------------------------
    reg [DATA_MEM_NUM_CHANNELS-1:0] data_read_valid_d1;
    reg [DATA_MEM_ADDR_BITS-1:0]    data_read_addr_d1  [DATA_MEM_NUM_CHANNELS-1:0];
    reg [DATA_MEM_NUM_CHANNELS-1:0] data_write_valid_d1;
    reg [DATA_MEM_ADDR_BITS-1:0]    data_write_addr_d1 [DATA_MEM_NUM_CHANNELS-1:0];
    reg [DATA_MEM_DATA_BITS-1:0]    data_write_data_d1 [DATA_MEM_NUM_CHANNELS-1:0];

        integer ch;
    always @(posedge clk) begin
        for (ch = 0; ch < DATA_MEM_NUM_CHANNELS; ch = ch + 1) begin
            data_mem_read_ready[ch]  <= 0;
            data_mem_write_ready[ch] <= 0;
            
            // 1-Cycle Read
            if (data_mem_read_valid[ch]) begin
                data_mem_read_data[ch]  <= data_mem[data_mem_read_address[ch]];
                data_mem_read_ready[ch] <= 1;
            end else data_mem_read_ready[ch] <= 0;
            
            // 1-Cycle Write
            if (data_mem_write_valid[ch] && !data_mem_write_ready[ch]) begin
                data_mem[data_mem_write_address[ch]] <= data_mem_write_data[ch];
                data_mem_write_ready[ch]             <= 1;
                $display("MEM_WRITE ch=%0d addr=%0d data=%0d @ %0t", 
                         ch, data_mem_write_address[ch], data_mem_write_data[ch], $time);
            end else data_mem_write_ready[ch] <= 0;
        end
    end
    // -----------------------------------------------------------------------
    // Instruction encoding helpers
    // -----------------------------------------------------------------------
    // Instruction format [15:12]=opcode [11:8]=rd [7:4]=rs [3:0]=rt
    // Immediate format   [15:12]=opcode [11:8]=rd [7:0]=imm8
    // BRnzp format       [15:12]=opcode [11:9]=nzp [7:0]=imm8

    function automatic [15:0] enc_const;
        input [3:0] rd;
        input [7:0] imm;
        enc_const = {4'b1001, rd, imm};
    endfunction

    function automatic [15:0] enc_add;
        input [3:0] rd, rs, rt;
        enc_add = {4'b0011, rd, rs, rt};
    endfunction

    function automatic [15:0] enc_ldr;
        input [3:0] rd, rs;
        enc_ldr = {4'b0111, rd, rs, 4'b0000};
    endfunction

    function automatic [15:0] enc_str;
        input [3:0] rs, rt; // rs=addr reg, rt=data reg
        // [15:12]=opcode (1000), [11:8]=rd (unused, 0), [7:4]=rs (addr), [3:0]=rt (data)
        enc_str = {4'b1000, 4'b0000, rs, rt}; 
    endfunction


    function automatic [15:0] enc_ret;
        enc_ret = {4'b1111, 12'b0};
    endfunction

    function automatic [15:0] enc_mul;
        input [3:0] rd, rs, rt;
        enc_mul = {4'b0101, rd, rs, rt};
    endfunction

    function automatic [15:0] enc_sub;
        input [3:0] rd, rs, rt;
        enc_sub = {4'b0100, rd, rs, rt};
    endfunction

    // -----------------------------------------------------------------------
    // Register aliases (for readability)
    // r0..r12 = general purpose
    // r13 = block_id (read-only)
    // r14 = threads_per_block (read-only)
    // r15 = thread_id (read-only)
    // -----------------------------------------------------------------------
    localparam R0=4'd0, R1=4'd1, R2=4'd2, R3=4'd3, R4=4'd4,
               R5=4'd5, R6=4'd6, R7=4'd7,
               BID=4'd13, TPB=4'd14, TID=4'd15;

    // -----------------------------------------------------------------------
    // Load program: vector add  C[i] = A[i] + B[i]
    //
    // Layout: A @ base 0, B @ base 8, C @ base 16
    // Each thread handles one element: global_id = block_id*4 + thread_id
    //
    // Assembly:
    //   r0 = thread_id                    (r15, already set)
    //   r1 = block_id * threads_per_block (r13 * r14)
    //   r2 = r1 + r0                      global index
    //   r3 = r2 + 0                       addr of A[i]  (base=0)
    //   r4 = LDR r3                       load A[i]
    //   r5 = r2 + 8                       addr of B[i]  (base=8)
    //   r6 = LDR r5                       load B[i]
    //   r7 = r4 + r6                      A[i]+B[i]
    //   r3 = r2 + 16                      addr of C[i]  (base=16)
    //   STR r3, r7                        store result
    //   RET
    // -----------------------------------------------------------------------
    task load_vector_add_program;
        integer pc;
        begin
            pc = 0;
            // r1 = block_id * threads_per_block
            prog_mem[pc] = enc_mul(R1, BID, TPB);       pc = pc + 1;
            // r2 = r1 + thread_id
            prog_mem[pc] = enc_add(R2, R1, TID);        pc = pc + 1;
            // r3 = r2 + 0  (A base = 0, just copy r2)
            prog_mem[pc] = enc_const(R0, 8'd0);         pc = pc + 1; // r0 = 0
            prog_mem[pc] = enc_add(R3, R2, R0);         pc = pc + 1; // r3 = global_id
            // r4 = mem[r3]  (load A[i])
            prog_mem[pc] = enc_ldr(R4, R3);             pc = pc + 1;
            // r5 = r2 + 8  (B base)
            prog_mem[pc] = enc_const(R0, 8'd8);         pc = pc + 1;
            prog_mem[pc] = enc_add(R5, R2, R0);         pc = pc + 1; // r5 = global_id+8
            // r6 = mem[r5]  (load B[i])
            prog_mem[pc] = enc_ldr(R6, R5);             pc = pc + 1;
            // r7 = r4 + r6
            prog_mem[pc] = enc_add(R7, R4, R6);         pc = pc + 1;
            // r3 = r2 + 16  (C base)
            prog_mem[pc] = enc_const(R0, 8'd16);        pc = pc + 1;
            prog_mem[pc] = enc_add(R3, R2, R0);         pc = pc + 1; // r3 = global_id+16
            // STR r3, r7
            prog_mem[pc] = enc_str(R3, R7);             pc = pc + 1;
            // RET
            prog_mem[pc] = enc_ret();                   pc = pc + 1;
        end
    endtask

    // -----------------------------------------------------------------------
    // Initialize data memory: A[i]=i+1, B[i]=i*2
    // -----------------------------------------------------------------------
    task init_data_memory;
        integer i;
        begin
            for (i = 0; i < 256; i = i + 1)
                data_mem[i] = 0;
            for (i = 0; i < NUM_THREADS; i = i + 1) begin
                data_mem[i]      = i + 1;      // A[i]
                data_mem[i + 8]  = i * 2;      // B[i]
            end
        end
    endtask

    // -----------------------------------------------------------------------
    // Result checker
    // -----------------------------------------------------------------------
    task check_results;
        integer i;
        reg [DATA_MEM_DATA_BITS-1:0] expected;
        reg failed;
        begin
            failed = 0;
            $display("\n--- Result Check ---");
            for (i = 0; i < NUM_THREADS; i = i + 1) begin
                expected = (i + 1) + (i * 2); // A[i] + B[i]
                if (data_mem[i + 16] !== expected) begin
                    $display("FAIL C[%0d]: got %0d, expected %0d", i, data_mem[i+16], expected);
                    failed = 1;
                end else begin
                    $display("PASS C[%0d] = %0d", i, data_mem[i+16]);
                end
            end
            if (!failed)
                $display("All %0d results correct.", NUM_THREADS);
        end
    endtask

    // -----------------------------------------------------------------------
    // Main test sequence
    // -----------------------------------------------------------------------
    integer timeout;

    initial begin
        // Init signals
        reset                      = 1;
        start                      = 0;
        device_control_write_enable = 0;
        device_control_data        = 0;
        program_mem_read_ready[0]  = 0;
        program_mem_read_data[0]   = 0;
        for (ch = 0; ch < DATA_MEM_NUM_CHANNELS; ch = ch + 1) begin
            data_mem_read_ready[ch]  = 0;
            data_mem_write_ready[ch] = 0;
            data_mem_read_data[ch]   = 0;
        end
        for (integer j = 0; j < 256; j = j + 1)
            prog_mem[j] = 16'h0000;
        // Load memories
        load_vector_add_program();
        init_data_memory();

        // Reset for 4 cycles
        repeat(4) @(posedge clk);
        reset = 0;
        @(posedge clk);

        // Write thread count to DCR
        $display("Writing thread_count=%0d to DCR", NUM_THREADS);
        device_control_write_enable = 1;
        device_control_data         = NUM_THREADS;
        @(posedge clk);
        device_control_write_enable = 0;
        @(posedge clk);

        // Kick off execution
        $display("Starting GPU execution...");
        start = 1;

        // Wait for done with timeout
        timeout = 0;
        while (!done && timeout < 5000) begin
            @(posedge clk);
            timeout = timeout + 1;
        end

        if (!done) begin
            $display("TIMEOUT: GPU did not complete within %0d cycles", timeout);
        end else begin
            $display("GPU done after ~%0d cycles", timeout);
            // Give one extra cycle for last write to settle
            @(posedge clk);
            check_results();
        end
        for (int i = 0; i < 16; i++) begin
            $display("mem[%0d] = %0d", i, data_mem[i]);
        end
        // Dump A, B, and C regions
        $display("\n--- Memory Dump ---");
        for (int i = 0; i < 24; i++) begin
            $display("mem[%0d] = %0d", i, data_mem[i]);
        end
        

        $display("\n--- Simulation complete ---");
        $finish;
    end

    // -----------------------------------------------------------------------
    // Waveform dump
    // -----------------------------------------------------------------------
    initial begin
        $dumpfile("gpu_tb.vcd");
        $dumpvars(0, gpu_tb);
    end

endmodule
