`default_nettype none
`timescale 1ns/1ns

module tb_gpu;

    // --- Configuration Parameters ---
    parameter string HEX_FILE           = "C:\\Users\\ASUS\\Desktop\\tiny-gpu\\assembler\\out.hex"; 
    localparam DATA_MEM_ADDR_BITS       = 32;
    localparam DATA_MEM_DATA_BITS       = 32;
    localparam DATA_MEM_NUM_CHANNELS    = 4;
    localparam PROGRAM_MEM_ADDR_BITS    = 32;
    localparam PROGRAM_MEM_DATA_BITS    = 32;
    localparam PROGRAM_MEM_NUM_CHANNELS = 1;
    localparam NUM_CORES                = 2;
    localparam THREADS_PER_BLOCK        = 4;
    localparam NUM_WARPS                = 4;
    
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
    
    // --- Hardware PMU Snapshot Outputs ---
    wire [31:0] pmu_snap_0_w [NUM_CORES];
    wire [31:0] pmu_snap_1_w [NUM_CORES];
    wire [31:0] pmu_snap_2_w [NUM_CORES];
    wire [31:0] pmu_snap_3_w [NUM_CORES];

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
        .data_mem_write_strobe(dm_write_strobe), .data_mem_write_ready(dm_write_ready),
        .pmu_snap_0(pmu_snap_0_w), .pmu_snap_1(pmu_snap_1_w), .pmu_snap_2(pmu_snap_2_w), .pmu_snap_3(pmu_snap_3_w)
    );

    // --- Clock Generation ---
    initial begin
        clk = 0;
        forever #5 clk = ~clk;
    end
    
    // --- TIMEOUT WATCHDOG ---
    initial begin
        #500000;
        $display("\n==================================================");
        $display(" CRITICAL ERROR: SIMULATION TIMEOUT!");
        $display("==================================================\n");
        $finish;
    end
    
    // --- Storage Arrays ---
    reg [31:0] pmem_array [256];
    reg [31:0] dmem_array [1024]; 

    // --- PMU Software Accumulators ---
    reg [31:0] total_cycles [NUM_CORES];
    reg [31:0] total_active [NUM_CORES];
    reg [31:0] total_issue  [NUM_CORES];
    reg [31:0] total_flush  [NUM_CORES];
    
    reg [31:0] total_mem      [NUM_CORES];
    reg [31:0] total_ic_acc   [NUM_CORES];
    reg [31:0] total_ic_hit   [NUM_CORES];
    reg [31:0] total_ic_stall [NUM_CORES];
    
    reg [31:0] total_stall_mem [NUM_CORES];
    reg [31:0] total_stall_bar [NUM_CORES];
    reg [31:0] total_stall_rdy [NUM_CORES];
    reg [31:0] total_diverge   [NUM_CORES];

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

    // --- Multi-Pass Hardware Snapshot Task ---
    task run_profiling_pass;
        input int pass_num;
        input [4:0] cfg0; input [4:0] cfg1; input [4:0] cfg2; input [4:0] cfg3;
        begin
            $display("\n[%0t] Launching Profiling Pass %0d (cfg: %0d, %0d, %0d, %0d)...", $time, pass_num, cfg0, cfg1, cfg2, cfg3);

            force dut.core_block[0].core_inst.pmu_cfg_0 = cfg0; force dut.core_block[0].core_inst.pmu_cfg_1 = cfg1;
            force dut.core_block[0].core_inst.pmu_cfg_2 = cfg2; force dut.core_block[0].core_inst.pmu_cfg_3 = cfg3;
            if (NUM_CORES > 1) begin
                force dut.core_block[1].core_inst.pmu_cfg_0 = cfg0; force dut.core_block[1].core_inst.pmu_cfg_1 = cfg1;
                force dut.core_block[1].core_inst.pmu_cfg_2 = cfg2; force dut.core_block[1].core_inst.pmu_cfg_3 = cfg3;
            end

            reset = 1; start = 0; device_control_write_enable = 0; device_control_address = 0; device_control_data = 0;
            repeat(4) @(posedge clk); 
            reset = 0;
            repeat(2) @(posedge clk);
            
            // Trigger PMU Reset (Addr 1)
            device_control_write_enable = 1; device_control_address = 8'h01; device_control_data = 1;
            @(posedge clk);
            device_control_write_enable = 0;
            repeat(2) @(posedge clk);
            
            // Set Thread Count (Addr 0)
            device_control_write_enable = 1; device_control_address = 8'h00; device_control_data = 36; 
            @(posedge clk);
            device_control_write_enable = 0;
            repeat(2) @(posedge clk);
            
            // Start Execution
            start = 1; 
            @(posedge clk); 
            start = 0;
            
            wait(done);
            repeat(4) @(posedge clk);
            
            // Trigger Hardware Snapshot (Addr 2)
            device_control_write_enable = 1; device_control_address = 8'h02; device_control_data = 1;
            @(posedge clk);
            device_control_write_enable = 0;
            
            // Wait for DCR -> PMU -> Latch -> Output propagation
            repeat(4) @(posedge clk);
            
            // Log HW Snapshots to TB trackers
            for (int i=0; i<NUM_CORES; i=i+1) begin
                if (pass_num == 1) begin
                    total_cycles[i] += pmu_snap_0_w[i]; total_active[i] += pmu_snap_1_w[i];
                    total_issue[i]  += pmu_snap_2_w[i]; total_flush[i]  += pmu_snap_3_w[i];
                end else if (pass_num == 2) begin
                    total_mem[i]      += pmu_snap_0_w[i]; total_ic_acc[i]   += pmu_snap_1_w[i];
                    total_ic_hit[i]   += pmu_snap_2_w[i]; total_ic_stall[i] += pmu_snap_3_w[i];
                end else if (pass_num == 3) begin
                    total_stall_mem[i] += pmu_snap_0_w[i]; total_stall_bar[i] += pmu_snap_1_w[i];
                    total_stall_rdy[i] += pmu_snap_2_w[i]; total_diverge[i]   += pmu_snap_3_w[i];
                end
            end
        end
    endtask

    integer i;
    integer test_errors; 
    reg [31:0] expected_out [36];

    initial begin
        $timeformat(-9, 0, " ns", 5);
        $display("==================================================");
        $display("   TINY-GPU KERNEL & PHASE 1 FEATURES TEST");
        $display("==================================================");
        
        for (i=0; i<256; i=i+1) pmem_array[i] = 0; 
        
        $display("Loading instructions from: %s", HEX_FILE);
        $readmemh(HEX_FILE, pmem_array);
        
        if (pmem_array[0] == 32'h00000000) begin
            $display("\n[!!! FATAL ERROR !!!] pmem_array[0] is empty. Halting.");
            $finish;
        end
        
        // --- 2. Initialize Data Memory ---
        for (i=0; i<1024; i=i+1) dmem_array[i] = 0;
        for (i=0; i<64; i=i+1) dmem_array[i] = 1;  
        for (i=0; i<9; i=i+1) dmem_array[64+i] = 2;    
        
        for (int row=0; row<6; row=row+1) begin
            for (int col=0; col<6; col=col+1) begin
                int sum = 0;
                for (int ky=0; ky<3; ky=ky+1) begin
                    for (int kx=0; kx<3; kx=kx+1) sum += dmem_array[(row + ky)*8 + (col + kx)] * dmem_array[64 + ky*3 + kx];
                end
                expected_out[row*6 + col] = sum;
            end
        end

        for (i=0; i<NUM_CORES; i=i+1) begin
            total_cycles[i]=0; total_active[i]=0; total_issue[i]=0; total_flush[i]=0;
            total_mem[i]=0; total_ic_acc[i]=0; total_ic_hit[i]=0; total_ic_stall[i]=0;
            total_stall_mem[i]=0; total_stall_bar[i]=0; total_stall_rdy[i]=0; total_diverge[i]=0;
        end

        // Pass 1: Base Core Performance
        run_profiling_pass(1, 5'd3, 5'd4, 5'd5, 5'd7);
        // Pass 2: Memory Controller & ICache
        run_profiling_pass(2, 5'd8, 5'd9, 5'd10, 5'd11);
        // Pass 3: New Stall Diagnostics (MemStall, BarStall, NoReady, Divergence)
        run_profiling_pass(3, 5'd15, 5'd16, 5'd17, 5'd14);

        $display("\n==================================================");
        $display("   FINAL PMU PERFORMANCE HARDWARE SNAPSHOTS");
        $display("==================================================");
        for (int c=0; c<NUM_CORES; c=c+1) begin
            $display("--- CORE %0d METRICS ---", c);
            $display("Total Cycle Count  : %0d", total_cycles[c]);
            $display("Active/Busy Cycles : %0d", total_active[c]);
            $display("Warp Issuances     : %0d", total_issue[c]);
            $display("Pipeline Flushes   : %0d", total_flush[c]);
            
            $display("\n>> I-Cache Acc/Hits: %0d / %0d (Stalls: %0d)", total_ic_acc[c], total_ic_hit[c], total_ic_stall[c]);
            
            $display("\n>> Scheduler Mem Stalls : %0d", total_stall_mem[c]);
            $display(">> Scheduler Bar Stalls : %0d", total_stall_bar[c]);
            $display(">> Scheduler Rdy Stalls : %0d", total_stall_rdy[c]);
            $display(">> Branch Divergences   : %0d\n", total_diverge[c]);
        end

        // --- 7. Verify Results ---
        test_errors = 0;
        $display("==================================================");
        $display("VERIFYING CONVOLUTION & ALU FEATURE TESTS");
        $display("==================================================");
        
        for (int j=0; j<36; j=j+1) begin
            if (dmem_array[73+j] !== expected_out[j]) begin
                $display("CONV ERROR: Out[%0d] = %0d (Expected %0d)", j, dmem_array[73+j], expected_out[j]);
                test_errors = test_errors + 1;
            end
        end
        if (test_errors == 0) $display("[PASS] 2D Convolution matches Expected Matrix!");

        // Verify the Phase 1 Features
        if (dmem_array[200] !== 32'h12345678) begin
            $display("[FAIL] LUI/OR Test: Got 0x%h, Expected 0x12345678", dmem_array[200]);
            test_errors++;
        end else $display("[PASS] LUI 20-bit Instruction");

        if (dmem_array[201] !== 32'd13) begin
            $display("[FAIL] POPCNT Test: Got %0d, Expected 13", dmem_array[201]);
            test_errors++;
        end else $display("[PASS] POPCNT Instruction");

        if (dmem_array[202] !== 32'd3) begin
            $display("[FAIL] CLZ Test: Got %0d, Expected 3", dmem_array[202]);
            test_errors++;
        end else $display("[PASS] CLZ Instruction");

        if (dmem_array[203] !== 32'h1E6A2C48) begin
            $display("[FAIL] BREV Test: Got 0x%h, Expected 0x1E6A2C48", dmem_array[203]);
            test_errors++;
        end else $display("[PASS] BREV Instruction");
        
        if (test_errors == 0) $display("\n>>> SUCCESS: ALL TESTS PASSED! <<<");
        else $display("\n>>> FAILED: %0d ERRORS FOUND <<<", test_errors);
        
        $display("==================================================\n");
        $finish;
    end
endmodule