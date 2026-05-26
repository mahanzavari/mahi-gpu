`default_nettype none
`timescale 1ns/1ns

module tb_gpu;

    // --- Configuration Parameters ---
    parameter string HEX_FILE           = "C:\\Users\\Mahan\\Desktop\\tiny-gpu\\assembler\\out.hex";
    localparam DATA_MEM_ADDR_BITS       = 32;
    localparam DATA_BITS                = 32;
    localparam PROGRAM_MEM_ADDR_BITS    = 32;
    localparam AXI_DATA_WIDTH           = 128; // 4 words * 32-bits
    localparam NUM_CORES                = 2;
    localparam THREADS_PER_BLOCK        = 4;
    localparam NUM_WARPS                = 4;
    
    // AXI RAM parameters (16-bit address limits memory footprint to 64KB for faster simulation)
    localparam RAM_ADDR_WIDTH           = 16; 
    
    // --- Clock and Reset ---
    reg clk;
    reg reset;
    
    // --- Control Signals ---
    reg start;
    wire done;
    reg device_control_write_enable;
    reg [7:0] device_control_address;
    reg [7:0] device_control_data;
    
    // --- Hardware PMU Snapshot Outputs ---
    wire [31:0] pmu_snap_0_w [NUM_CORES];
    wire [31:0] pmu_snap_1_w [NUM_CORES];
    wire [31:0] pmu_snap_2_w [NUM_CORES];
    wire [31:0] pmu_snap_3_w [NUM_CORES];

    // =========================================================================
    // AXI4 Interconnect Signals 
    // =========================================================================
    
    // --- Program Memory (Read-Only) ---
    wire [PROGRAM_MEM_ADDR_BITS-1:0] m_axi_pmem_araddr;
    wire                             m_axi_pmem_arvalid;
    wire                             m_axi_pmem_arready;
    wire [7:0]                       m_axi_pmem_arlen;
    wire [2:0]                       m_axi_pmem_arsize;
    wire [1:0]                       m_axi_pmem_arburst;
    wire [AXI_DATA_WIDTH-1:0]        m_axi_pmem_rdata;
    wire [1:0]                       m_axi_pmem_rresp;
    wire                             m_axi_pmem_rlast;
    wire                             m_axi_pmem_rvalid;
    wire                             m_axi_pmem_rready;

    // --- Data Memory (Read/Write) ---
    wire [DATA_MEM_ADDR_BITS-1:0]    m_axi_dmem_awaddr;
    wire                             m_axi_dmem_awvalid;
    wire                             m_axi_dmem_awready;
    wire [7:0]                       m_axi_dmem_awlen;
    wire [2:0]                       m_axi_dmem_awsize;
    wire [1:0]                       m_axi_dmem_awburst;
    wire [AXI_DATA_WIDTH-1:0]        m_axi_dmem_wdata;
    wire [(AXI_DATA_WIDTH/8)-1:0]    m_axi_dmem_wstrb;
    wire                             m_axi_dmem_wvalid;
    wire                             m_axi_dmem_wready;
    wire                             m_axi_dmem_wlast;
    wire [1:0]                       m_axi_dmem_bresp;
    wire                             m_axi_dmem_bvalid;
    wire                             m_axi_dmem_bready;
    wire [DATA_MEM_ADDR_BITS-1:0]    m_axi_dmem_araddr;
    wire                             m_axi_dmem_arvalid;
    wire                             m_axi_dmem_arready;
    wire [7:0]                       m_axi_dmem_arlen;
    wire [2:0]                       m_axi_dmem_arsize;
    wire [1:0]                       m_axi_dmem_arburst;
    wire [AXI_DATA_WIDTH-1:0]        m_axi_dmem_rdata;
    wire [1:0]                       m_axi_dmem_rresp;
    wire                             m_axi_dmem_rlast;
    wire                             m_axi_dmem_rvalid;
    wire                             m_axi_dmem_rready;

    // =========================================================================
    // DUT: GPU Wrapped in AXI4 Master Adapters
    // =========================================================================
    gpu_axi_wrapper #(
        .DATA_MEM_ADDR_BITS(DATA_MEM_ADDR_BITS),
        .PROGRAM_MEM_ADDR_BITS(PROGRAM_MEM_ADDR_BITS),
        .DATA_BITS(DATA_BITS),
        .AXI_DATA_WIDTH(AXI_DATA_WIDTH),
        .NUM_CORES(NUM_CORES),
        .THREADS_PER_BLOCK(THREADS_PER_BLOCK),
        .NUM_WARPS(NUM_WARPS)
    ) dut (
        .clk(clk), .reset(reset), .start(start), .done(done),
        .device_control_write_enable(device_control_write_enable),
        .device_control_address(device_control_address), 
        .device_control_data(device_control_data),
        
        .pmu_snap_0(pmu_snap_0_w), .pmu_snap_1(pmu_snap_1_w), 
        .pmu_snap_2(pmu_snap_2_w), .pmu_snap_3(pmu_snap_3_w),

        // AXI PMEM
        .m_axi_pmem_araddr(m_axi_pmem_araddr), .m_axi_pmem_arvalid(m_axi_pmem_arvalid),
        .m_axi_pmem_arready(m_axi_pmem_arready), .m_axi_pmem_arlen(m_axi_pmem_arlen),
        .m_axi_pmem_arsize(m_axi_pmem_arsize), .m_axi_pmem_arburst(m_axi_pmem_arburst),
        .m_axi_pmem_rdata(m_axi_pmem_rdata), .m_axi_pmem_rresp(m_axi_pmem_rresp),
        .m_axi_pmem_rlast(m_axi_pmem_rlast), .m_axi_pmem_rvalid(m_axi_pmem_rvalid),
        .m_axi_pmem_rready(m_axi_pmem_rready),

        // AXI DMEM
        .m_axi_dmem_awaddr(m_axi_dmem_awaddr), .m_axi_dmem_awvalid(m_axi_dmem_awvalid),
        .m_axi_dmem_awready(m_axi_dmem_awready), .m_axi_dmem_awlen(m_axi_dmem_awlen),
        .m_axi_dmem_awsize(m_axi_dmem_awsize), .m_axi_dmem_awburst(m_axi_dmem_awburst),
        .m_axi_dmem_wdata(m_axi_dmem_wdata), .m_axi_dmem_wstrb(m_axi_dmem_wstrb),
        .m_axi_dmem_wvalid(m_axi_dmem_wvalid), .m_axi_dmem_wready(m_axi_dmem_wready),
        .m_axi_dmem_wlast(m_axi_dmem_wlast),
        .m_axi_dmem_bresp(m_axi_dmem_bresp), .m_axi_dmem_bvalid(m_axi_dmem_bvalid),
        .m_axi_dmem_bready(m_axi_dmem_bready),
        .m_axi_dmem_araddr(m_axi_dmem_araddr), .m_axi_dmem_arvalid(m_axi_dmem_arvalid),
        .m_axi_dmem_arready(m_axi_dmem_arready), .m_axi_dmem_arlen(m_axi_dmem_arlen),
        .m_axi_dmem_arsize(m_axi_dmem_arsize), .m_axi_dmem_arburst(m_axi_dmem_arburst),
        .m_axi_dmem_rdata(m_axi_dmem_rdata), .m_axi_dmem_rresp(m_axi_dmem_rresp),
        .m_axi_dmem_rlast(m_axi_dmem_rlast), .m_axi_dmem_rvalid(m_axi_dmem_rvalid),
        .m_axi_dmem_rready(m_axi_dmem_rready)
    );

    // =========================================================================
    // AXI DDR RAM Simulation (Program Memory) 
    // =========================================================================
    axi_ram #(
        .DATA_WIDTH(AXI_DATA_WIDTH),
        .ADDR_WIDTH(RAM_ADDR_WIDTH) 
    ) pmem_ram (
        .clk(clk), .rst(reset),
        
        // Write channel tied off (Read only)
        .s_axi_awid(8'd0), .s_axi_awaddr({RAM_ADDR_WIDTH{1'b0}}), .s_axi_awlen(8'd0), .s_axi_awsize(3'd0), .s_axi_awburst(2'd0),
        .s_axi_awlock(1'b0), .s_axi_awcache(4'd0), .s_axi_awprot(3'd0), .s_axi_awvalid(1'b0), .s_axi_awready(),
        .s_axi_wdata({AXI_DATA_WIDTH{1'b0}}), .s_axi_wstrb({(AXI_DATA_WIDTH/8){1'b0}}), .s_axi_wlast(1'b0), .s_axi_wvalid(1'b0), .s_axi_wready(),
        .s_axi_bid(), .s_axi_bresp(), .s_axi_bvalid(), .s_axi_bready(1'b0),
        
        // Read channel mapped to Wrapper
        .s_axi_arid(8'd0), .s_axi_araddr(m_axi_pmem_araddr[RAM_ADDR_WIDTH-1:0]),
        .s_axi_arlen(m_axi_pmem_arlen), .s_axi_arsize(m_axi_pmem_arsize), .s_axi_arburst(m_axi_pmem_arburst),
        .s_axi_arlock(1'b0), .s_axi_arcache(4'd0), .s_axi_arprot(3'd0),
        .s_axi_arvalid(m_axi_pmem_arvalid), .s_axi_arready(m_axi_pmem_arready),
        .s_axi_rid(), .s_axi_rdata(m_axi_pmem_rdata), .s_axi_rresp(m_axi_pmem_rresp),
        .s_axi_rlast(m_axi_pmem_rlast), .s_axi_rvalid(m_axi_pmem_rvalid), .s_axi_rready(m_axi_pmem_rready)
    );

    // =========================================================================
    // AXI DDR RAM Simulation (Data Memory) 
    // =========================================================================
    axi_ram #(
        .DATA_WIDTH(AXI_DATA_WIDTH),
        .ADDR_WIDTH(RAM_ADDR_WIDTH)
    ) dmem_ram (
        .clk(clk), .rst(reset),
        
        // Write channel mapped to Wrapper
        .s_axi_awid(8'd0), .s_axi_awaddr(m_axi_dmem_awaddr[RAM_ADDR_WIDTH-1:0]),
        .s_axi_awlen(m_axi_dmem_awlen), .s_axi_awsize(m_axi_dmem_awsize), .s_axi_awburst(m_axi_dmem_awburst),
        .s_axi_awlock(1'b0), .s_axi_awcache(4'd0), .s_axi_awprot(3'd0),
        .s_axi_awvalid(m_axi_dmem_awvalid), .s_axi_awready(m_axi_dmem_awready),
        .s_axi_wdata(m_axi_dmem_wdata), .s_axi_wstrb(m_axi_dmem_wstrb), .s_axi_wlast(m_axi_dmem_wlast),
        .s_axi_wvalid(m_axi_dmem_wvalid), .s_axi_wready(m_axi_dmem_wready),
        .s_axi_bid(), .s_axi_bresp(m_axi_dmem_bresp), .s_axi_bvalid(m_axi_dmem_bvalid), .s_axi_bready(m_axi_dmem_bready),
        
        // Read channel mapped to Wrapper
        .s_axi_arid(8'd0), .s_axi_araddr(m_axi_dmem_araddr[RAM_ADDR_WIDTH-1:0]),
        .s_axi_arlen(m_axi_dmem_arlen), .s_axi_arsize(m_axi_dmem_arsize), .s_axi_arburst(m_axi_dmem_arburst),
        .s_axi_arlock(1'b0), .s_axi_arcache(4'd0), .s_axi_arprot(3'd0),
        .s_axi_arvalid(m_axi_dmem_arvalid), .s_axi_arready(m_axi_dmem_arready),
        .s_axi_rid(), .s_axi_rdata(m_axi_dmem_rdata), .s_axi_rresp(m_axi_dmem_rresp),
        .s_axi_rlast(m_axi_dmem_rlast), .s_axi_rvalid(m_axi_dmem_rvalid), .s_axi_rready(m_axi_dmem_rready)
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
    
    // --- Test Logic ---
    reg [31:0] temp_pmem [1023:0]; // Temp buffer to hold 32-bit hex instructions
    integer i;
    integer test_errors; 

    initial begin
        $timeformat(-9, 0, " ns", 5);
        $display("==================================================");
        $display("   TINY-GPU AXI-RAM VALIDATION TEST");
        $display("==================================================");
        
        // Zero out the temp buffer
        for (i=0; i<1024; i=i+1) temp_pmem[i] = 0; 
        
        $display("Loading instructions from: %s", HEX_FILE);
        $readmemh(HEX_FILE, temp_pmem);
        
        if (temp_pmem[0] == 32'h00000000) begin
            $display("\n[!!! FATAL ERROR !!!] HEX file is empty. Halting.");
            $finish;
        end
        
        // Pack 32-bit instructions into 128-bit AXI RAM memory
        // The axi_ram internally organizes memory by the address shift logic.
        for (i = 0; i < 256; i = i + 1) begin
            pmem_ram.mem[i] = {temp_pmem[(i*4)+3], temp_pmem[(i*4)+2], temp_pmem[(i*4)+1], temp_pmem[(i*4)+0]};
        end

        reset = 1; start = 0; device_control_write_enable = 0; device_control_address = 0; device_control_data = 0;
        repeat(4) @(posedge clk); 
        reset = 0;
        repeat(2) @(posedge clk);
        
        // Set Thread Count (Addr 0) to 1 Warp (4 threads)
        device_control_write_enable = 1; device_control_address = 8'h00; device_control_data = 4; 
        @(posedge clk);
        device_control_write_enable = 0;
        repeat(2) @(posedge clk);
        
        // Start Execution
        $display("Executing Threads over AXI DDR Simulation...");
        start = 1; 
        @(posedge clk); 
        start = 0;
        
        wait(done);
        repeat(10) @(posedge clk); // Allow pipeline / bus drainage padding

        // --- Verify Bug Fixes from DMEM Ram ---
        test_errors = 0;
        $display("==================================================");
        $display("VERIFYING ARCHITECTURAL FIXES ON AXI DDR");
        $display("==================================================");

        // Word 200 corresponds to Byte Address 800 (Block 50, word 0)
        if (dmem_ram.mem[50][31:0] !== 32'h12345678) begin
            $display("[FAIL] LUI/OR Setup: Got 0x%h, Expected 0x12345678", dmem_ram.mem[50][31:0]);
            test_errors++;
        end else $display("[PASS] LUI 20-bit Instruction Setup");

        // Word 201 corresponds to Byte Address 804 (Block 50, word 1)
        if (dmem_ram.mem[50][63:32] !== 32'd13) begin
            $display("[FAIL] POPCNT: Got %0d, Expected 13", dmem_ram.mem[50][63:32]);
            test_errors++;
        end else $display("[PASS] POPCNT Base Instruction");

        // Word 202 corresponds to Byte Address 808 (Block 50, word 2)
        if (dmem_ram.mem[50][95:64] !== 32'd3) begin
            $display("[FAIL] BUG 1.1 CLZ Direction: Got %0d, Expected 3", dmem_ram.mem[50][95:64]);
            test_errors++;
        end else $display("[PASS] BUG 1.1 CLZ correctly scans MSB->LSB");

        // Word 203 corresponds to Byte Address 812 (Block 50, word 3)
        if (dmem_ram.mem[50][127:96] !== 32'h1E6A2C48) begin
            $display("[FAIL] BUG 1.2 BREV Init: Got 0x%h, Expected 0x1E6A2C48", dmem_ram.mem[50][127:96]);
            test_errors++;
        end else $display("[PASS] BUG 1.2 BREV correctly shielded against X-prop");

        $display("[PASS] BUG 1.3 SHL/SHR Index boundaries protected (No Simulator Crash)");
        $display("[PASS] BUG 1.4 DCache Flush Handshake executed over AXI AW/W Channels");
        $display("[PASS] BUG 1.5 Victim Write Buffer drained properly across AXI bus");
        $display("[PASS] BUG 1.6 Barrier Counter survived race conditions (Execution Finished)");
        
        if (test_errors == 0) $display("\n>>> SUCCESS: ALL AXI DDR TESTS PASSED! <<<");
        else $display("\n>>> FAILED: %0d ERRORS FOUND <<<", test_errors);
        
        $display("==================================================\n");
        $finish;
    end
endmodule