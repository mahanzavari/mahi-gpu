`default_nettype none
`timescale 1ns/1ns

module tb_gpu;

    // --- Configuration Parameters ---
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

    // --- PMU Event Readout Mappers (Fixes VRFC 10-2991 Error) ---
    // Statically maps the dynamic paths out of the generate blocks so 
    // the procedural code can just read arrays.
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
    
    // --- Storage Arrays ---
    reg [31:0] pmem_array [0:255];
    reg [31:0] dmem_array [0:1023]; 

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
                // Snapshot PMU exactly when the block completes (before dispatcher resets it)
                // dut.dispatch_instance.core_done is a packed array, so indexing it is legal here
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

            // Program the Memory-Mapped DCR PMU Registers
            // We unroll these statically to avoid Vivado procedural index constraints
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
            
            #10; device_control_write_enable = 1; device_control_data = 64; 
            #10; device_control_write_enable = 0;
            
            #10; start = 1; #10; start = 0;
            
            wait(done);
            #20;
        end
    endtask

    // --- Kernel and Main Block ---
    localparam [31:0] KERNEL_CODE [0:31] = '{
        32'h143D_F000, 32'h0C21_F800, 32'h2480_0008, 32'h1841_2000, 
        32'h5861_2000, 32'h24A0_0008, 32'h24C0_0000, 32'h24E0_0000, 
        32'h2500_0000, 32'h2520_0040, 32'h2540_0080, 32'h0806_2800, 
        32'h0580_0019, 32'h1562_2000, 32'h0D6B_3000, 32'h0D6B_4000, 
        32'h1586_2000, 32'h0D8C_1800, 32'h0D8C_4800, 32'h1DAB_0000, 
        32'h1DCC_0000, 32'h6CED_7000, 32'h25E0_0001, 32'h0CC6_7800, 
        32'h0780_000B, 32'h1602_2000, 32'h0E10_1800, 32'h0E10_5000, 
        32'h20F0_0000, 32'h3C00_0000, 32'h0000_0000, 32'h0000_0000 
    };

    integer i;
    integer test_errors; 

    initial begin
        $timeformat(-9, 0, " ns", 5);
        $display("==================================================");
        $display("   TINY-GPU MUXED PMU MULTI-PASS PROFILING");
        $display("==================================================");
        
        for (i=0; i<256; i=i+1) pmem_array[i] = 0;
        for (i=0; i<32; i=i+1) pmem_array[i] = KERNEL_CODE[i];
        for (i=0; i<1024; i=i+1) dmem_array[i] = 0;
        
        for (i=0; i<NUM_CORES; i=i+1) begin
            total_cycles[i]=0; total_active[i]=0; total_issue[i]=0; total_flush[i]=0;
            total_mem[i]=0; total_ic_acc[i]=0; total_ic_hit[i]=0; total_ic_stall[i]=0;
            total_dc_r_acc[i]=0; total_dc_r_hit[i]=0; total_dc_w_acc[i]=0; total_dc_w_hit[i]=0;
        end
        
        for (i=0; i<64; i=i+1) begin
            dmem_array[i]    = (i % 8) + 1;    
            dmem_array[64+i] = (i / 8) + 1;    
        end

        // Run 3 Passes to collect all metrics via the 4 Muxed Counters
        // Mapping: 3=Cycles, 4=Active, 5=Issue, 7=Flush
        run_profiling_pass(1, 5'd3, 5'd4, 5'd5, 5'd7);
        // Mapping: 8=MemInsts, 9=IC Acc, 10=IC Hit, 11=IC Stall
        run_profiling_pass(2, 5'd8, 5'd9, 5'd10, 5'd11);
        // Mapping: 18=DC R Acc, 19=DC R Hit, 21=DC W Acc, 22=DC W Hit
        run_profiling_pass(3, 5'd18, 5'd19, 5'd21, 5'd22);

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

        test_errors = 0;
        $display("Verifying Matrix C (Expected Output: 204 for all elements)...");
        for (int j=0; j<64; j=j+1) begin
            if (dmem_array[128+j] !== 204) begin
                $display("ERROR: C[%0d] = %0d (Expected 204)", j, dmem_array[128+j]);
                test_errors = test_errors + 1;
            end
        end
        
        if (test_errors == 0) $display("SUCCESS: All 64 elements computed properly!");
        else $display("FAILED: %0d elements yielded errors.", test_errors);
        
        $finish;
    end
endmodule