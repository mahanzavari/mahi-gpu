`timescale 1ns/1ps
`default_nettype none

module tb_gpu_axi_wrapper();

    // --- Clock and Reset ---
    logic clk;
    logic reset;

    // --- GPU Control Signals ---
    logic start;
    logic done;
    logic device_control_write_enable;
    logic [7:0] device_control_address;
    logic [7:0] device_control_data;

    // PMU Snapshot Arrays
    wire [31:0] pmu_snap_0 [2];
    wire [31:0] pmu_snap_1 [2];
    wire [31:0] pmu_snap_2 [2];
    wire [31:0] pmu_snap_3 [2];

    // ==========================================
    // GPU to PMEM Signals (Read-Only from GPU)
    // ==========================================
    logic [31:0]  pmem_araddr;
    logic         pmem_arvalid;
    logic         pmem_arready;
    logic [7:0]   pmem_arlen;
    logic [2:0]   pmem_arsize;
    logic [1:0]   pmem_arburst;
    logic [127:0] pmem_rdata;
    logic [1:0]   pmem_rresp;
    logic         pmem_rlast;
    logic         pmem_rvalid;
    logic         pmem_rready;

    // ==========================================
    // GPU to DMEM Signals (Read & Write)
    // ==========================================
    logic [31:0]  dmem_awaddr;
    logic         dmem_awvalid;
    logic         dmem_awready;
    logic [7:0]   dmem_awlen;
    logic [2:0]   dmem_awsize;
    logic [1:0]   dmem_awburst;
    logic [127:0] dmem_wdata;
    logic [15:0]  dmem_wstrb;
    logic         dmem_wvalid;
    logic         dmem_wready;
    logic         dmem_wlast;
    logic [1:0]   dmem_bresp;
    logic         dmem_bvalid;
    logic         dmem_bready;
    logic [31:0]  dmem_araddr;
    logic         dmem_arvalid;
    logic         dmem_arready;
    logic [7:0]   dmem_arlen;
    logic [2:0]   dmem_arsize;
    logic [1:0]   dmem_arburst;
    logic [127:0] dmem_rdata;
    logic [1:0]   dmem_rresp;
    logic         dmem_rlast;
    logic         dmem_rvalid;
    logic         dmem_rready;

    // ==========================================
    // Instantiate the GPU Wrapper (DUT)
    // ==========================================
    gpu_axi_wrapper #(
        .NUM_CORES(2),
        .THREADS_PER_BLOCK(4),
        .NUM_WARPS(4)
    ) dut (
        .clk(clk),
        .reset(reset),
        .start(start),
        .done(done),
        .device_control_write_enable(device_control_write_enable),
        .device_control_address(device_control_address),
        .device_control_data(device_control_data),
        .pmu_snap_0(pmu_snap_0),
        .pmu_snap_1(pmu_snap_1),
        .pmu_snap_2(pmu_snap_2),
        .pmu_snap_3(pmu_snap_3),

        // PMEM Interface
        .m_axi_pmem_araddr(pmem_araddr),
        .m_axi_pmem_arvalid(pmem_arvalid),
        .m_axi_pmem_arready(pmem_arready),
        .m_axi_pmem_arlen(pmem_arlen),
        .m_axi_pmem_arsize(pmem_arsize),
        .m_axi_pmem_arburst(pmem_arburst),
        .m_axi_pmem_rdata(pmem_rdata),
        .m_axi_pmem_rresp(pmem_rresp),
        .m_axi_pmem_rlast(pmem_rlast),
        .m_axi_pmem_rvalid(pmem_rvalid),
        .m_axi_pmem_rready(pmem_rready),

        // DMEM Interface
        .m_axi_dmem_awaddr(dmem_awaddr),
        .m_axi_dmem_awvalid(dmem_awvalid),
        .m_axi_dmem_awready(dmem_awready),
        .m_axi_dmem_awlen(dmem_awlen),
        .m_axi_dmem_awsize(dmem_awsize),
        .m_axi_dmem_awburst(dmem_awburst),
        .m_axi_dmem_wdata(dmem_wdata),
        .m_axi_dmem_wstrb(dmem_wstrb),
        .m_axi_dmem_wvalid(dmem_wvalid),
        .m_axi_dmem_wready(dmem_wready),
        .m_axi_dmem_wlast(dmem_wlast),
        .m_axi_dmem_bresp(dmem_bresp),
        .m_axi_dmem_bvalid(dmem_bvalid),
        .m_axi_dmem_bready(dmem_bready),
        .m_axi_dmem_araddr(dmem_araddr),
        .m_axi_dmem_arvalid(dmem_arvalid),
        .m_axi_dmem_arready(dmem_arready),
        .m_axi_dmem_arlen(dmem_arlen),
        .m_axi_dmem_arsize(dmem_arsize),
        .m_axi_dmem_arburst(dmem_arburst),
        .m_axi_dmem_rdata(dmem_rdata),
        .m_axi_dmem_rresp(dmem_rresp),
        .m_axi_dmem_rlast(dmem_rlast),
        .m_axi_dmem_rvalid(dmem_rvalid),
        .m_axi_dmem_rready(dmem_rready)
    );

    // ==========================================
    // Parameter setup for RAM Instantiations
    // ==========================================
    localparam RAM_ADDR_WIDTH = 16; // 64 KB of memory space (safe for simulation)
    localparam RAM_DATA_WIDTH = 128;
    localparam RAM_ID_WIDTH   = 8;

    // ==========================================
    // Program Memory RAM Instance (Read Only)
    // ==========================================
    axi_ram #(
        .DATA_WIDTH(RAM_DATA_WIDTH),
        .ADDR_WIDTH(RAM_ADDR_WIDTH),
        .ID_WIDTH(RAM_ID_WIDTH)
    ) u_pmem (
        .clk(clk),
        .rst(reset),
        
        // Write channel tied to 0 since PMEM is Read-Only for the GPU
        .s_axi_awid(8'h0),
        .s_axi_awaddr({RAM_ADDR_WIDTH{1'b0}}),
        .s_axi_awlen(8'h0),
        .s_axi_awsize(3'h0),
        .s_axi_awburst(2'h0),
        .s_axi_awlock(1'b0),
        .s_axi_awcache(4'h0),
        .s_axi_awprot(3'h0),
        .s_axi_awvalid(1'b0),
        .s_axi_awready(),
        
        .s_axi_wdata({RAM_DATA_WIDTH{1'b0}}),
        .s_axi_wstrb({(RAM_DATA_WIDTH/8){1'b0}}),
        .s_axi_wlast(1'b0),
        .s_axi_wvalid(1'b0),
        .s_axi_wready(),
        
        .s_axi_bid(),
        .s_axi_bresp(),
        .s_axi_bvalid(),
        .s_axi_bready(1'b1),
        
        // Read channel mapped to GPU
        .s_axi_arid(8'h0),
        .s_axi_araddr(pmem_araddr[RAM_ADDR_WIDTH-1:0]),
        .s_axi_arlen(pmem_arlen),
        .s_axi_arsize(pmem_arsize),
        .s_axi_arburst(pmem_arburst),
        .s_axi_arlock(1'b0),
        .s_axi_arcache(4'h0),
        .s_axi_arprot(3'h0),
        .s_axi_arvalid(pmem_arvalid),
        .s_axi_arready(pmem_arready),
        
        .s_axi_rid(),
        .s_axi_rdata(pmem_rdata),
        .s_axi_rresp(pmem_rresp),
        .s_axi_rlast(pmem_rlast),
        .s_axi_rvalid(pmem_rvalid),
        .s_axi_rready(pmem_rready)
    );

    // ==========================================
    // Data Memory RAM Instance (Read & Write)
    // ==========================================
    axi_ram #(
        .DATA_WIDTH(RAM_DATA_WIDTH),
        .ADDR_WIDTH(RAM_ADDR_WIDTH),
        .ID_WIDTH(RAM_ID_WIDTH)
    ) u_dmem (
        .clk(clk),
        .rst(reset),
        
        // Write channel mapped to GPU
        .s_axi_awid(8'h0),
        .s_axi_awaddr(dmem_awaddr[RAM_ADDR_WIDTH-1:0]),
        .s_axi_awlen(dmem_awlen),
        .s_axi_awsize(dmem_awsize),
        .s_axi_awburst(dmem_awburst),
        .s_axi_awlock(1'b0),
        .s_axi_awcache(4'h0),
        .s_axi_awprot(3'h0),
        .s_axi_awvalid(dmem_awvalid),
        .s_axi_awready(dmem_awready),
        
        .s_axi_wdata(dmem_wdata),
        .s_axi_wstrb(dmem_wstrb),
        .s_axi_wlast(dmem_wlast),
        .s_axi_wvalid(dmem_wvalid),
        .s_axi_wready(dmem_wready),
        
        .s_axi_bid(),
        .s_axi_bresp(dmem_bresp),
        .s_axi_bvalid(dmem_bvalid),
        .s_axi_bready(dmem_bready),
        
        // Read channel mapped to GPU
        .s_axi_arid(8'h0),
        .s_axi_araddr(dmem_araddr[RAM_ADDR_WIDTH-1:0]),
        .s_axi_arlen(dmem_arlen),
        .s_axi_arsize(dmem_arsize),
        .s_axi_arburst(dmem_arburst),
        .s_axi_arlock(1'b0),
        .s_axi_arcache(4'h0),
        .s_axi_arprot(3'h0),
        .s_axi_arvalid(dmem_arvalid),
        .s_axi_arready(dmem_arready),
        
        .s_axi_rid(),
        .s_axi_rdata(dmem_rdata),
        .s_axi_rresp(dmem_rresp),
        .s_axi_rlast(dmem_rlast),
        .s_axi_rvalid(dmem_rvalid),
        .s_axi_rready(dmem_rready)
    );

    // --- Clock Generation ---
    initial begin
        clk = 0;
        forever #5 clk = ~clk; // 100 MHz clock
    end

    // --- Test Sequence ---
    initial begin
        // Initialize Inputs
        reset = 1;
        start = 0;
        device_control_write_enable = 0;
        device_control_address = 0;
        device_control_data = 0;

        // ====================================================================
        // Pre-Load Memory directly via hierarchy
        // ====================================================================
        // The RAM has 128-bit (16-byte) rows.
        // We pack four 32-bit EXIT instructions (0x3C000000) into a 128-bit vector.
        
        // Fill the first 1KB (64 blocks of 16-bytes) of Program Memory 
        for (int i = 0; i < 64; i++) begin
            u_pmem.mem[i] = 128'h3C000000_3C000000_3C000000_3C000000;
        end
        $display("[%0t] Program Memory Initialized with EXIT Instructions", $time);

        // Release Reset after 200ns
        #200 reset = 0;
        #20;

        // Configure DCR: Set thread_count to 32 (Address 0x00)
        @(posedge clk);
        device_control_write_enable = 1;
        device_control_address = 8'h00;
        device_control_data = 8'd32; // 32 Threads
        @(posedge clk);
        device_control_write_enable = 0;

        // Start the GPU
        @(posedge clk);
        start = 1;
        @(posedge clk);
        start = 0;

        $display("[%0t] GPU Started...", $time);

        // Wait for 'done' signal (Wait max 10us as a safety timeout)
        fork
            begin
                wait(done == 1'b1);
                $display("[%0t] GPU Execution Completed Gracefully!", $time);
            end
            begin
                #10000;
                $display("[%0t] ERROR: Simulation Timeout! GPU did not assert done.", $time);
            end
        join_any
        disable fork; // Kill the timeout if 'done' happens first

        #100;
        $finish;
    end
endmodule