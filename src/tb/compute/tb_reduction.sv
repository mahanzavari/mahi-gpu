`default_nettype none
`timescale 1ns/1ns

module tb_reduction;

    parameter NUM_CORES = 1;
    parameter THREADS_PER_BLOCK = 16;
    parameter NUM_WARPS = 1;
    parameter DATA_WIDTH = 32;
    parameter ADDR_WIDTH = 32;

    reg clk;
    reg reset;
    reg start;
    wire done;

    // AXI Interfaces
    wire [ADDR_WIDTH-1:0]   m_axi_pmem_araddr;
    wire                    m_axi_pmem_arvalid;
    wire                    m_axi_pmem_arready;
    wire [7:0]              m_axi_pmem_arlen;
    wire [2:0]              m_axi_pmem_arsize;
    wire [1:0]              m_axi_pmem_arburst;
    wire [127:0]            m_axi_pmem_rdata;
    wire [1:0]              m_axi_pmem_rresp;
    wire                    m_axi_pmem_rlast;
    wire                    m_axi_pmem_rvalid;
    wire                    m_axi_pmem_rready;

    wire [ADDR_WIDTH-1:0]   m_axi_dmem_awaddr;
    wire                    m_axi_dmem_awvalid;
    wire                    m_axi_dmem_awready;
    wire [7:0]              m_axi_dmem_awlen;
    wire [2:0]              m_axi_dmem_awsize;
    wire [1:0]              m_axi_dmem_awburst;
    wire [127:0]            m_axi_dmem_wdata;
    wire [15:0]             m_axi_dmem_wstrb;
    wire                    m_axi_dmem_wvalid;
    wire                    m_axi_dmem_wready;
    wire                    m_axi_dmem_wlast;
    wire [1:0]              m_axi_dmem_bresp;
    wire                    m_axi_dmem_bvalid;
    wire                    m_axi_dmem_bready;
    
    wire [ADDR_WIDTH-1:0]   m_axi_dmem_araddr;
    wire                    m_axi_dmem_arvalid;
    wire                    m_axi_dmem_arready;
    wire [7:0]              m_axi_dmem_arlen;
    wire [2:0]              m_axi_dmem_arsize;
    wire [1:0]              m_axi_dmem_arburst;
    wire [127:0]            m_axi_dmem_rdata;
    wire [1:0]              m_axi_dmem_rresp;
    wire                    m_axi_dmem_rlast;
    wire                    m_axi_dmem_rvalid;
    wire                    m_axi_dmem_rready;

    // DCR (Device Control Register) Setup
    reg         dcr_we;
    reg [7:0]   dcr_addr;
    reg [7:0]   dcr_data;

    gpu_axi_wrapper #(
        .NUM_CORES(NUM_CORES),
        .THREADS_PER_BLOCK(THREADS_PER_BLOCK),
        .NUM_WARPS(NUM_WARPS)
    ) dut (
        .clk(clk),
        .reset(reset),
        .start(start),
        .done(done),
        .device_control_write_enable(dcr_we),
        .device_control_address(dcr_addr),
        .device_control_data(dcr_data),
        
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
        .m_axi_dmem_wlast(m_axi_dmem_wlast), .m_axi_dmem_bresp(m_axi_dmem_bresp),
        .m_axi_dmem_bvalid(m_axi_dmem_bvalid), .m_axi_dmem_bready(m_axi_dmem_bready),
        
        .m_axi_dmem_araddr(m_axi_dmem_araddr), .m_axi_dmem_arvalid(m_axi_dmem_arvalid),
        .m_axi_dmem_arready(m_axi_dmem_arready), .m_axi_dmem_arlen(m_axi_dmem_arlen),
        .m_axi_dmem_arsize(m_axi_dmem_arsize), .m_axi_dmem_arburst(m_axi_dmem_arburst),
        .m_axi_dmem_rdata(m_axi_dmem_rdata), .m_axi_dmem_rresp(m_axi_dmem_rresp),
        .m_axi_dmem_rlast(m_axi_dmem_rlast), .m_axi_dmem_rvalid(m_axi_dmem_rvalid),
        .m_axi_dmem_rready(m_axi_dmem_rready)
    );

    // --- FIX: Reduced ADDR_WIDTH to 16 to prevent Vivado OOM crash ---
    axi_ram #(
        .DATA_WIDTH(128), .ADDR_WIDTH(16) 
    ) program_memory (
        .clk(clk), .rst(reset),
        .s_axi_awid(8'd0), .s_axi_awaddr(16'd0), .s_axi_awlen(8'd0),
        .s_axi_awsize(3'd0), .s_axi_awburst(2'd0), .s_axi_awlock(1'b0),
        .s_axi_awcache(4'd0), .s_axi_awprot(3'd0), .s_axi_awvalid(1'b0),
        .s_axi_awready(), .s_axi_wdata(128'd0), .s_axi_wstrb(16'd0),
        .s_axi_wlast(1'b0), .s_axi_wvalid(1'b0), .s_axi_wready(),
        .s_axi_bid(), .s_axi_bresp(), .s_axi_bvalid(), .s_axi_bready(1'b1),
        
        // Truncate the 32-bit bus to 16-bits
        .s_axi_arid(8'd0), .s_axi_araddr(m_axi_pmem_araddr[15:0]), .s_axi_arlen(m_axi_pmem_arlen),
        .s_axi_arsize(m_axi_pmem_arsize), .s_axi_arburst(m_axi_pmem_arburst), .s_axi_arlock(1'b0),
        .s_axi_arcache(4'd0), .s_axi_arprot(3'd0), .s_axi_arvalid(m_axi_pmem_arvalid),
        .s_axi_arready(m_axi_pmem_arready), .s_axi_rid(), .s_axi_rdata(m_axi_pmem_rdata),
        .s_axi_rresp(m_axi_pmem_rresp), .s_axi_rlast(m_axi_pmem_rlast), .s_axi_rvalid(m_axi_pmem_rvalid),
        .s_axi_rready(m_axi_pmem_rready)
    );

    // --- FIX: Reduced ADDR_WIDTH to 16 to prevent Vivado OOM crash ---
    axi_ram #(
        .DATA_WIDTH(128), .ADDR_WIDTH(16)
    ) data_memory (
        .clk(clk), .rst(reset),
        
        // Truncate the 32-bit bus to 16-bits
        .s_axi_awid(8'd0), .s_axi_awaddr(m_axi_dmem_awaddr[15:0]), .s_axi_awlen(m_axi_dmem_awlen),
        .s_axi_awsize(m_axi_dmem_awsize), .s_axi_awburst(m_axi_dmem_awburst), .s_axi_awlock(1'b0),
        .s_axi_awcache(4'd0), .s_axi_awprot(3'd0), .s_axi_awvalid(m_axi_dmem_awvalid),
        .s_axi_awready(m_axi_dmem_awready), .s_axi_wdata(m_axi_dmem_wdata), .s_axi_wstrb(m_axi_dmem_wstrb),
        .s_axi_wlast(m_axi_dmem_wlast), .s_axi_wvalid(m_axi_dmem_wvalid), .s_axi_wready(m_axi_dmem_wready),
        .s_axi_bid(), .s_axi_bresp(m_axi_dmem_bresp), .s_axi_bvalid(m_axi_dmem_bvalid), .s_axi_bready(m_axi_dmem_bready),
        
        .s_axi_arid(8'd0), .s_axi_araddr(m_axi_dmem_araddr[15:0]), .s_axi_arlen(m_axi_dmem_arlen),
        .s_axi_arsize(m_axi_dmem_arsize), .s_axi_arburst(m_axi_dmem_arburst), .s_axi_arlock(1'b0),
        .s_axi_arcache(4'd0), .s_axi_arprot(3'd0), .s_axi_arvalid(m_axi_dmem_arvalid),
        .s_axi_arready(m_axi_dmem_arready), .s_axi_rid(), .s_axi_rdata(m_axi_dmem_rdata),
        .s_axi_rresp(m_axi_dmem_rresp), .s_axi_rlast(m_axi_dmem_rlast), .s_axi_rvalid(m_axi_dmem_rvalid),
        .s_axi_rready(m_axi_dmem_rready)
    );

    always #5 clk = ~clk;

    initial begin
        clk = 0; reset = 1; start = 0;
        dcr_we = 0; dcr_addr = 0; dcr_data = 0;
        #20 reset = 0;

        // Load compiled assembly directly into memory
        $readmemh("C:\\Users\\Mahan\\Desktop\\tiny-gpu\\assembler\\out.hex", program_memory.mem);

        // Tell GPU to dispatch all 16 threads (1 Warp)
        #10;
        dcr_we = 1; dcr_addr = 8'h00; dcr_data = 8'd16; 
        #10;
        dcr_we = 0;

        // Start GPU
        #10 start = 1;
        $display("[%0t] Starting GPU Parallel Tree Reduction...", $time);
        #10 start = 0;

        // Wait for completion
        wait(done);
        #50;
        
        $display("[%0t] Computation finished, inspecting Data Memory...", $time);

        // Verify the sum in Global Memory Address 0
        // Sum of 1 through 16 = 136 (0x88)
        if (data_memory.mem[0][31:0] == 32'h00000088) begin
            $display("==================================================");
            $display("   STATUS: PASS! Expected Sum 0x88, Got 0x88");
            $display("==================================================");
        end else begin
            $display("==================================================");
            $display("   STATUS: FAILED. Expected 0x88, Got %0h", data_memory.mem[0][31:0]);
            $display("==================================================");
        end
        
        $finish;
    end
endmodule