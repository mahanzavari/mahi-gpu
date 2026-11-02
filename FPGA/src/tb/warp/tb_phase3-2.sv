`default_nettype none
`timescale 1ns/1ns

module tb_phase4;

    // Parameters
    localparam DATA_MEM_ADDR_BITS = 8;
    localparam DATA_MEM_DATA_BITS = 16;
    localparam DATA_MEM_NUM_CHANNELS = 8; // Increased to 8 to handle concurrent requests from 2 cores
    localparam PROGRAM_MEM_ADDR_BITS = 8;
    localparam PROGRAM_MEM_DATA_BITS = 16;
    localparam PROGRAM_MEM_NUM_CHANNELS = 2; // 2 Cores fetching simultaneously
    localparam NUM_CORES = 2; 
    localparam THREADS_PER_BLOCK = 4;
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

    // Mock External Memory (With 5 Cycle Read Latency for Data Memory!)
    reg [4:0] dmem_read_delay [DATA_MEM_NUM_CHANNELS];
    reg [DATA_MEM_ADDR_BITS-1:0] latched_read_addr [DATA_MEM_NUM_CHANNELS];

    always @(posedge clk) begin
        // Program memory is fast (1 cycle)
        for (int i = 0; i < PROGRAM_MEM_NUM_CHANNELS; i++) begin
            program_mem_read_ready[i] <= program_mem_read_valid[i];
            if (program_mem_read_valid[i]) program_mem_read_data[i] <= p_mem[program_mem_read_address[i]];
        end
        
        // Data memory has a 5 cycle delay for reads to test Latency Hiding
        for (int i = 0; i < DATA_MEM_NUM_CHANNELS; i++) begin
            dmem_read_delay[i] <= {dmem_read_delay[i][3:0], data_mem_read_valid[i]};
            
            if (data_mem_read_valid[i] && !dmem_read_delay[i][0]) begin
                latched_read_addr[i] <= data_mem_read_address[i];
            end
            
            data_mem_read_ready[i] <= dmem_read_delay[i][4]; // Ready after 5 cycles
            if (dmem_read_delay[i][4]) begin
                data_mem_read_data[i] <= d_mem[latched_read_addr[i]];
            end
            
            // Writes are fast
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
        $display("   PHASE 4: MULTI-CORE & 4-WAY DIVERGENCE TEST    ");
        $display("==================================================");

        for (int i = 0; i < 256; i++) begin
            d_mem[i] = 0;
            p_mem[i] = 16'h0000;
        end
        
        d_mem[100] = 42; // The value Warp 0 will load from memory

        // ---------------------------------------------------------------------
        // ASSEMBLY PROGRAM
        // R13 = Block ID
        // R15 = Local Thread ID (0..7)
        // ---------------------------------------------------------------------
        
        // PC 0-2: Split Warps based on ThreadID
        p_mem[0]  = 16'h9104; // CONST R1, 4
        p_mem[1]  = 16'h20F1; // CMP R15, R1   (Is Local ThreadID < 4 ?)
        p_mem[2]  = 16'h1214; // BRn 20        (Warp 0 jumps to PC 20: 0x14)
        
        // --- WARP 1 PATH (ThreadIdx 4, 5, 6, 7) ---
        // Calculate R2 = R15 - 4 (Results in 0, 1, 2, 3 for the four threads)
        p_mem[3]  = 16'h42F1; // SUB R2, R15, R1
        
        // 4-Way Divergence Test
        p_mem[4]  = 16'h9100; // CONST R1, 0
        p_mem[5]  = 16'h2021; // CMP R2, R1
        p_mem[6]  = 16'h141E; // BRz 30 (0x1E) -> Thread 4 jumps
        
        p_mem[7]  = 16'h9101; // CONST R1, 1
        p_mem[8]  = 16'h2021; // CMP R2, R1
        p_mem[9]  = 16'h1428; // BRz 40 (0x28) -> Thread 5 jumps
        
        p_mem[10] = 16'h9102; // CONST R1, 2
        p_mem[11] = 16'h2021; // CMP R2, R1
        p_mem[12] = 16'h1432; // BRz 50 (0x32) -> Thread 6 jumps
        
        p_mem[13] = 16'h1E3C; // BRnzp 60 (0x3C) -> Thread 7 jumps (Fallthrough essentially)

        // --- WARP 0 PATH (Memory Latency Hiding) ---
        p_mem[20] = 16'h9264; // CONST R2, 100
        p_mem[21] = 16'h7320; // LDR R3, R2     (Load from d_mem[100] -> STALLS WARP 0)
        p_mem[22] = 16'h3333; // ADD R3, R3, R3 (R3 = R3 + R3 = 42 * 2 = 84)
        p_mem[23] = 16'h9408; // CONST R4, 8
        p_mem[24] = 16'h54D4; // MUL R4, R13, R4 (R4 = BlockID * 8)
        p_mem[25] = 16'h344F; // ADD R4, R4, R15 (R4 = Global Thread ID)
        p_mem[26] = 16'h8043; // STR x, R4, R3  (Store 84 to Global ID offset)
        p_mem[27] = 16'hF000; // RET

        // --- WARP 1 DIVERGENT BRANCH TARGETS ---
        p_mem[30] = 16'h930A; // CONST R3, 10 (Thread 4)
        p_mem[31] = 16'h1E46; // BRnzp 70 (0x46)
        
        p_mem[40] = 16'h9314; // CONST R3, 20 (Thread 5)
        p_mem[41] = 16'h1E46; // BRnzp 70
        
        p_mem[50] = 16'h931E; // CONST R3, 30 (Thread 6)
        p_mem[51] = 16'h1E46; // BRnzp 70
        
        p_mem[60] = 16'h9328; // CONST R3, 40 (Thread 7)
        p_mem[61] = 16'h1E46; // BRnzp 70

        // --- WARP 1 RECONVERGENCE & STORE ---
        p_mem[70] = 16'h9408; // CONST R4, 8
        p_mem[71] = 16'h54D4; // MUL R4, R13, R4 (R4 = BlockID * 8)
        p_mem[72] = 16'h344F; // ADD R4, R4, R15 (R4 = Global Thread ID)
        p_mem[73] = 16'h8043; // STR x, R4, R3
        p_mem[74] = 16'hF000; // RET

        reset = 1;
        start = 0;
        device_control_write_enable = 0;
        device_control_data = 0;
        
        #100 reset = 0;
        #50;

        device_control_write_enable = 1;
        device_control_data = 16; // Request 16 Threads (2 Blocks of 8 Threads)
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
                #25000; 
                $display("[%0t] [TESTBENCH] ERROR: Timeout waiting for DONE!", $time);
                $finish;
            end
        join_any

        $display("==================================================");
        $display("   VERIFYING RESULTS FOR 16 THREADS (2 CORES)");
        $display("==================================================");
        
        begin
            int expected [16] = '{
                // Block 0 (Core 0)
                84, 84, 84, 84, // Warp 0
                10, 20, 30, 40, // Warp 1 (4-way divergence)
                // Block 1 (Core 1)
                84, 84, 84, 84, // Warp 0
                10, 20, 30, 40  // Warp 1 (4-way divergence)
            };
            
            for (int i = 0; i < 16; i++) begin
                if (d_mem[i] == expected[i]) begin
                    $display("Global Thread %02d Output: %0d [PASS]", i, d_mem[i]);
                end else begin
                    $display("Global Thread %02d Output: %0d ... EXPECTED %0d [FAIL]", i, d_mem[i], expected[i]);
                end
            end
        end
        #20 $finish;
    end
endmodule