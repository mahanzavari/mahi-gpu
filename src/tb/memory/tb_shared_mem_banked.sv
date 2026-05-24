`default_nettype none
`timescale 1ns/1ns

module tb_shared_mem_banked;

    // --- Configuration Parameters ---
    parameter string HEX_FILE           = "C:\\Users\\ASUS\\Desktop\\tiny-gpu\\assembler\\out.hex"; 
    localparam DATA_MEM_ADDR_BITS       = 32;
    localparam DATA_MEM_DATA_BITS       = 32;
    localparam DATA_MEM_NUM_CHANNELS    = 4;
    localparam PROGRAM_MEM_ADDR_BITS    = 32;
    localparam PROGRAM_MEM_DATA_BITS    = 32;
    localparam PROGRAM_MEM_NUM_CHANNELS = 1;
    localparam NUM_CORES                = 1; 
    localparam THREADS_PER_BLOCK        = 4;
    localparam NUM_WARPS                = 1;
    
    // --- Clock and Reset ---
    reg clk;
    reg reset;
    
    // --- Control Signals ---
    reg start;
    wire done;
    reg device_control_write_enable;
    reg [7:0] device_control_address;
    reg [7:0] device_control_data;
    
    // --- Program Memory Interface ---
    wire [PROGRAM_MEM_NUM_CHANNELS-1:0] pm_read_valid;
    wire [PROGRAM_MEM_ADDR_BITS-1:0]    pm_read_addr [PROGRAM_MEM_NUM_CHANNELS];
    reg  [PROGRAM_MEM_NUM_CHANNELS-1:0] pm_read_ready;
    reg  [(PROGRAM_MEM_DATA_BITS*4)-1:0] pm_read_data [PROGRAM_MEM_NUM_CHANNELS];
    
    // --- Data Memory Interface ---
    wire [DATA_MEM_NUM_CHANNELS-1:0] dm_read_valid;
    wire [DATA_MEM_ADDR_BITS-1:0]    dm_read_addr [DATA_MEM_NUM_CHANNELS];
    reg  [DATA_MEM_NUM_CHANNELS-1:0] dm_read_ready;
    reg  [(DATA_MEM_DATA_BITS*4)-1:0] dm_read_data [DATA_MEM_NUM_CHANNELS];
    
    wire [DATA_MEM_NUM_CHANNELS-1:0] dm_write_valid;
    wire [DATA_MEM_ADDR_BITS-1:0]    dm_write_addr [DATA_MEM_NUM_CHANNELS];
    wire [(DATA_MEM_DATA_BITS*4)-1:0] dm_write_data [DATA_MEM_NUM_CHANNELS];
    wire [3:0]                       dm_write_strobe [DATA_MEM_NUM_CHANNELS];
    reg  [DATA_MEM_NUM_CHANNELS-1:0] dm_write_ready;
    
    // --- DUT Instantiation ---
    gpu #(
        .DATA_MEM_ADDR_BITS(DATA_MEM_ADDR_BITS), .DATA_MEM_DATA_BITS(DATA_MEM_DATA_BITS),
        .DATA_MEM_NUM_CHANNELS(DATA_MEM_NUM_CHANNELS), .PROGRAM_MEM_ADDR_BITS(PROGRAM_MEM_ADDR_BITS),
        .PROGRAM_MEM_DATA_BITS(PROGRAM_MEM_DATA_BITS), .PROGRAM_MEM_NUM_CHANNELS(PROGRAM_MEM_NUM_CHANNELS),
        .NUM_CORES(NUM_CORES), .THREADS_PER_BLOCK(THREADS_PER_BLOCK), .NUM_WARPS(NUM_WARPS), .DEBUG(0)
    ) dut (
        .clk(clk), .reset(reset), .start(start), .done(done),
        .device_control_write_enable(device_control_write_enable),
        .device_control_address(device_control_address), 
        .device_control_data(device_control_data),
        .program_mem_read_valid(pm_read_valid), .program_mem_read_address(pm_read_addr), .program_mem_read_ready(pm_read_ready), .program_mem_read_data(pm_read_data),
        .data_mem_read_valid(dm_read_valid), .data_mem_read_address(dm_read_addr), .data_mem_read_ready(dm_read_ready), .data_mem_read_data(dm_read_data),
        .data_mem_write_valid(dm_write_valid), .data_mem_write_address(dm_write_addr), .data_mem_write_data(dm_write_data),
        .data_mem_write_strobe(dm_write_strobe), .data_mem_write_ready(dm_write_ready)
    );

    // --- Clock Generation ---
    initial begin
        clk = 0;
        forever #5 clk = ~clk;
    end
    
    // --- TIMEOUT WATCHDOG ---
    initial begin
        #50000; // Shorter timeout, this program is very fast
        $display("\n[FATAL] SIMULATION TIMEOUT!");
        $finish;
    end
    
    // --- Storage Arrays ---
    reg [31:0] pmem_array [256];
    reg [31:0] dmem_array [1024]; 

    // --- Memory Emulation ---
    always @(posedge clk) begin
        if (reset) begin
            pm_read_ready <= 0;
            for (int c=0; c<PROGRAM_MEM_NUM_CHANNELS; c=c+1) pm_read_data[c] <= 0;
        end else begin
            for (int c=0; c<PROGRAM_MEM_NUM_CHANNELS; c=c+1) begin
                if (pm_read_valid[c]) begin
                    pm_read_data[c] <= { 
                        pmem_array[(pm_read_addr[c]*4) + 3], pmem_array[(pm_read_addr[c]*4) + 2],
                        pmem_array[(pm_read_addr[c]*4) + 1], pmem_array[(pm_read_addr[c]*4) + 0]
                    };
                    pm_read_ready[c] <= 1;
                end else pm_read_ready[c] <= 0;
            end
        end
    end

    always @(posedge clk) begin
        if (reset) begin
            dm_read_ready <= 0; dm_write_ready <= 0;
            for (int c=0; c<DATA_MEM_NUM_CHANNELS; c=c+1) dm_read_data[c] <= 0;
        end else begin
            for (int c=0; c<DATA_MEM_NUM_CHANNELS; c=c+1) begin
                if (dm_read_valid[c]) begin
                    dm_read_data[c] <= { 
                        dmem_array[(dm_read_addr[c]*4) + 3], dmem_array[(dm_read_addr[c]*4) + 2],
                        dmem_array[(dm_read_addr[c]*4) + 1], dmem_array[(dm_read_addr[c]*4) + 0]
                    };
                    dm_read_ready[c] <= 1;
                end else dm_read_ready[c] <= 0;
                
                if (dm_write_valid[c]) begin
                    if (dm_write_strobe[c][0]) dmem_array[(dm_write_addr[c]*4) + 0] <= dm_write_data[c][31:0];
                    if (dm_write_strobe[c][1]) dmem_array[(dm_write_addr[c]*4) + 1] <= dm_write_data[c][63:32];
                    if (dm_write_strobe[c][2]) dmem_array[(dm_write_addr[c]*4) + 2] <= dm_write_data[c][95:64];
                    if (dm_write_strobe[c][3]) dmem_array[(dm_write_addr[c]*4) + 3] <= dm_write_data[c][127:96];
                    dm_write_ready[c] <= 1;
                end else dm_write_ready[c] <= 0;
            end
        end
    end

    // --- Main Test Sequence ---
    integer i;
    integer errors;
    initial begin
        $timeformat(-9, 0, " ns", 5);
        $display("==================================================");
        $display("   SHARED MEMORY BANK CONFLICT & BROADCAST TEST");
        $display("==================================================");
        
        for (i=0; i<256; i=i+1) pmem_array[i] = 0; 
        for (i=0; i<1024; i=i+1) dmem_array[i] = 0; 
        
        $readmemh(HEX_FILE, pmem_array);
        
        reset = 1; start = 0;
        device_control_write_enable = 0; device_control_address = 0; device_control_data = 0;
        
        repeat(4) @(posedge clk); 
        reset = 0;
        repeat(2) @(posedge clk);
        
        // Setup Thread Count (4 threads)
        device_control_write_enable = 1; 
        device_control_address = 8'h00; 
        device_control_data = 4; 
        @(posedge clk);
        device_control_write_enable = 0;
        repeat(2) @(posedge clk);
        
        $display("[%0t] Starting GPU...", $time);
        start = 1; 
        @(posedge clk); 
        start = 0;
        
        wait(done);
        $display("[%0t] GPU Execution Finished.", $time);
        
        // Need to wait for flush caches to clear write buffers
        repeat(50) @(posedge clk); 

        // --- VERIFY RESULTS ---
        errors = 0;
        $display("\n--- Checking No-Conflict Read Results ---");
        for (i = 0; i < 4; i++) begin
            if (dmem_array[100 + i] !== i) begin
                $display("[FAIL] Thread %0d No-Conflict read got: %0d (Expected: %0d)", i, dmem_array[100+i], i);
                errors++;
            end else begin
                $display("[PASS] Thread %0d read %0d correctly.", i, i);
            end
        end

        $display("\n--- Checking Broadcast Read Results ---");
        for (i = 0; i < 4; i++) begin
            if (dmem_array[110 + i] !== 32'd11) begin
                $display("[FAIL] Thread %0d Broadcast read got: %0d (Expected: 11)", i, dmem_array[110+i]);
                errors++;
            end else begin
                $display("[PASS] Thread %0d read Broadcast 11 correctly.", i);
            end
        end

        if (errors == 0) begin
            $display("\n>>> SUCCESS: ALL TESTS PASSED! <<<");
            $display("Bank conflicts correctly serialized and broadcasts handled seamlessly.");
        end else begin
            $display("\n>>> FAILED: %0d ERRORS FOUND <<<", errors);
        end
        $display("==================================================\n");
        $finish;
    end
endmodule