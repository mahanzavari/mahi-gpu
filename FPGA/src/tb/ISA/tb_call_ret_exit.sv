`default_nettype none
`timescale 1ns/1ns

module tb_call_ret_exit;

    // Testbench parameters
    localparam DATA_MEM_ADDR_BITS = 8;
    localparam DATA_MEM_DATA_BITS = 16;
    localparam DATA_MEM_NUM_CHANNELS = 16; 
    localparam PROGRAM_MEM_ADDR_BITS = 8;
    localparam PROGRAM_MEM_DATA_BITS = 16;
    localparam PROGRAM_MEM_NUM_CHANNELS = 2; 
    localparam NUM_CORES = 2; 
    localparam THREADS_PER_BLOCK = 8;        
    localparam NUM_WARPS = 2;                // 16 threads per core total

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
        .NUM_CORES(NUM_CORES), .THREADS_PER_BLOCK(THREADS_PER_BLOCK), .NUM_WARPS(NUM_WARPS)
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

    // Fast Memory Access Mock
    always @(posedge clk) begin
        for (int i = 0; i < PROGRAM_MEM_NUM_CHANNELS; i++) begin
            program_mem_read_ready[i] <= program_mem_read_valid[i];
            if (program_mem_read_valid[i]) program_mem_read_data[i] <= p_mem[program_mem_read_address[i]];
        end
        
        for (int i = 0; i < DATA_MEM_NUM_CHANNELS; i++) begin
            data_mem_read_ready[i] <= data_mem_read_valid[i];
            if (data_mem_read_valid[i]) data_mem_read_data[i] <= d_mem[data_mem_read_address[i]];
            
            data_mem_write_ready[i] <= data_mem_write_valid[i];
            if (data_mem_write_valid[i]) d_mem[data_mem_write_address[i]] <= data_mem_write_data[i];
        end
    end

    initial begin
        clk = 0;
        forever #5 clk = ~clk; 
    end

    initial begin
        $display("==================================================");
        $display("   TESTING: CALL, RET_FN, AND EXIT                ");
        $display("==================================================");

        for (int i = 0; i < 256; i++) begin
            d_mem[i] = 0;
            p_mem[i] = 16'h0000;
        end
        
        // ---------------------------------------------------------------------
        // ASSEMBLY PROGRAM: Test nested calls & thread exit
        // R13 = Block ID
        // R15 = Local Thread ID
        // ---------------------------------------------------------------------
        
        // Main Execution
        p_mem[0] = 16'h9200; // CONST R2, 0
        p_mem[1] = 16'h31F2; // ADD R1, R15, R2     (R1 = Thread ID)
        p_mem[2] = 16'hD014; // CALL 20             (Call Func_A at PC=20)
        
        // Return from Func_A (R1 should now be Thread ID * 4)
        p_mem[3] = 16'h9410; // CONST R4, 16
        p_mem[4] = 16'h54D4; // MUL R4, R13, R4     (R4 = BlockID * 16)
        p_mem[5] = 16'h344F; // ADD R4, R4, R15     (R4 = Global Thread ID)
        p_mem[6] = 16'h8041; // STR [R4+0], R1      (Store Result)
        
        p_mem[7] = 16'hF000; // EXIT                (Terminate Thread)

        // Func_A (PC = 20)
        p_mem[20] = 16'h3111; // ADD R1, R1, R1     (R1 = R1 * 2)
        p_mem[21] = 16'hD01E; // CALL 30            (Nested Call Func_B at PC=30)
        p_mem[22] = 16'hE000; // RET_FN             (Return to Main)

        // Func_B (PC = 30)
        p_mem[30] = 16'h3111; // ADD R1, R1, R1     (R1 = R1 * 2)
        p_mem[31] = 16'hE000; // RET_FN             (Return to Func_A)

        reset = 1;
        start = 0;
        device_control_write_enable = 0;
        device_control_data = 0;
        
        #100 reset = 0;
        #50;

        device_control_write_enable = 1;
        device_control_data = 32; // 32 Threads Total (2 Blocks of 16 Threads)
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
                #10000; 
                $display("[%0t] [TESTBENCH] ERROR: Timeout waiting for DONE!", $time);
                $finish;
            end
        join_any

        $display("==================================================");
        $display("   VERIFYING NESTED CALL RESULTS ");
        $display("==================================================");
        
        begin
            int errors = 0;
            // Expected: Each thread's local Thread ID * 4
            for (int i = 0; i < 32; i++) begin
                int expected_val = (i % 16) * 4;
                if (d_mem[i] == expected_val) begin
                    $display("Global Thread %02d Output: %02d [PASS]", i, d_mem[i]);
                end else begin
                    $display("Global Thread %02d Output: %02d ... EXPECTED %02d [FAIL]", i, d_mem[i], expected_val);
                    errors++;
                end
            end
            if (errors == 0) $display("\nALL NESTED CALL AND RET/EXIT TESTS PASSED!");
            else $display("\nTEST FAILED WITH %0d ERRORS.", errors);
        end
        #20 $finish;
    end
endmodule