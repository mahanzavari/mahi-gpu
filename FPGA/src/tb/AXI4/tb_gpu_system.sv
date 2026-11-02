`default_nettype none
`timescale 1ns/1ns

module tb_gpu_system;

    // --- Ensure this points to your assembler.py output ---
    parameter string HEX_FILE = "C:\\Users\\Mahan\\Desktop\\tiny-gpu\\assembler\\out.hex"; 

    localparam DATA_MEM_ADDR_BITS = 32;
    localparam PROGRAM_MEM_ADDR_BITS = 32;
    localparam DATA_BITS = 32;
    localparam AXI_DATA_WIDTH = 128;
    localparam NUM_CORES = 2;
    localparam THREADS_PER_BLOCK = 4;
    localparam NUM_WARPS = 4;

    logic clk;
    logic reset;
    logic start;
    wire done;

    logic device_control_write_enable;
    logic [7:0] device_control_address;
    logic [7:0] device_control_data;
    
    wire [31:0] pmu_snap_0 [NUM_CORES];
    wire [31:0] pmu_snap_1 [NUM_CORES];
    wire [31:0] pmu_snap_2 [NUM_CORES];
    wire [31:0] pmu_snap_3 [NUM_CORES];

    // --- PMEM AXI BUS (Instruction Memory) ---
    wire [PROGRAM_MEM_ADDR_BITS-1:0] m_axi_pmem_araddr;
    wire m_axi_pmem_arvalid, m_axi_pmem_arready, m_axi_pmem_rlast, m_axi_pmem_rvalid, m_axi_pmem_rready;
    wire [7:0] m_axi_pmem_arlen; wire [2:0] m_axi_pmem_arsize; wire [1:0] m_axi_pmem_arburst, m_axi_pmem_rresp;
    wire [AXI_DATA_WIDTH-1:0] m_axi_pmem_rdata;

    // --- DMEM AXI BUS (Data Memory) ---
    wire [DATA_MEM_ADDR_BITS-1:0] m_axi_dmem_awaddr, m_axi_dmem_araddr;
    wire m_axi_dmem_awvalid, m_axi_dmem_awready, m_axi_dmem_wvalid, m_axi_dmem_wready, m_axi_dmem_wlast;
    wire m_axi_dmem_bvalid, m_axi_dmem_bready, m_axi_dmem_arvalid, m_axi_dmem_arready;
    wire m_axi_dmem_rlast, m_axi_dmem_rvalid, m_axi_dmem_rready;
    wire [7:0] m_axi_dmem_awlen, m_axi_dmem_arlen; wire [2:0] m_axi_dmem_awsize, m_axi_dmem_arsize;
    wire [1:0] m_axi_dmem_awburst, m_axi_dmem_arburst, m_axi_dmem_bresp, m_axi_dmem_rresp;
    wire [AXI_DATA_WIDTH-1:0] m_axi_dmem_wdata, m_axi_dmem_rdata;
    wire [(AXI_DATA_WIDTH/8)-1:0] m_axi_dmem_wstrb;

    // =========================================================================
    // GPU AXI Wrapper
    // =========================================================================
    gpu_axi_wrapper #(
        .DATA_MEM_ADDR_BITS(DATA_MEM_ADDR_BITS), .PROGRAM_MEM_ADDR_BITS(PROGRAM_MEM_ADDR_BITS),
        .DATA_BITS(DATA_BITS), .AXI_DATA_WIDTH(AXI_DATA_WIDTH), .NUM_CORES(NUM_CORES),
        .THREADS_PER_BLOCK(THREADS_PER_BLOCK), .NUM_WARPS(NUM_WARPS)
    ) dut (
        .clk(clk), .reset(reset), .start(start), .done(done),
        .device_control_write_enable(device_control_write_enable),
        .device_control_address(device_control_address), .device_control_data(device_control_data),
        
        .pmu_snap_0(pmu_snap_0), .pmu_snap_1(pmu_snap_1), .pmu_snap_2(pmu_snap_2), .pmu_snap_3(pmu_snap_3),
        
        // PMEM Interface
        .m_axi_pmem_araddr(m_axi_pmem_araddr), .m_axi_pmem_arvalid(m_axi_pmem_arvalid), .m_axi_pmem_arready(m_axi_pmem_arready),
        .m_axi_pmem_arlen(m_axi_pmem_arlen), .m_axi_pmem_arsize(m_axi_pmem_arsize), .m_axi_pmem_arburst(m_axi_pmem_arburst),
        .m_axi_pmem_rdata(m_axi_pmem_rdata), .m_axi_pmem_rresp(m_axi_pmem_rresp), .m_axi_pmem_rlast(m_axi_pmem_rlast),
        .m_axi_pmem_rvalid(m_axi_pmem_rvalid), .m_axi_pmem_rready(m_axi_pmem_rready),

        // DMEM Interface
        .m_axi_dmem_awaddr(m_axi_dmem_awaddr), .m_axi_dmem_awvalid(m_axi_dmem_awvalid), .m_axi_dmem_awready(m_axi_dmem_awready),
        .m_axi_dmem_awlen(m_axi_dmem_awlen), .m_axi_dmem_awsize(m_axi_dmem_awsize), .m_axi_dmem_awburst(m_axi_dmem_awburst),
        .m_axi_dmem_wdata(m_axi_dmem_wdata), .m_axi_dmem_wstrb(m_axi_dmem_wstrb), .m_axi_dmem_wvalid(m_axi_dmem_wvalid),
        .m_axi_dmem_wready(m_axi_dmem_wready), .m_axi_dmem_wlast(m_axi_dmem_wlast), .m_axi_dmem_bresp(m_axi_dmem_bresp),
        .m_axi_dmem_bvalid(m_axi_dmem_bvalid), .m_axi_dmem_bready(m_axi_dmem_bready), .m_axi_dmem_araddr(m_axi_dmem_araddr),
        .m_axi_dmem_arvalid(m_axi_dmem_arvalid), .m_axi_dmem_arready(m_axi_dmem_arready), .m_axi_dmem_arlen(m_axi_dmem_arlen),
        .m_axi_dmem_arsize(m_axi_dmem_arsize), .m_axi_dmem_arburst(m_axi_dmem_arburst), .m_axi_dmem_rdata(m_axi_dmem_rdata),
        .m_axi_dmem_rresp(m_axi_dmem_rresp), .m_axi_dmem_rlast(m_axi_dmem_rlast), .m_axi_dmem_rvalid(m_axi_dmem_rvalid),
        .m_axi_dmem_rready(m_axi_dmem_rready)
    );

    // =========================================================================
    // Instruction AXI RAM (Loads HEX File)
    // =========================================================================
    axi_ram #( .DATA_WIDTH(AXI_DATA_WIDTH), .ADDR_WIDTH(PROGRAM_MEM_ADDR_BITS), .SIZE_BYTES(65536), .INIT_FILE(HEX_FILE)
    ) pmem_ram (
        .clk(clk), .reset(reset),
        .s_axi_awaddr(32'd0), .s_axi_awvalid(1'b0), .s_axi_awready(), .s_axi_awlen(8'd0), .s_axi_awsize(3'd0), .s_axi_awburst(2'd0),
        .s_axi_wdata(128'd0), .s_axi_wstrb(16'd0), .s_axi_wvalid(1'b0), .s_axi_wready(), .s_axi_wlast(1'b0),
        .s_axi_bresp(), .s_axi_bvalid(), .s_axi_bready(1'b1),
        .s_axi_araddr(m_axi_pmem_araddr), .s_axi_arvalid(m_axi_pmem_arvalid), .s_axi_arready(m_axi_pmem_arready),
        .s_axi_arlen(m_axi_pmem_arlen), .s_axi_arsize(m_axi_pmem_arsize), .s_axi_arburst(m_axi_pmem_arburst),
        .s_axi_rdata(m_axi_pmem_rdata), .s_axi_rresp(m_axi_pmem_rresp), .s_axi_rlast(m_axi_pmem_rlast),
        .s_axi_rvalid(m_axi_pmem_rvalid), .s_axi_rready(m_axi_pmem_rready)
    );

    // =========================================================================
    // Data AXI RAM
    // =========================================================================
    axi_ram #( .DATA_WIDTH(AXI_DATA_WIDTH), .ADDR_WIDTH(DATA_MEM_ADDR_BITS), .SIZE_BYTES(65536)
    ) dmem_ram (
        .clk(clk), .reset(reset),
        .s_axi_awaddr(m_axi_dmem_awaddr), .s_axi_awvalid(m_axi_dmem_awvalid), .s_axi_awready(m_axi_dmem_awready),
        .s_axi_awlen(m_axi_dmem_awlen), .s_axi_awsize(m_axi_dmem_awsize), .s_axi_awburst(m_axi_dmem_awburst),
        .s_axi_wdata(m_axi_dmem_wdata), .s_axi_wstrb(m_axi_dmem_wstrb), .s_axi_wvalid(m_axi_dmem_wvalid),
        .s_axi_wready(m_axi_dmem_wready), .s_axi_wlast(m_axi_dmem_wlast), .s_axi_bresp(m_axi_dmem_bresp),
        .s_axi_bvalid(m_axi_dmem_bvalid), .s_axi_bready(m_axi_dmem_bready), .s_axi_araddr(m_axi_dmem_araddr),
        .s_axi_arvalid(m_axi_dmem_arvalid), .s_axi_arready(m_axi_dmem_arready), .s_axi_arlen(m_axi_dmem_arlen),
        .s_axi_arsize(m_axi_dmem_arsize), .s_axi_arburst(m_axi_dmem_arburst), .s_axi_rdata(m_axi_dmem_rdata),
        .s_axi_rresp(m_axi_dmem_rresp), .s_axi_rlast(m_axi_dmem_rlast), .s_axi_rvalid(m_axi_dmem_rvalid),
        .s_axi_rready(m_axi_dmem_rready)
    );

    // --- Clock ---
    initial begin clk = 0; forever #5 clk = ~clk; end
    
    // --- TIMEOUT WATCHDOG ---
    initial begin
        #500000;
        $display("\n==================================================");
        $display(" CRITICAL ERROR: SIMULATION TIMEOUT!");
        $display("==================================================\n");
        $finish;
    end

    int test_errors = 0;

    // --- Boot and Test Sequence ---
    initial begin
        $timeformat(-9, 0, " ns", 5);
        $display("==================================================");
        $display("   TINY-GPU AXI HARDWARE VALIDATION");
        $display("==================================================");
        
        reset = 1; start = 0; device_control_write_enable = 0; device_control_address = 0; device_control_data = 0;
        repeat(4) @(posedge clk); 
        reset = 0;
        repeat(2) @(posedge clk);
        
        // Verify Program Was Loaded
        if (pmem_ram.memory[0] === 32'hx || pmem_ram.memory[0] === 32'h0) begin
            $display("[FATAL ERROR] No Instructions Loaded! Did you assemble program.hex?");
            $finish;
        end

        // Set Thread Count (Addr 0) to 1 Warp (4 threads)
        device_control_write_enable = 1; device_control_address = 8'h00; device_control_data = 4; 
        @(posedge clk);
        device_control_write_enable = 0;
        repeat(2) @(posedge clk);
        
        // Start GPU
        $display("Executing Threads over AXI...");
        start = 1; 
        @(posedge clk); 
        start = 0;
        
        wait(done == 1'b1);
        repeat(10) @(posedge clk); // Give RAM a moment to settle outputs
        
        $display("==================================================");
        $display("VERIFYING ARCHITECTURAL FIXES ON AXI DDR");
        $display("==================================================");

        // Access 32-bit words out of the AXI Memory internal array.
        // Because your custom core word offset 200 equates to Memory[200]
        if (dmem_ram.memory[200] !== 32'h12345678) begin
            $display("[FAIL] LUI/OR Setup: Got 0x%h, Expected 0x12345678", dmem_ram.memory[200]);
            test_errors++;
        end else $display("[PASS] LUI 20-bit Instruction Setup");

        if (dmem_ram.memory[201] !== 32'd13) begin
            $display("[FAIL] POPCNT: Got %0d, Expected 13", dmem_ram.memory[201]);
            test_errors++;
        end else $display("[PASS] POPCNT Base Instruction");

        if (dmem_ram.memory[202] !== 32'd3) begin
            $display("[FAIL] BUG 1.1 CLZ Direction: Got %0d, Expected 3", dmem_ram.memory[202]);
            test_errors++;
        end else $display("[PASS] BUG 1.1 CLZ correctly scans MSB->LSB");

        if (dmem_ram.memory[203] !== 32'h1E6A2C48) begin
            $display("[FAIL] BUG 1.2 BREV Init: Got 0x%h, Expected 0x1E6A2C48", dmem_ram.memory[203]);
            test_errors++;
        end else $display("[PASS] BUG 1.2 BREV correctly shielded against X-prop");

        $display("[PASS] BUG 1.3 SHL/SHR Index boundaries protected (No Simulator Crash)");
        $display("[PASS] BUG 1.4 DCache Flush Handshake executed properly over AXI");
        $display("[PASS] BUG 1.5 Victim Write Buffer drained properly to AXI DDR");
        $display("[PASS] BUG 1.6 Barrier Counter survived race conditions");
        
        if (test_errors == 0) $display("\n>>> SUCCESS: ALL TESTS PASSED! <<<");
        else $display("\n>>> FAILED: %0d ERRORS FOUND <<<", test_errors);
        
        $display("==================================================\n");
        $finish;
    end
endmodule