`default_nettype none
`timescale 1ns/1ns

module tb_gpu;

    // --- Configuration Parameters ---
    // Make SURE this path is exactly where your Python script saved out.hex!
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
        .DATA_MEM_ADDR_BITS(DATA_MEM_ADDR_BITS),
        .DATA_MEM_DATA_BITS(DATA_MEM_DATA_BITS),
        .DATA_MEM_NUM_CHANNELS(DATA_MEM_NUM_CHANNELS),
        .PROGRAM_MEM_ADDR_BITS(PROGRAM_MEM_ADDR_BITS),
        .PROGRAM_MEM_DATA_BITS(PROGRAM_MEM_DATA_BITS),
        .PROGRAM_MEM_NUM_CHANNELS(PROGRAM_MEM_NUM_CHANNELS),
        .NUM_CORES(NUM_CORES),
        .THREADS_PER_BLOCK(THREADS_PER_BLOCK),
        .NUM_WARPS(NUM_WARPS)
    ) dut (
        .clk(clk),
        .reset(reset),
        .start(start),
        .done(done),
        .device_control_write_enable(device_control_write_enable),
        .device_control_data(device_control_data),
        .program_mem_read_valid(pm_read_valid),
        .program_mem_read_address(pm_read_addr),
        .program_mem_read_ready(pm_read_ready),
        .program_mem_read_data(pm_read_data),
        .data_mem_read_valid(dm_read_valid),
        .data_mem_read_address(dm_read_addr),
        .data_mem_read_ready(dm_read_ready),
        .data_mem_read_data(dm_read_data),
        .data_mem_write_valid(dm_write_valid),
        .data_mem_write_address(dm_write_addr),
        .data_mem_write_data(dm_write_data),
        .data_mem_write_strobe(dm_write_strobe),
        .data_mem_write_ready(dm_write_ready)
    );

    // --- PMU Event Readout Mappers ---
    wire [31:0] pmu_cnt_0_w [NUM_CORES];
    wire [31:0] pmu_cnt_1_w [NUM_CORES];
    wire [31:0] pmu_cnt_2_w [NUM_CORES];
    wire [31:0] pmu_cnt_3_w [NUM_CORES];

    genvar g;
    generate
        for (g = 0; g < NUM_CORES; g = g + 1) begin : pmu_mapper
            assign pmu_cnt_0_w[g] = dut.core_block[g].core_inst.pmu_cnt_0;
            assign pmu_cnt_1_w[g] = dut.core_block[g].core_inst.pmu_cnt_1;
            assign pmu_cnt_2_w[g] = dut.core_block[g].core_inst.pmu_cnt_2;
            assign pmu_cnt_3_w[g] = dut.core_block[g].core_inst.pmu_cnt_3;
        end
    endgenerate

    // --- Clock Generation ---
    initial begin
        clk = 0;
        forever #5 clk = ~clk;
    end
    
    // --- TIMEOUT WATCHDOG (Prevents Infinite Hangs) ---
    initial begin
        #500000; // Stop simulation if it runs past 500,000 ns
        $display("\n==================================================");
        $display(" CRITICAL ERROR: SIMULATION TIMEOUT!");
        $display(" The GPU ran too long. This usually means the PC is stuck in an infinite loop, or out.hex didn't load.");
        $display("==================================================\n");
        $finish;
    end
    
    // --- Storage Arrays ---
    reg [31:0] pmem_array [256];
    reg [31:0] dmem_array [1024]; 

    // --- PMU Software Accumulators ---
    int current_pass = 0;
    
    reg [31:0] total_cycles [NUM_CORES];
    reg [31:0] total_active [NUM_CORES];
    reg [31:0] total_issue  [NUM_CORES];
    reg [31:0] total_flush  [NUM_CORES];
    
    reg [31:0] total_mem      [NUM_CORES];
    reg [31:0] total_ic_acc   [NUM_CORES];
    reg [31:0] total_ic_hit   [NUM_CORES];
    reg [31:0] total_ic_stall [NUM_CORES];
    
    reg [31:0] total_dc_r_acc [NUM_CORES];
    reg [31:0] total_dc_r_hit [NUM_CORES];
    reg [31:0] total_dc_w_acc [NUM_CORES];
    reg [31:0] total_dc_w_hit [NUM_CORES];

    always @(posedge clk) begin
        if (!reset) begin
            for (int i=0; i<NUM_CORES; i=i+1) begin
                if (dut.dispatch_instance.core_done[i]) begin
                    if (current_pass == 1) begin
                        total_cycles[i] += pmu_cnt_0_w[i];
                        total_active[i] += pmu_cnt_1_w[i];
                        total_issue[i]  += pmu_cnt_2_w[i];
                        total_flush[i]  += pmu_cnt_3_w[i];
                    end else if (current_pass == 2) begin
                        total_mem[i]      += pmu_cnt_0_w[i];
                        total_ic_acc[i]   += pmu_cnt_1_w[i];
                        total_ic_hit[i]   += pmu_cnt_2_w[i];
                        total_ic_stall[i] += pmu_cnt_3_w[i];
                    end else if (current_pass == 3) begin
                        total_dc_r_acc[i] += pmu_cnt_0_w[i];
                        total_dc_r_hit[i] += pmu_cnt_1_w[i];
                        total_dc_w_acc[i] += pmu_cnt_2_w[i];
                        total_dc_w_hit[i] += pmu_cnt_3_w[i];
                    end
                end
            end
        end
    end

    // --- Memory Emulation ---
    always @(posedge clk) begin
        if (reset) begin
            pm_read_ready <= 0;
            for (int c=0; c<PROGRAM_MEM_NUM_CHANNELS; c=c+1) pm_read_data[c] <= 0;
        end else begin
            for (int c=0; c<PROGRAM_MEM_NUM_CHANNELS; c=c+1) begin
                if (pm_read_valid[c]) begin
                    pm_read_data[c] <= { 
                        pmem_array[(pm_read_addr[c]*4) + 3],
                        pmem_array[(pm_read_addr[c]*4) + 2],
                        pmem_array[(pm_read_addr[c]*4) + 1],
                        pmem_array[(pm_read_addr[c]*4) + 0]
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
                        dmem_array[(dm_read_addr[c]*4) + 3],
                        dmem_array[(dm_read_addr[c]*4) + 2],
                        dmem_array[(dm_read_addr[c]*4) + 1],
                        dmem_array[(dm_read_addr[c]*4) + 0]
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

    // --- Multi-Pass Profiling Task ---
    task run_profiling_pass;
        input int pass_num;
        input [4:0] cfg0;
        input [4:0] cfg1;
        input [4:0] cfg2;
        input [4:0] cfg3;
        begin
            current_pass = pass_num;
            $display("\n[%0t] Launching Profiling Pass %0d...", $time, pass_num);

            force dut.core_block[0].core_inst.pmu_cfg_0 = cfg0;
            force dut.core_block[0].core_inst.pmu_cfg_1 = cfg1;
            force dut.core_block[0].core_inst.pmu_cfg_2 = cfg2;
            force dut.core_block[0].core_inst.pmu_cfg_3 = cfg3;

            if (NUM_CORES > 1) begin
                force dut.core_block[1].core_inst.pmu_cfg_0 = cfg0;
                force dut.core_block[1].core_inst.pmu_cfg_1 = cfg1;
                force dut.core_block[1].core_inst.pmu_cfg_2 = cfg2;
                force dut.core_block[1].core_inst.pmu_cfg_3 = cfg3;
            end

            reset = 1; start = 0; device_control_write_enable = 0; device_control_data = 0;
            #20; reset = 0;
            
            // CONVOLUTION: We need exactly 36 threads (a 6x6 output image)
            #10; device_control_write_enable = 1; device_control_data = 36; 
            #10; device_control_write_enable = 0;
            
            #10; start = 1; #10; start = 0;
            
            wait(done);
            #20;
        end
    endtask

    integer i;
    integer test_errors; 
    
    // Test verification arrays
    reg [31:0] expected_out [36];

    initial begin
        $timeformat(-9, 0, " ns", 5);
        $display("==================================================");
        $display("   TINY-GPU 2D CONVOLUTION KERNEL MULTI-PASS");
        $display("==================================================");
        
        // --- 1. Load the Hex File ---
        for (i=0; i<256; i=i+1) pmem_array[i] = 0; // Clear memory first
        
        $display("Loading instructions from: %s", HEX_FILE);
        $readmemh(HEX_FILE, pmem_array);
        
        // SAFETY CHECK: Did the file actually load?
        if (pmem_array[0] == 32'h00000000) begin
            $display("\n[!!! FATAL ERROR !!!]");
            $display("pmem_array[0] is completely empty. The simulation will hang because of infinite NOPs.");
            $display("Double check your HEX_FILE path. Windows requires double-backslashes (\\\\) in Verilog strings!");
            $finish;
        end
        
        // --- 2. Initialize Data Memory for Convolution ---
        for (i=0; i<1024; i=i+1) dmem_array[i] = 0;
        
        // Initialize an 8x8 Image (Address 0 to 63)
        // Values are all 1 to make it easy to spot calculation errors
        for (i=0; i<64; i=i+1) begin
            dmem_array[i] = 1;  
        end
        // Initialize a 3x3 Filter (Address 64 to 72)
        // Values are all 2. Expected output for every 3x3 patch = 1*2 * 9 = 18!
        for (i=0; i<9; i=i+1) begin
            dmem_array[64+i] = 2;    
        end
        
        // --- 3. Dynamically Calculate Expected Output ---
        for (int row=0; row<6; row=row+1) begin
            for (int col=0; col<6; col=col+1) begin
                int sum = 0;
                for (int ky=0; ky<3; ky=ky+1) begin
                    for (int kx=0; kx<3; kx=kx+1) begin
                        int img_val = dmem_array[(row + ky)*8 + (col + kx)];
                        int fil_val = dmem_array[64 + ky*3 + kx];
                        sum += img_val * fil_val;
                    end
                end
                expected_out[row*6 + col] = sum;
            end
        end

        // --- 4. Zero Profilers ---
        for (i=0; i<NUM_CORES; i=i+1) begin
            total_cycles[i]=0; total_active[i]=0; total_issue[i]=0; total_flush[i]=0;
            total_mem[i]=0; total_ic_acc[i]=0; total_ic_hit[i]=0; total_ic_stall[i]=0;
            total_dc_r_acc[i]=0; total_dc_r_hit[i]=0; total_dc_w_acc[i]=0; total_dc_w_hit[i]=0;
        end

        // --- 5. Run Execution Passes ---
        run_profiling_pass(1, 5'd3, 5'd4, 5'd5, 5'd7);
        run_profiling_pass(2, 5'd8, 5'd9, 5'd10, 5'd11);
        run_profiling_pass(3, 5'd18, 5'd19, 5'd21, 5'd22);

        // --- 6. Print Profiling Output ---
        $display("\n==================================================");
        $display("   FINAL PERFORMANCE COUNTERS REPORT");
        $display("==================================================");
        for (int c=0; c<NUM_CORES; c=c+1) begin
            $display("--- CORE %0d METRICS ---", c);
            $display("Total Cycle Count  : %0d", total_cycles[c]);
            $display("Active/Busy Cycles : %0d", total_active[c]);
            $display("Warp Issuances     : %0d", total_issue[c]);
            $display("Memory Insts       : %0d", total_mem[c]);
            $display("Pipeline Flushes   : %0d", total_flush[c]);
            
            $display("\n>> I-Cache Acc/Hits: %0d / %0d", total_ic_acc[c], total_ic_hit[c]);
            $display(">> D-Cache R. Acc/H: %0d / %0d", total_dc_r_acc[c], total_dc_r_hit[c]);
            $display(">> D-Cache W. Acc/H: %0d / %0d\n", total_dc_w_acc[c], total_dc_w_hit[c]);
        end
        $display("==================================================\n");

        // --- 7. Verify Correctness and Print Output Matrix ---
        test_errors = 0;
        $display("Verifying Convolution Output against Expected Results...");
        
        for (int j=0; j<36; j=j+1) begin
            // Matrix Output starts at memory address 73
            if (dmem_array[73+j] !== expected_out[j]) begin
                $display("ERROR: Out[%0d] = %0d (Expected %0d)", j, dmem_array[73+j], expected_out[j]);
                test_errors = test_errors + 1;
            end
        end
        
        if (test_errors == 0) $display("SUCCESS: All 36 Output Pixels match perfectly!\n");
        else $display("FAILED: %0d elements yielded errors.\n", test_errors);
        
        // Print the matrices beautifully
        $display("--- Filter Matrix (3x3) ---");
        for (int r=0; r<3; r++) $display("%4d %4d %4d", dmem_array[64+r*3+0], dmem_array[64+r*3+1], dmem_array[64+r*3+2]);
        
        $display("\n--- Convolution Output Matrix (6x6) ---");
        for (int r=0; r<6; r++) begin
            $display("%6d %6d %6d %6d %6d %6d",
                dmem_array[73 + r*6 + 0],
                dmem_array[73 + r*6 + 1],
                dmem_array[73 + r*6 + 2],
                dmem_array[73 + r*6 + 3],
                dmem_array[73 + r*6 + 4],
                dmem_array[73 + r*6 + 5]
            );
        end
        $display("\n==================================================");
        
        $finish;
    end
endmodule