`default_nettype none
`timescale 1ns/1ns

module tb_gpu_pipelined;

    // Parameters
    localparam DATA_MEM_ADDR_BITS = 8;
    localparam DATA_MEM_DATA_BITS = 16;
    localparam DATA_MEM_NUM_CHANNELS = 4;
    localparam PROGRAM_MEM_ADDR_BITS = 8;
    localparam PROGRAM_MEM_DATA_BITS = 16;
    localparam PROGRAM_MEM_NUM_CHANNELS = 1;
    localparam NUM_CORES = 2;
    localparam THREADS_PER_BLOCK = 4;

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

    gpu #(
        .DATA_MEM_ADDR_BITS(DATA_MEM_ADDR_BITS), .DATA_MEM_DATA_BITS(DATA_MEM_DATA_BITS),
        .DATA_MEM_NUM_CHANNELS(DATA_MEM_NUM_CHANNELS), .PROGRAM_MEM_ADDR_BITS(PROGRAM_MEM_ADDR_BITS),
        .PROGRAM_MEM_DATA_BITS(PROGRAM_MEM_DATA_BITS), .PROGRAM_MEM_NUM_CHANNELS(PROGRAM_MEM_NUM_CHANNELS),
        .NUM_CORES(NUM_CORES), .THREADS_PER_BLOCK(THREADS_PER_BLOCK)
    ) dut (
        .clk(clk), .reset(reset), .start(start), .done(done),
        .device_control_write_enable(device_control_write_enable),
        .device_control_data(device_control_data),
        
        .program_mem_read_valid(program_mem_read_valid), .program_mem_read_address(program_mem_read_address),
        .program_mem_read_ready(program_mem_read_ready), .program_mem_read_data(program_mem_read_data),
        
        .data_mem_read_valid(data_mem_read_valid), .data_mem_read_address(data_mem_read_address),
        .data_mem_read_ready(data_mem_read_ready), .data_mem_read_data(data_mem_read_data),
        
        .data_mem_write_valid(data_mem_write_valid), .data_mem_write_address(data_mem_write_address),
        .data_mem_write_data(data_mem_write_data), .data_mem_write_ready(data_mem_write_ready)
    );

    reg [PROGRAM_MEM_DATA_BITS-1:0] p_mem [0:255];
    reg [DATA_MEM_DATA_BITS-1:0]    d_mem [0:255];

    // Mock External Memory
    always @(posedge clk) begin
        for (int i = 0; i < PROGRAM_MEM_NUM_CHANNELS; i++) begin
            program_mem_read_ready[i] <= program_mem_read_valid[i];
            if (program_mem_read_valid[i]) program_mem_read_data[i] <= p_mem[program_mem_read_address[i]];
        end
        for (int i = 0; i < DATA_MEM_NUM_CHANNELS; i++) begin
            data_mem_read_ready[i] <= data_mem_read_valid[i];
            if (data_mem_read_valid[i]) data_mem_read_data[i] <= d_mem[data_mem_read_address[i]];
            
            data_mem_write_ready[i] <= data_mem_write_valid[i];
            if (data_mem_write_valid[i]) begin
                d_mem[data_mem_write_address[i]] <= data_mem_write_data[i];
            end
        end
    end
    initial begin
        clk = 0;
        forever #5 clk = ~clk; 
    end
    initial begin
        $display("==================================================");
        $display("   STARTING PIPELINED 2x2 MATRIX MULTIPLICATION   ");
        $display("==================================================");

        // 1. Initialize Data Memory
        // Matrix A (2x2) stored at indices 0-3
        d_mem[0] = 1; d_mem[1] = 2; 
        d_mem[2] = 3; d_mem[3] = 4;
        
        // Matrix B (2x2) stored at indices 4-7
        d_mem[4] = 5; d_mem[5] = 6; 
        d_mem[6] = 7; d_mem[7] = 8;
        
        // Matrix C (Output) stored at indices 8-11
        for (int i = 8; i < 256; i++) d_mem[i] = 0;

        // 2. Initialize Program Memory
        p_mem[0]  = 16'h9C00; // CONST R12, 0       (Use R12 as constant 0 for memory offsets)

        // Calculate global ID: R0 = (blockIdx * blockDim) + threadIdx
        p_mem[1]  = 16'h50DE; // MUL R0, R13, R14   
        p_mem[2]  = 16'h300F; // ADD R0, R0, R15    

        // Calculate row and col for this thread's output
        p_mem[3]  = 16'h9102; // CONST R1, 2        (Matrix dimension N=2)
        p_mem[4]  = 16'h6201; // DIV R2, R0, R1     (R2 = row = global_id / 2)
        p_mem[5]  = 16'h5321; // MUL R3, R2, R1     (R3 = row * 2)
        p_mem[6]  = 16'h4403; // SUB R4, R0, R3     (R4 = col = global_id - row * 2)

        // Load A[row, 0]
        p_mem[7]  = 16'h9500; // CONST R5, 0        (A base address)
        p_mem[8]  = 16'h3553; // ADD R5, R5, R3     (R5 = A base + row*2)
        p_mem[9]  = 16'h765C; // LDR R6, R5, R12    (R6 = MEM[R5 + 0])

        // Load A[row, 1]
        p_mem[10] = 16'h9701; // CONST R7, 1        
        p_mem[11] = 16'h3757; // ADD R7, R5, R7     (R7 = A base + row*2 + 1)
        p_mem[12] = 16'h787C; // LDR R8, R7, R12    (R8 = MEM[R7 + 0])

        // Load B[0, col]
        p_mem[13] = 16'h9904; // CONST R9, 4        (B base address)
        p_mem[14] = 16'h3994; // ADD R9, R9, R4     (R9 = B base + col)
        p_mem[15] = 16'h7A9C; // LDR R10, R9, R12   (R10 = MEM[R9 + 0])

        // Load B[1, col]
        p_mem[16] = 16'h9B06; // CONST R11, 6       (B row 1 base: 4 + 1*2 = 6)
        p_mem[17] = 16'h3BB4; // ADD R11, R11, R4   (R11 = B row 1 base + col)
        p_mem[18] = 16'h71BC; // LDR R1, R11, R12   (R1 = MEM[R11 + 0] -> Overwrites R1)

        // Multiply and Accumulate (Dot Product)
        p_mem[19] = 16'h566A; // MUL R6, R6, R10    (R6 = A[row, 0] * B[0, col])
        p_mem[20] = 16'h5881; // MUL R8, R8, R1     (R8 = A[row, 1] * B[1, col])
        p_mem[21] = 16'h3668; // ADD R6, R6, R8     (R6 = Sum)

        // Store Result to C[global_id]
        p_mem[22] = 16'h9708; // CONST R7, 8        (C base address)
        p_mem[23] = 16'h3770; // ADD R7, R7, R0     (R7 = C base + global_id)
        p_mem[24] = 16'h8076; // STR x, R7, R6      (MEM[R7] = R6)
        
        p_mem[25] = 16'hF000; // RET
        
        for (int i = 26; i < 256; i++) p_mem[i] = 16'h0000;

        // Ensure signals are stabilized and wait for multiple clocks
        reset = 1;
        start = 0;
        device_control_write_enable = 0;
        device_control_data = 0;
        program_mem_read_ready = 0;
        data_mem_read_ready = 0;
        data_mem_write_ready = 0;
        
        #100 reset = 0;
        #50;

        $display("[%0t] [TESTBENCH] Loading DCR with 4 threads...", $time);
        device_control_write_enable = 1;
        device_control_data = 4;
        #50 device_control_write_enable = 0;
        #50;

        $display("[%0t] [TESTBENCH] Sending START pulse...", $time);
        start = 1;
        #50 start = 0;

        fork
            begin
                wait (done == 1'b1);
                $display("[%0t] [TESTBENCH] Execution Completed!", $time);
            end
            begin
                #50000; // 50,000 ns timeout
                $display("[%0t] [TESTBENCH] ERROR: Timeout waiting for DONE!", $time);
            end
        join_any

        $display("==================================================");
        $display("   VERIFYING RESULTS (C = A x B)");
        $display("==================================================");
        
        // Expected values: 19, 22, 43, 50
        begin
            int expected [4] = '{19, 22, 43, 50};
            for (int i = 0; i < 4; i++) begin
                if (d_mem[i + 8] == expected[i]) begin
                    $display("Index C[%0d]: %0d [PASS]", i, d_mem[i + 8]);
                end else begin
                    $display("Index C[%0d]: %0d ... EXPECTED %0d [FAIL]", i, d_mem[i + 8], expected[i]);
                end
            end
        end
        #20 $finish;
    end
endmodule