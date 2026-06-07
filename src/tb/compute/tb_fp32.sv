`default_nettype none
`timescale 1ns/1ps

module tb_fp32;
    // Parameters
    localparam DATA_WIDTH = 32;
    localparam ADDR_WIDTH = 32;
    localparam STRB_WIDTH = (DATA_WIDTH/8);
    localparam ID_WIDTH = 8;
    localparam AXI_DATA_WIDTH = 128; // 4 words per block

    // Core Parameters (Total 16 threads)
    localparam NUM_CORES = 1;
    localparam THREADS_PER_BLOCK = 4;
    localparam NUM_WARPS = 4;

    reg clk;
    reg reset;

    // AXI PMEM
    wire [ADDR_WIDTH-1:0]    m_axi_pmem_araddr;
    wire                     m_axi_pmem_arvalid;
    wire                     m_axi_pmem_arready;
    wire [7:0]               m_axi_pmem_arlen;
    wire [2:0]               m_axi_pmem_arsize;
    wire [1:0]               m_axi_pmem_arburst;
    wire [AXI_DATA_WIDTH-1:0] m_axi_pmem_rdata;
    wire [1:0]               m_axi_pmem_rresp;
    wire                     m_axi_pmem_rlast;
    wire                     m_axi_pmem_rvalid;
    wire                     m_axi_pmem_rready;

    // AXI DMEM
    wire [ADDR_WIDTH-1:0]    m_axi_dmem_awaddr;
    wire                     m_axi_dmem_awvalid;
    wire                     m_axi_dmem_awready;
    wire [7:0]               m_axi_dmem_awlen;
    wire [2:0]               m_axi_dmem_awsize;
    wire [1:0]               m_axi_dmem_awburst;
    wire [AXI_DATA_WIDTH-1:0] m_axi_dmem_wdata;
    wire [(AXI_DATA_WIDTH/8)-1:0] m_axi_dmem_wstrb;
    wire                     m_axi_dmem_wvalid;
    wire                     m_axi_dmem_wready;
    wire                     m_axi_dmem_wlast;
    wire [1:0]               m_axi_dmem_bresp;
    wire                     m_axi_dmem_bvalid;
    wire                     m_axi_dmem_bready;
    
    wire [ADDR_WIDTH-1:0]    m_axi_dmem_araddr;
    wire                     m_axi_dmem_arvalid;
    wire                     m_axi_dmem_arready;
    wire [7:0]               m_axi_dmem_arlen;
    wire [2:0]               m_axi_dmem_arsize;
    wire [1:0]               m_axi_dmem_arburst;
    wire [AXI_DATA_WIDTH-1:0] m_axi_dmem_rdata;
    wire [1:0]               m_axi_dmem_rresp;
    wire                     m_axi_dmem_rlast;
    wire                     m_axi_dmem_rvalid;
    wire                     m_axi_dmem_rready;

    // Control
    reg start;
    wire done;
    reg device_control_write_enable;
    reg [7:0] device_control_address;
    reg [7:0] device_control_data;

    // PMU
    wire [31:0] pmu_snap_0 [NUM_CORES];
    wire [31:0] pmu_snap_1 [NUM_CORES];
    wire [31:0] pmu_snap_2 [NUM_CORES];
    wire [31:0] pmu_snap_3 [NUM_CORES];

    // DUT
    gpu_axi_wrapper #(
        .DATA_MEM_ADDR_BITS(ADDR_WIDTH),
        .PROGRAM_MEM_ADDR_BITS(ADDR_WIDTH),
        .DATA_BITS(DATA_WIDTH),
        .AXI_DATA_WIDTH(AXI_DATA_WIDTH),
        .NUM_CORES(NUM_CORES),
        .THREADS_PER_BLOCK(THREADS_PER_BLOCK),
        .NUM_WARPS(NUM_WARPS)
    ) dut (
        .clk(clk), .reset(reset), .start(start), .done(done),
        .device_control_write_enable(device_control_write_enable),
        .device_control_address(device_control_address),
        .device_control_data(device_control_data),
        .pmu_snap_0(pmu_snap_0), .pmu_snap_1(pmu_snap_1),
        .pmu_snap_2(pmu_snap_2), .pmu_snap_3(pmu_snap_3),
        
        .m_axi_pmem_araddr(m_axi_pmem_araddr), .m_axi_pmem_arvalid(m_axi_pmem_arvalid),
        .m_axi_pmem_arready(m_axi_pmem_arready), .m_axi_pmem_arlen(m_axi_pmem_arlen),
        .m_axi_pmem_arsize(m_axi_pmem_arsize), .m_axi_pmem_arburst(m_axi_pmem_arburst),
        .m_axi_pmem_rdata(m_axi_pmem_rdata), .m_axi_pmem_rresp(m_axi_pmem_rresp),
        .m_axi_pmem_rlast(m_axi_pmem_rlast), .m_axi_pmem_rvalid(m_axi_pmem_rvalid),
        .m_axi_pmem_rready(m_axi_pmem_rready),

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

    // PMEM RAM
    axi_ram #(
        .DATA_WIDTH(AXI_DATA_WIDTH), .ADDR_WIDTH(ADDR_WIDTH), .ID_WIDTH(ID_WIDTH)
    ) pmem_ram (
        .clk(clk), .rst(reset),
        .s_axi_awid(8'd0), .s_axi_awaddr(32'd0), .s_axi_awlen(8'd0), .s_axi_awsize(3'd0), .s_axi_awburst(2'd0), .s_axi_awlock(1'b0), .s_axi_awcache(4'd0), .s_axi_awprot(3'd0), .s_axi_awvalid(1'b0), .s_axi_awready(),
        .s_axi_wdata(128'd0), .s_axi_wstrb(16'd0), .s_axi_wlast(1'b0), .s_axi_wvalid(1'b0), .s_axi_wready(),
        .s_axi_bid(), .s_axi_bresp(), .s_axi_bvalid(), .s_axi_bready(1'b1),
        .s_axi_arid(8'd0), .s_axi_araddr(m_axi_pmem_araddr), .s_axi_arlen(m_axi_pmem_arlen), .s_axi_arsize(m_axi_pmem_arsize), .s_axi_arburst(m_axi_pmem_arburst), .s_axi_arlock(1'b0), .s_axi_arcache(4'd0), .s_axi_arprot(3'd0), .s_axi_arvalid(m_axi_pmem_arvalid), .s_axi_arready(m_axi_pmem_arready),
        .s_axi_rid(), .s_axi_rdata(m_axi_pmem_rdata), .s_axi_rresp(m_axi_pmem_rresp), .s_axi_rlast(m_axi_pmem_rlast), .s_axi_rvalid(m_axi_pmem_rvalid), .s_axi_rready(m_axi_pmem_rready)
    );

    // DMEM RAM
    axi_ram #(
        .DATA_WIDTH(AXI_DATA_WIDTH), .ADDR_WIDTH(ADDR_WIDTH), .ID_WIDTH(ID_WIDTH)
    ) dmem_ram (
        .clk(clk), .rst(reset),
        .s_axi_awid(8'd0), .s_axi_awaddr(m_axi_dmem_awaddr), .s_axi_awlen(m_axi_dmem_awlen), .s_axi_awsize(m_axi_dmem_awsize), .s_axi_awburst(m_axi_dmem_awburst), .s_axi_awlock(1'b0), .s_axi_awcache(4'd0), .s_axi_awprot(3'd0), .s_axi_awvalid(m_axi_dmem_awvalid), .s_axi_awready(m_axi_dmem_awready),
        .s_axi_wdata(m_axi_dmem_wdata), .s_axi_wstrb(m_axi_dmem_wstrb), .s_axi_wlast(m_axi_dmem_wlast), .s_axi_wvalid(m_axi_dmem_wvalid), .s_axi_wready(m_axi_dmem_wready),
        .s_axi_bid(), .s_axi_bresp(m_axi_dmem_bresp), .s_axi_bvalid(m_axi_dmem_bvalid), .s_axi_bready(m_axi_dmem_bready),
        .s_axi_arid(8'd0), .s_axi_araddr(m_axi_dmem_araddr), .s_axi_arlen(m_axi_dmem_arlen), .s_axi_arsize(m_axi_dmem_arsize), .s_axi_arburst(m_axi_dmem_arburst), .s_axi_arlock(1'b0), .s_axi_arcache(4'd0), .s_axi_arprot(3'd0), .s_axi_arvalid(m_axi_dmem_arvalid), .s_axi_arready(m_axi_dmem_arready),
        .s_axi_rid(), .s_axi_rdata(m_axi_dmem_rdata), .s_axi_rresp(m_axi_dmem_rresp), .s_axi_rlast(m_axi_dmem_rlast), .s_axi_rvalid(m_axi_dmem_rvalid), .s_axi_rready(m_axi_dmem_rready)
    );

    initial begin
        clk = 0;
        forever #5 clk = ~clk;
    end

    // Load Program: Safely pack 32-bit hex line entries into 128-bit memory blocks
    reg [31:0] temp_mem [0:1023];
    initial begin
        for (int i = 0; i < 1024; i++) temp_mem[i] = 32'd0;
        $readmemh("reduction.hex", temp_mem);
        
        for (int i = 0; i < 256; i++) begin
            pmem_ram.mem[i] = {temp_mem[i*4+3], temp_mem[i*4+2], temp_mem[i*4+1], temp_mem[i*4+0]};
        end
    end

    initial begin
        reset = 1;
        start = 0;
        device_control_write_enable = 0;
        device_control_address = 0;
        device_control_data = 0;
        
        #100;
        reset = 0;
        #50;
        
        // Write thread_count = 16 to DCR (Address 0x00)
        device_control_write_enable = 1;
        device_control_address = 8'h00;
        device_control_data = 16;
        #10;
        device_control_write_enable = 0;
        #10;
        
        $display("[%0t] Starting GPU Computation...", $time);
        start = 1;
        #10;
        start = 0;
        
        wait(done);
        #100;
        
        $display("[%0t] Computation finished, inspecting Data Memory...", $time);
        
        // Expected value: Sum of 1 to 16 = 136 (0x00000088)
        if (dmem_ram.mem[0][31:0] !== 32'h00000088) begin
            $display("==================================================");
            $display("   STATUS: FAILED.");
            $display("   Expected 0x00000088, Got 0x%08x", dmem_ram.mem[0][31:0]);
            $display("==================================================");
        end else begin
            $display("==================================================");
            $display("   STATUS: SUCCESS! ");
            $display("   Tree Reduction calculated correctly (0x00000088).");
            $display("==================================================");
        end
        
        $finish;
    end

    // Failsafe Timeout
    initial begin
        #5000000;
        $display("Simulation Timeout.");
        $finish;
    end

endmodule