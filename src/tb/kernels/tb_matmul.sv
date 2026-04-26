`default_nettype none
`timescale 1ns/1ns

module tb_matmul;

    // Testbench parameters: 2 Cores, 2 Warps per core, 8 Threads per Warp -> 32 Threads Total
    localparam DATA_MEM_ADDR_BITS = 8;
    localparam DATA_MEM_DATA_BITS = 16;
    localparam DATA_MEM_NUM_CHANNELS = 16; // 2 cores * 8 Active Threads
    localparam PROGRAM_MEM_ADDR_BITS = 8;
    localparam PROGRAM_MEM_DATA_BITS = 16;
    localparam PROGRAM_MEM_NUM_CHANNELS = 2; // 2 Cores fetching
    localparam NUM_CORES = 2; 
    localparam THREADS_PER_BLOCK = 8;        
    localparam NUM_WARPS = 2;                

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

    // Single Cycle Memory Latency
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
        $display("=========================================================");
        $display(" PHASE 5: MATMUL (CALL/RET STACK & DIVERGENT BRANCHES)   ");
        $display("=========================================================");

        for (int i = 0; i < 256; i++) begin
            d_mem[i] = 0;
            p_mem[i] = 16'h0000;
        end

        // ---------------------------------------------------------------------
        // DATA INITIALIZATION (5x5 Matrices)
        // Memory Map:
        //   A: 0-24  (Identity Matrix -> 1 on diagonal, 0 elsewhere)
        //   B: 25-49 (Values 0 to 24 sequentially)
        //   C: 50-74 (Output -> Should be identical to B since A is Identity)
        // ---------------------------------------------------------------------
        d_mem[0] = 1; d_mem[6] = 1; d_mem[12] = 1; d_mem[18] = 1; d_mem[24] = 1; // Identity matrix
        for (int i = 0; i < 25; i++) begin
            d_mem[25 + i] = i; 
        end

        // ---------------------------------------------------------------------
        // ASSEMBLY PROGRAM: 5x5 Matrix Multiplication
        // Launch 32 Threads -> 25 Calculate, 7 Exit immediately (Divergence!)
        // ---------------------------------------------------------------------

        // --- MAIN KERNEL ---
        // Calc Global TID: R0 = R13 * 16 + R15
        p_mem[0]  = 16'h9710; // CONST R7, 16      
        p_mem[1]  = 16'h50D7; // MUL R0, R13, R7   
        p_mem[2]  = 16'h300F; // ADD R0, R0, R15   
        
        // Bounds check: if (R0 < 25) branch to MAIN_BODY, else EXIT
        p_mem[3]  = 16'h9119; // CONST R1, 25      
        p_mem[4]  = 16'h2001; // CMP R0, R1        
        p_mem[5]  = 16'h1807; // BRn 07 (jump over EXIT)
        p_mem[6]  = 16'hF000; // EXIT (Threads 25-31 diverge and terminate here)
        
        // MAIN_BODY: Row = R0 / 5
        p_mem[7]  = 16'h9405; // CONST R4, 5       
        p_mem[8]  = 16'h6204; // DIV R2, R0, R4    
        
        // Col = R0 - Row * 5
        p_mem[9]  = 16'h5324; // MUL R3, R2, R4    
        p_mem[10] = 16'h4303; // SUB R3, R0, R3    

        // Function Call: R5 = DotProduct(Row, Col)
        p_mem[11] = 16'hD010; // CALL 16 (Jump to subroutine)

        // Store Result: C[R0] = R5
        p_mem[12] = 16'h9732; // CONST R7, 50 (Base_C)
        p_mem[13] = 16'h3770; // ADD R7, R7, R0    
        p_mem[14] = 16'h8075; // STR [R7+0], R5    
        p_mem[15] = 16'hF000; // EXIT (Threads 0-24 terminate here)

        // --- SUBROUTINE: DOT_PROD (PC = 16) ---
        p_mem[16] = 16'h9500; // CONST R5, 0 (Accumulator Result = 0)
        p_mem[17] = 16'h9600; // CONST R6, 0 (Loop counter k = 0)

        // LOOP_START (PC = 18): if (k < 5) loop, else RET_FN
        p_mem[18] = 16'h2064; // CMP R6, R4        
        p_mem[19] = 16'h1815; // BRn 21 (Jump to LOOP_BODY)
        p_mem[20] = 16'hE000; // RET_FN (Return to PC 12 via hardware stack)

        // LOOP_BODY (PC = 21)
        // A_addr = Base_A(0) + Row * 5 + k
        p_mem[21] = 16'h5824; // MUL R8, R2, R4    
        p_mem[22] = 16'h3886; // ADD R8, R8, R6    
        
        // B_addr = Base_B(25) + k * 5 + Col
        p_mem[23] = 16'h9719; // CONST R7, 25      
        p_mem[24] = 16'h5964; // MUL R9, R6, R4    
        p_mem[25] = 16'h3997; // ADD R9, R9, R7    
        p_mem[26] = 16'h3993; // ADD R9, R9, R3    

        // Load Values
        p_mem[27] = 16'h7880; // LDR R8, [R8+0]    (A_val)
        p_mem[28] = 16'h7990; // LDR R9, [R9+0]    (B_val)

        // Result += A_val * B_val
        p_mem[29] = 16'h5A89; // MUL R10, R8, R9   
        p_mem[30] = 16'h355A; // ADD R5, R5, R10   

        // k++
        p_mem[31] = 16'h9701; // CONST R7, 1       
        p_mem[32] = 16'h3667; // ADD R6, R6, R7    
        p_mem[33] = 16'h1E12; // BRnzp 18 (Jump back to LOOP_START)

        reset = 1;
        start = 0;
        device_control_write_enable = 0;
        device_control_data = 0;
        
        #100 reset = 0;
        #50;

        device_control_write_enable = 1;
        device_control_data = 32; // Launch exactly 32 threads (2 cores * 1 block * 16 threads)
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
                #100000; 
                $display("[%0t] [TESTBENCH] ERROR: Timeout waiting for DONE! You likely have a divergence deadlock.", $time);
                $finish;
            end
        join_any

        $display("==================================================");
        $display("   VERIFYING 5x5 MATRIX MULTIPLICATION RESULTS    ");
        $display("==================================================");
        
        begin
            int errors = 0;
            // Expected: Since A is an Identity matrix, C = A * B should just equal B
            for (int i = 0; i < 25; i++) begin
                int expected_val = i;
                if (d_mem[50 + i] == expected_val) begin
                    $display("Matrix C Element %02d (Computed by Thread %02d): %02d [PASS]", i, i, d_mem[50+i]);
                end else begin
                    $display("Matrix C Element %02d (Computed by Thread %02d): %02d ... EXPECTED %02d [FAIL]", i, i, d_mem[50+i], expected_val);
                    errors++;
                end
            end

            // Verify memory where the 7 diverged threads would have written (it should be untouched)
            for (int i = 25; i < 32; i++) begin
                if (d_mem[50 + i] == 0) begin
                    $display("Diverged Thread %02d Memory Space Untouched [PASS]", i);
                end else begin
                    $display("Diverged Thread %02d Unexpectedly modified memory to %0d [FAIL]", i, d_mem[50+i]);
                    errors++;
                end
            end

            if (errors == 0) $display("\nMATMUL DIVERGENCE AND CALL/RET STACK TESTS PASSED!");
            else $display("\nTEST FAILED WITH %0d ERRORS.", errors);
        end
        #20 $finish;
    end
endmodule