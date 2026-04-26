`default_nettype none
`timescale 1ns/1ns

module tb_phase1;

    // Parameters
    localparam DATA_MEM_ADDR_BITS = 8;
    localparam DATA_MEM_DATA_BITS = 16;
    localparam DATA_MEM_NUM_CHANNELS = 4;
    localparam PROGRAM_MEM_ADDR_BITS = 8;
    localparam PROGRAM_MEM_DATA_BITS = 16;
    localparam PROGRAM_MEM_NUM_CHANNELS = 1;
    localparam NUM_CORES = 1; // Only need 1 core to test divergence
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
        $display("   STARTING SIMT BRANCH DIVERGENCE TEST           ");
        $display("==================================================");

        for (int i = 0; i < 256; i++) d_mem[i] = 0;

        // T0 & T1 -> Jump to 10, set R2 = 10
        // T2 & T3 -> Fallthrough to 3, set R2 = 20
        
        p_mem[0]  = 16'h9102; // CONST R1, 2
        p_mem[1]  = 16'h20F1; // CMP R15, R1
        p_mem[2]  = 16'h120A; // BRn 10 (If < 2, jump to PC 10)
        
        // --- FALLTHROUGH PATH (Threads 2 & 3) ---
        p_mem[3]  = 16'h9214; // CONST R2, 20
        p_mem[4]  = 16'h0000; // NOP
        p_mem[5]  = 16'h0000; // NOP
        p_mem[6]  = 16'h0000; // NOP
        p_mem[7]  = 16'h1E0E; // BRnzp 14 (Unconditional Jump to Reconverge at PC 14)
        p_mem[8]  = 16'h0000; // NOP
        p_mem[9]  = 16'h0000; // NOP

        // --- TAKEN PATH (Threads 0 & 1) ---
        p_mem[10]  = 16'h920A; // CONST R2, 10
        p_mem[11]  = 16'h0000; // NOP 
        p_mem[12]  = 16'h0000; // NOP 
        p_mem[13]  = 16'h0000; // NOP 
        
        // --- RECONVERGENCE POINT (All Threads) ---
        p_mem[14] = 16'h80F2; // STR x, R15, R2
        p_mem[15] = 16'h0000; // NOP 
        p_mem[16] = 16'hF000; // RET
        
        for (int i = 17; i < 256; i++) p_mem[i] = 16'h0000;

        reset = 1;
        start = 0;
        device_control_write_enable = 0;
        device_control_data = 0;
        program_mem_read_ready = 0;
        data_mem_read_ready = 0;
        data_mem_write_ready = 0;
        
        #100 reset = 0;
        #50;

        device_control_write_enable = 1;
        device_control_data = 4;
        #50 device_control_write_enable = 0;
        #50;

        start = 1;
        #50 start = 0;

        fork
            begin
                wait (done == 1'b1);
                $display("[%0t] [TESTBENCH] Execution Completed!", $time);
            end
            begin
                #10000; // 10,000 ns timeout
                $display("[%0t] [TESTBENCH] ERROR: Timeout waiting for DONE!", $time);
            end
        join_any

        $display("==================================================");
        $display("   VERIFYING DIVERGENCE RESULTS");
        $display("==================================================");
        
        begin
            int expected [4] = '{10, 10, 20, 20};
            for (int i = 0; i < 4; i++) begin
                if (d_mem[i] == expected[i]) begin
                    $display("Thread %0d Output: %0d [PASS]", i, d_mem[i]);
                end else begin
                    $display("Thread %0d Output: %0d ... EXPECTED %0d [FAIL]", i, d_mem[i], expected[i]);
                end
            end
        end
        #20 $finish;
    end
endmodule