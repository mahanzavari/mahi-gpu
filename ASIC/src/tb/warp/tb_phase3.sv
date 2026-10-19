`default_nettype none
`timescale 1ns/1ns

module tb_phase3;

    // Parameters
    localparam DATA_MEM_ADDR_BITS = 8;
    localparam DATA_MEM_DATA_BITS = 16;
    localparam DATA_MEM_NUM_CHANNELS = 4;
    localparam PROGRAM_MEM_ADDR_BITS = 8;
    localparam PROGRAM_MEM_DATA_BITS = 16;
    localparam PROGRAM_MEM_NUM_CHANNELS = 1;
    localparam NUM_CORES = 1; 
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
            // Shift register for delay
            dmem_read_delay[i] <= {dmem_read_delay[i][3:0], data_mem_read_valid[i]};
            
            // Latch address on first cycle of request
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
        $display("   STARTING WARP SCHEDULING & LATENCY HIDING TEST ");
        $display("==================================================");

        for (int i = 0; i < 256; i++) d_mem[i] = 0;
        
        d_mem[100] = 42; // The value Warp 0 will load from memory

        // Program:
        // PC 0-2: Split Warps based on ThreadID
        p_mem[0]  = 16'h9104; // CONST R1, 4
        p_mem[1]  = 16'h20F1; // CMP R15, R1   (Is ThreadIdx < 4 ?)
        p_mem[2]  = 16'h120A; // BRn 10        (Warp 0 jumps to 10)
        
        // --- WARP 1 PATH (ThreadIdx 4, 5, 6, 7) ---
        p_mem[3]  = 16'h9201; // CONST R2, 1
        p_mem[4]  = 16'h3222; // ADD R2, R2, R2 (1+1=2)
        p_mem[5]  = 16'h3222; // ADD R2, R2, R2 (2+2=4)
        p_mem[6]  = 16'h3222; // ADD R2, R2, R2 (4+4=8)
        p_mem[7]  = 16'h3222; // ADD R2, R2, R2 (8+8=16)
        p_mem[8]  = 16'h80F2; // STR x, R15, R2 (Store 16 to d_mem[4..7])
        p_mem[9]  = 16'hF000; // RET
        
        // --- WARP 0 PATH (ThreadIdx 0, 1, 2, 3) ---
        p_mem[10] = 16'h9264; // CONST R2, 100
        p_mem[11] = 16'h7320; // LDR R3, R2     (Load from d_mem[100] -> STALLS WARP 0)
        p_mem[12] = 16'h3333; // ADD R3, R3, R3 (R3 = R3 + R3 = 42 * 2 = 84)
        p_mem[13] = 16'h80F3; // STR x, R15, R3 (Store 84 to d_mem[0..3])
        p_mem[14] = 16'hF000; // RET
        
        for (int i = 15; i < 256; i++) p_mem[i] = 16'h0000;

        reset = 1;
        start = 0;
        device_control_write_enable = 0;
        device_control_data = 0;
        
        #100 reset = 0;
        #50;

        device_control_write_enable = 1;
        device_control_data = 8; // Request 8 Threads (2 Warps)
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
                #15000; 
                $display("[%0t] [TESTBENCH] ERROR: Timeout waiting for DONE!", $time);
                $finish;
            end
        join_any

        $display("==================================================");
        $display("   VERIFYING RESULTS");
        $display("==================================================");
        
        begin
            int expected [8] = '{84, 84, 84, 84, 16, 16, 16, 16};
            for (int i = 0; i < 8; i++) begin
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