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
        $display("   STARTING PIPELINED GPU VECTOR ADDITION TEST");
        $display("==================================================");

        // Initialize Data Memory
        for (int i = 0; i < 8; i++) begin
            d_mem[i]    = i * 10;    // A = {0, 10, 20, 30, 40, 50, 60, 70}
            d_mem[i+8]  = i * 2;     // B = {0, 2,  4,  6,  8,  10, 12, 14}
            d_mem[i+16] = 0;         // C = (Output)
        end

        // Initialize Program Memory
        p_mem[0]  = 16'h50DE; // MUL R0, R13, R14   (R0 = blockIdx * blockDim)
        p_mem[1]  = 16'h0000; // NOP
        p_mem[2]  = 16'h0000; // NOP
        p_mem[3]  = 16'h0000; // NOP
        p_mem[4]  = 16'h300F; // ADD R0, R0, R15    (R0 = global_id)
        p_mem[5]  = 16'h0000; // NOP
        p_mem[6]  = 16'h0000; // NOP
        p_mem[7]  = 16'h0000; // NOP
        
        p_mem[8]  = 16'h9100; // CONST R1, 0        (R1 = Base addr of A)
        p_mem[9]  = 16'h9308; // CONST R3, 8        (R3 = Base addr of B)
        p_mem[10] = 16'h9610; // CONST R6, 16       (R6 = Base addr of C)
        p_mem[11]  = 16'h0000; // NOP
        p_mem[12]  = 16'h0000; // NOP
        p_mem[13]  = 16'h0000; // NOP
        
        p_mem[14] = 16'h3110; // ADD R1, R1, R0     (R1 = Addr of A[global_id])
        p_mem[15] = 16'h3330; // ADD R3, R3, R0     (R3 = Addr of B[global_id])
        p_mem[16] = 16'h3660; // ADD R6, R6, R0     (R6 = Addr of C[global_id])
        p_mem[17] = 16'h0000; // NOP
        p_mem[18] = 16'h0000; // NOP
        p_mem[19] = 16'h0000; // NOP
        
        p_mem[20] = 16'h7210; // LDR R2, R1, x      (R2 = Mem[R1] -> A[global_id])
        p_mem[21] = 16'h7430; // LDR R4, R3, x      (R4 = Mem[R3] -> B[global_id])
        p_mem[22] = 16'h0000; // NOP
        p_mem[23] = 16'h0000; // NOP
        p_mem[24] = 16'h0000; // NOP
        
        p_mem[25] = 16'h3524; // ADD R5, R2, R4     (R5 = A + B)
        p_mem[26] = 16'h0000; // NOP
        p_mem[27] = 16'h0000; // NOP
        p_mem[28] = 16'h0000; // NOP
        
        p_mem[29] = 16'h8065; // STR x, R6, R5      (Mem[R6] = R5 -> C[global_id])
        p_mem[30] = 16'h0000; // NOP
        p_mem[31] = 16'h0000; // NOP
        p_mem[32] = 16'h0000; // NOP
        
        p_mem[33] = 16'hF000; // RET                (End Thread)
        
        // Ensure remaining memory is NOPs
        for (int i = 34; i < 256; i++) p_mem[i] = 16'h0000;

        start = 0;
        device_control_write_enable = 0;
        device_control_data = 0;
        reset = 1;
        program_mem_read_ready = 0;
        data_mem_read_ready = 0;
        data_mem_write_ready = 0;
        
        #20 reset = 0;
        #10;

        device_control_write_enable = 1;
        device_control_data = 8; // 8 threads (2 blocks)
        #10 device_control_write_enable = 0;

        start = 1;
        #10 start = 0;

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
        $display("   VERIFYING RESULTS (C = A + B)");
        $display("==================================================");
        
        for (int i = 0; i < 8; i++) begin
            int expected = (i * 10) + (i * 2);
            if (d_mem[i + 16] == expected) begin
                $display("Index %0d: A(%0d) + B(%0d) = C(%0d) [PASS]", i, i*10, i*2, d_mem[i + 16]);
            end else begin
                $display("Index %0d: A(%0d) + B(%0d) = C(%0d) ... EXPECTED %0d [FAIL]", i, i*10, i*2, d_mem[i + 16], expected);
            end
        end
        #20 $finish;
    end
endmodule