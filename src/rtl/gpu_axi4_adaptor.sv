`default_nettype none
`timescale 1ns/1ns

module gpu_axi_wrapper #(
    parameter DATA_MEM_ADDR_BITS = 32,
    parameter PROGRAM_MEM_ADDR_BITS = 32,
    parameter DATA_BITS = 32,
    parameter AXI_DATA_WIDTH = 128, // 4 words per block * 32 bits
    parameter NUM_CORES = 2,
    parameter THREADS_PER_BLOCK = 4,
    parameter NUM_WARPS = 4
) (
    input wire clk,
    input wire reset,

    input wire start,
    output wire done,

    // DCR (Device Control Register) CPU Interface
    input wire device_control_write_enable,
    input wire [7:0] device_control_address, 
    input wire [7:0] device_control_data,
    
    // PMU (Performance Monitoring Unit) Readouts
    output wire [31:0] pmu_snap_0 [NUM_CORES],
    output wire [31:0] pmu_snap_1 [NUM_CORES],
    output wire [31:0] pmu_snap_2 [NUM_CORES],
    output wire [31:0] pmu_snap_3 [NUM_CORES],

    // =========================================================================
    // AXI4 Master: Instruction/Program Memory (Read-Only)
    // =========================================================================
    output wire [PROGRAM_MEM_ADDR_BITS-1:0] m_axi_pmem_araddr,
    output wire                             m_axi_pmem_arvalid,
    input  wire                             m_axi_pmem_arready,
    output wire [7:0]                       m_axi_pmem_arlen,
    output wire [2:0]                       m_axi_pmem_arsize,
    output wire [1:0]                       m_axi_pmem_arburst,
    input  wire [AXI_DATA_WIDTH-1:0]        m_axi_pmem_rdata,
    input  wire [1:0]                       m_axi_pmem_rresp,
    input  wire                             m_axi_pmem_rlast,
    input  wire                             m_axi_pmem_rvalid,
    output wire                             m_axi_pmem_rready,

    // =========================================================================
    // AXI4 Master: Data Memory (Read/Write)
    // =========================================================================
    output wire [DATA_MEM_ADDR_BITS-1:0]    m_axi_dmem_awaddr,
    output wire                             m_axi_dmem_awvalid,
    input  wire                             m_axi_dmem_awready,
    output wire [7:0]                       m_axi_dmem_awlen,
    output wire [2:0]                       m_axi_dmem_awsize,
    output wire [1:0]                       m_axi_dmem_awburst,
    output wire [AXI_DATA_WIDTH-1:0]        m_axi_dmem_wdata,
    output wire [(AXI_DATA_WIDTH/8)-1:0]    m_axi_dmem_wstrb,
    output wire                             m_axi_dmem_wvalid,
    input  wire                             m_axi_dmem_wready,
    output wire                             m_axi_dmem_wlast,
    input  wire [1:0]                       m_axi_dmem_bresp,
    input  wire                             m_axi_dmem_bvalid,
    output wire                             m_axi_dmem_bready,
    output wire [DATA_MEM_ADDR_BITS-1:0]    m_axi_dmem_araddr,
    output wire                             m_axi_dmem_arvalid,
    input  wire                             m_axi_dmem_arready,
    output wire [7:0]                       m_axi_dmem_arlen,
    output wire [2:0]                       m_axi_dmem_arsize,
    output wire [1:0]                       m_axi_dmem_arburst,
    input  wire [AXI_DATA_WIDTH-1:0]        m_axi_dmem_rdata,
    input  wire [1:0]                       m_axi_dmem_rresp,
    input  wire                             m_axi_dmem_rlast,
    input  wire                             m_axi_dmem_rvalid,
    output wire                             m_axi_dmem_rready
);

    // Internal Native Wires
    wire [0:0] custom_pmem_r_valid, custom_pmem_r_ready;
    wire [PROGRAM_MEM_ADDR_BITS-1:0] custom_pmem_r_addr [1];
    wire [AXI_DATA_WIDTH-1:0] custom_pmem_r_data [1];

    wire [0:0] custom_dmem_r_valid, custom_dmem_r_ready;
    wire [DATA_MEM_ADDR_BITS-1:0] custom_dmem_r_addr [1];
    wire [AXI_DATA_WIDTH-1:0] custom_dmem_r_data [1];
    
    wire [0:0] custom_dmem_w_valid, custom_dmem_w_ready;
    wire [DATA_MEM_ADDR_BITS-1:0] custom_dmem_w_addr [1];
    wire [AXI_DATA_WIDTH-1:0] custom_dmem_w_data [1];
    wire [3:0] custom_dmem_w_strobe [1];

    // Instantiate the GPU core with exactly 1 Data Channel and 1 Program Channel
    gpu #(
        .DATA_MEM_ADDR_BITS(DATA_MEM_ADDR_BITS),
        .DATA_MEM_DATA_BITS(DATA_BITS),
        .DATA_MEM_NUM_CHANNELS(1),          // Locked to 1 for this wrapper
        .PROGRAM_MEM_ADDR_BITS(PROGRAM_MEM_ADDR_BITS),
        .PROGRAM_MEM_DATA_BITS(DATA_BITS),
        .PROGRAM_MEM_NUM_CHANNELS(1),       // Locked to 1 for this wrapper
        .NUM_CORES(NUM_CORES),
        .THREADS_PER_BLOCK(THREADS_PER_BLOCK),
        .NUM_WARPS(NUM_WARPS),
        .DEBUG(0)
    ) gpu_inst (
        .clk(clk), .reset(reset),
        .start(start), .done(done),
        .device_control_write_enable(device_control_write_enable),
        .device_control_address(device_control_address),
        .device_control_data(device_control_data),
        
        // Unpack Array [0] mapped to adapter
        .program_mem_read_valid(custom_pmem_r_valid[0]),
        .program_mem_read_address(custom_pmem_r_addr),
        .program_mem_read_ready(custom_pmem_r_ready[0]),
        .program_mem_read_data(custom_pmem_r_data),

        .data_mem_read_valid(custom_dmem_r_valid[0]),
        .data_mem_read_address(custom_dmem_r_addr),
        .data_mem_read_ready(custom_dmem_r_ready[0]),
        .data_mem_read_data(custom_dmem_r_data),
        
        .data_mem_write_valid(custom_dmem_w_valid[0]),
        .data_mem_write_address(custom_dmem_w_addr),
        .data_mem_write_data(custom_dmem_w_data),
        .data_mem_write_strobe(custom_dmem_w_strobe),
        .data_mem_write_ready(custom_dmem_w_ready[0]),
        
        .pmu_snap_0(pmu_snap_0), .pmu_snap_1(pmu_snap_1),
        .pmu_snap_2(pmu_snap_2), .pmu_snap_3(pmu_snap_3)
    );

    // Program Memory Adapter
    axi4_adapter #(
        .ADDR_BITS(PROGRAM_MEM_ADDR_BITS),
        .DATA_BITS(AXI_DATA_WIDTH),
        .CUSTOM_STROBE_BITS(4)
    ) pmem_adapter (
        .clk(clk), .reset(reset),
        
        // Native side
        .custom_read_valid(custom_pmem_r_valid[0]), .custom_read_addr(custom_pmem_r_addr[0]),
        .custom_read_ready(custom_pmem_r_ready[0]), .custom_read_data(custom_pmem_r_data[0]),
        .custom_write_valid(1'b0), .custom_write_addr(32'd0), .custom_write_data(128'd0), 
        .custom_write_strobe(4'd0), .custom_write_ready(), // Read-only

        // AXI side (Read only hooked up)
        .m_axi_awaddr(), .m_axi_awvalid(), .m_axi_awready(1'b0), .m_axi_awlen(), .m_axi_awsize(), .m_axi_awburst(),
        .m_axi_wdata(), .m_axi_wstrb(), .m_axi_wvalid(), .m_axi_wready(1'b0), .m_axi_wlast(),
        .m_axi_bresp(2'b0), .m_axi_bvalid(1'b0), .m_axi_bready(),
        
        .m_axi_araddr(m_axi_pmem_araddr), .m_axi_arvalid(m_axi_pmem_arvalid),
        .m_axi_arready(m_axi_pmem_arready), .m_axi_arlen(m_axi_pmem_arlen),
        .m_axi_arsize(m_axi_pmem_arsize), .m_axi_arburst(m_axi_pmem_arburst),
        .m_axi_rdata(m_axi_pmem_rdata), .m_axi_rresp(m_axi_pmem_rresp),
        .m_axi_rlast(m_axi_pmem_rlast), .m_axi_rvalid(m_axi_pmem_rvalid),
        .m_axi_rready(m_axi_pmem_rready)
    );

    // Data Memory Adapter
    axi4_adapter #(
        .ADDR_BITS(DATA_MEM_ADDR_BITS),
        .DATA_BITS(AXI_DATA_WIDTH),
        .CUSTOM_STROBE_BITS(4)
    ) dmem_adapter (
        .clk(clk), .reset(reset),
        
        // Native side
        .custom_read_valid(custom_dmem_r_valid[0]), .custom_read_addr(custom_dmem_r_addr[0]),
        .custom_read_ready(custom_dmem_r_ready[0]), .custom_read_data(custom_dmem_r_data[0]),
        .custom_write_valid(custom_dmem_w_valid[0]), .custom_write_addr(custom_dmem_w_addr[0]),
        .custom_write_data(custom_dmem_w_data[0]), .custom_write_strobe(custom_dmem_w_strobe[0]),
        .custom_write_ready(custom_dmem_w_ready[0]),

        // AXI side
        .m_axi_awaddr(m_axi_dmem_awaddr), .m_axi_awvalid(m_axi_dmem_awvalid),
        .m_axi_awready(m_axi_dmem_awready), .m_axi_awlen(m_axi_dmem_awlen),
        .m_axi_awsize(m_axi_dmem_awsize), .m_axi_awburst(m_axi_dmem_awburst),
        
        .m_axi_wdata(m_axi_dmem_wdata), .m_axi_wstrb(m_axi_dmem_wstrb),
        .m_axi_wvalid(m_axi_dmem_wvalid), .m_axi_wready(m_axi_dmem_wready),
        .m_axi_wlast(m_axi_dmem_wlast),
        
        .m_axi_bresp(m_axi_dmem_bresp), .m_axi_bvalid(m_axi_dmem_bvalid),
        .m_axi_bready(m_axi_dmem_bready),
        
        .m_axi_araddr(m_axi_dmem_araddr), .m_axi_arvalid(m_axi_dmem_arvalid),
        .m_axi_arready(m_axi_dmem_arready), .m_axi_arlen(m_axi_dmem_arlen),
        .m_axi_arsize(m_axi_dmem_arsize), .m_axi_arburst(m_axi_dmem_arburst),
        
        .m_axi_rdata(m_axi_dmem_rdata), .m_axi_rresp(m_axi_dmem_rresp),
        .m_axi_rlast(m_axi_dmem_rlast), .m_axi_rvalid(m_axi_dmem_rvalid),
        .m_axi_rready(m_axi_dmem_rready)
    );

endmodule