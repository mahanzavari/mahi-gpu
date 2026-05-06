`default_nettype none
`timescale 1ns/1ns

module tb_coalescing;

    // Testbench parameters
    localparam DATA_MEM_ADDR_BITS = 8;
    localparam DATA_MEM_DATA_BITS = 16;
    localparam WORDS_PER_BLOCK = 4;
    localparam BLOCK_DATA_BITS = DATA_MEM_DATA_BITS * WORDS_PER_BLOCK; // 64-bit memory bus
    
    localparam DATA_MEM_NUM_CHANNELS = 2;    // 1 Coalescing LSU per Core!
    localparam PROGRAM_MEM_ADDR_BITS = 8;
    localparam PROGRAM_MEM_DATA_BITS = 16;
    localparam PROGRAM_MEM_NUM_CHANNELS = 2; // 2 Cores fetching
    localparam NUM_CORES = 2; 
    localparam THREADS_PER_BLOCK = 8;        
    localparam NUM_WARPS = 2;                // 16 threads per core total

    reg clk;
    reg reset;
    reg start;
    wire done;
    reg device_control_write_enable;
    reg [7:0] device_control_data;

    // Program Memory Ports
    wire [PROGRAM_MEM_NUM_CHANNELS-1:0] program_mem_read_valid;
    wire [PROGRAM_MEM_ADDR_BITS-1:0] program_mem_read_address [PROGRAM_MEM_NUM_CHANNELS];
    reg [PROGRAM_MEM_NUM_CHANNELS-1:0] program_mem_read_ready;
    reg [PROGRAM_MEM_DATA_BITS-1:0] program_mem_read_data [PROGRAM_MEM_NUM_CHANNELS];

    // WIDE Data Memory Ports (64-bit blocks)
    wire [DATA_MEM_NUM_CHANNELS-1:0] data_mem_read_valid;
    wire [DATA_MEM_ADDR_BITS-1:0] data_mem_read_address [DATA_MEM_NUM_CHANNELS];
    reg [DATA_MEM_NUM_CHANNELS-1:0] data_mem_read_ready;
    reg [BLOCK_DATA_BITS-1:0] data_mem_read_data [DATA_MEM_NUM_CHANNELS];
    
    wire [DATA_MEM_NUM_CHANNELS-1:0] data_mem_write_valid;
    wire [DATA_MEM_ADDR_BITS-1:0] data_mem_write_address [DATA_MEM_NUM_CHANNELS];
    wire [BLOCK_DATA_BITS-1:0] data_mem_write_data [DATA_MEM_NUM_CHANNELS];
    wire [3:0] data_mem_write_strobe [DATA_MEM_NUM_CHANNELS];
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
        .data_mem_write_data(data_mem_write_data), .data_mem_write_strobe(data_mem_write_strobe), .data_mem_write_ready(data_mem_write_ready)
    );

    reg [PROGRAM_MEM_DATA_BITS-1:0] p_mem [0:255];
    reg [DATA_MEM_DATA_BITS-1:0]    d_mem [0:255]; // Underlying 16-bit memory array

    // Metrics for Coalescing Verification
    integer total_read_transactions = 0;
    integer total_write_transactions = 0;

    always @(posedge clk) begin
        if (reset) begin
            for (int i = 0; i < DATA_MEM_NUM_CHANNELS; i++) begin
                data_mem_read_ready[i] <= 0;
                data_mem_write_ready[i] <= 0;
            end
        end else begin
            // Program Memory
            for (int i = 0; i < PROGRAM_MEM_NUM_CHANNELS; i++) begin
                program_mem_read_ready[i] <= program_mem_read_valid[i];
                if (program_mem_read_valid[i]) program_mem_read_data[i] <= p_mem[program_mem_read_address[i]];
            end
            
            // WIDE Data Memory (Block-based addressing)
            for (int i = 0; i < DATA_MEM_NUM_CHANNELS; i++) begin
                // --- READ COALESCING MOCK ---
                if (data_mem_read_valid[i] && !data_mem_read_ready[i]) begin
                    int block_addr = data_mem_read_address[i];
                    data_mem_read_ready[i] <= 1;
                    
                    // Pack 4 16-bit words into a 64-bit block
                    data_mem_read_data[i] <= {
                        d_mem[block_addr * 4 + 3], 
                        d_mem[block_addr * 4 + 2], 
                        d_mem[block_addr * 4 + 1], 
                        d_mem[block_addr * 4 + 0]
                    };
                    total_read_transactions++;
                    $display("[%0t] [MEM MOCK] Coalesced READ Block %0d requested by Channel %0d", $time, block_addr, i);
                end else begin
                    data_mem_read_ready[i] <= 0;
                end
                
                // --- WRITE COALESCING MOCK ---
                if (data_mem_write_valid[i] && !data_mem_write_ready[i]) begin
                    int block_addr = data_mem_write_address[i];
                    data_mem_write_ready[i] <= 1;
                    
                    // Apply Write Strobes
                    if (data_mem_write_strobe[i][0]) d_mem[block_addr * 4 + 0] <= data_mem_write_data[i][15:0];
                    if (data_mem_write_strobe[i][1]) d_mem[block_addr * 4 + 1] <= data_mem_write_data[i][31:16];
                    if (data_mem_write_strobe[i][2]) d_mem[block_addr * 4 + 2] <= data_mem_write_data[i][47:32];
                    if (data_mem_write_strobe[i][3]) d_mem[block_addr * 4 + 3] <= data_mem_write_data[i][63:48];
                    
                    total_write_transactions++;
                    $display("[%0t] [MEM MOCK] Coalesced WRITE Block %0d requested by Channel %0d (Strobe: %b)", $time, block_addr, i, data_mem_write_strobe[i]);
                end else begin
                    data_mem_write_ready[i] <= 0;
                end
            end
        end
    end

    initial begin
        clk = 0;
        forever #5 clk = ~clk; 
    end

    initial begin
        $display("=========================================================");
        $display(" PHASE 6: INTRA-WARP MEMORY COALESCING VERIFICATION      ");
        $display("=========================================================");

        for (int i = 0; i < 256; i++) begin
            p_mem[i] = 16'h0000;
            d_mem[i] = 0;
        end

        // Initialize Array A at Addr 0
        for (int i = 0; i < 32; i++) begin
            d_mem[i] = i * 10; // A[i] = 0, 10, 20, 30...
        end

        // ---------------------------------------------------------------------
        // ASSEMBLY PROGRAM: B[tid] = A[tid] + 1
        // (Array A starts at 0, Array B starts at 128)
        // ---------------------------------------------------------------------
        
        // Calc Global TID: R0 = R13 * 16 + R15
        p_mem[0] = 16'h9710; // CONST R7, 16      
        p_mem[1] = 16'h50D7; // MUL R0, R13, R7   
        p_mem[2] = 16'h300F; // ADD R0, R0, R15   
        
        // LDR R1, [R0 + 0] -> Reads A[tid]
        p_mem[3] = 16'h7100; 

        // ADD R1, R1, 1
        p_mem[4] = 16'h9201; // CONST R2, 1
        p_mem[5] = 16'h3112; // ADD R1, R1, R2

        // STR [R3 + 0], R1 -> Writes to B[tid]
        p_mem[6] = 16'h9380; // CONST R3, 128 (0x80)
        p_mem[7] = 16'h3330; // ADD R3, R3, R0
        p_mem[8] = 16'h8031; // STR [R3 + 0], R1
        
        p_mem[9] = 16'hF000; // EXIT

        reset = 1;
        start = 0;
        device_control_write_enable = 0;
        device_control_data = 0;
        
        #100 reset = 0;
        #50;

        device_control_write_enable = 1;
        device_control_data = 32; // Launch exactly 32 threads
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
                #20000; 
                $display("[%0t] [TESTBENCH] ERROR: Timeout waiting for DONE!", $time);
                $finish;
            end
        join_any

        $display("==================================================");
        $display("   VERIFYING RESULTS AND MEMORY METRICS           ");
        $display("==================================================");
        
        begin
            int errors = 0;
            // Verify Vector Add Data
            for (int i = 0; i < 32; i++) begin
                int expected_val = (i * 10) + 1;
                if (d_mem[128 + i] == expected_val) begin
                    $display("Output B[%02d]: %02d [PASS]", i, d_mem[128+i]);
                end else begin
                    $display("Output B[%02d]: %02d ... EXPECTED %02d [FAIL]", i, d_mem[128+i], expected_val);
                    errors++;
                end
            end

            $display("\n==================================================");
            $display("   COALESCING METRICS (CRITICAL)                  ");
            $display("==================================================");
            $display("Threads executed: 32");
            $display("Total Expected memory requests WITHOUT coalescing: 64 (32 reads, 32 writes)");
            $display("Total Expected memory requests WITH coalescing: 16 (8 block reads, 8 block writes)");
            
            $display("ACTUAL Read Transactions: %0d", total_read_transactions);
            $display("ACTUAL Write Transactions: %0d", total_write_transactions);

            if (total_read_transactions == 8 && total_write_transactions == 8) begin
                $display("\nCOALESCING WORKS PERFECTLY! 4x Compression achieved. [PASS]");
            end else begin
                $display("\nCOALESCING FAILED! Transaction counts do not match expected. [FAIL]");
                errors++;
            end

            if (errors == 0) $display("\nALL TESTS PASSED!");
            else $display("\nTEST FAILED WITH %0d ERRORS.", errors);
        end
        #20 $finish;
    end
endmodule