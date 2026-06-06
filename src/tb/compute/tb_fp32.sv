`timescale 1ns/1ns
`default_nettype none

module tb_fp32;

    reg clk;
    reg reset;
    
    // Clock Gen
    initial begin
        clk = 0;
        forever #5 clk = ~clk;
    end

    reg start;
    wire done;

    reg device_control_write_enable;
    reg [7:0] device_control_address;
    reg [7:0] device_control_data;

    // --- AXI Bus Wires ---
    wire [31:0] m_axi_pmem_araddr;
    wire        m_axi_pmem_arvalid;
    wire        m_axi_pmem_arready;
    wire [7:0]  m_axi_pmem_arlen;
    wire [2:0]  m_axi_pmem_arsize;
    wire [1:0]  m_axi_pmem_arburst;
    wire [127:0] m_axi_pmem_rdata;
    wire [1:0]  m_axi_pmem_rresp;
    wire        m_axi_pmem_rlast;
    wire        m_axi_pmem_rvalid;
    wire        m_axi_pmem_rready;

    wire [31:0] m_axi_dmem_awaddr;
    wire        m_axi_dmem_awvalid;
    wire        m_axi_dmem_awready;
    wire [7:0]  m_axi_dmem_awlen;
    wire [2:0]  m_axi_dmem_awsize;
    wire [1:0]  m_axi_dmem_awburst;
    wire [127:0] m_axi_dmem_wdata;
    wire [15:0] m_axi_dmem_wstrb;
    wire        m_axi_dmem_wvalid;
    wire        m_axi_dmem_wready;
    wire        m_axi_dmem_wlast;
    wire [1:0]  m_axi_dmem_bresp;
    wire        m_axi_dmem_bvalid;
    wire        m_axi_dmem_bready;
    wire [31:0] m_axi_dmem_araddr;
    wire        m_axi_dmem_arvalid;
    wire        m_axi_dmem_arready;
    wire [7:0]  m_axi_dmem_arlen;
    wire [2:0]  m_axi_dmem_arsize;
    wire [1:0]  m_axi_dmem_arburst;
    wire [127:0] m_axi_dmem_rdata;
    wire [1:0]  m_axi_dmem_rresp;
    wire        m_axi_dmem_rlast;
    wire        m_axi_dmem_rvalid;
    wire        m_axi_dmem_rready;

    // --- Device Under Test ---
    gpu_axi_wrapper #(
        .NUM_CORES(1),
        .THREADS_PER_BLOCK(4),
        .NUM_WARPS(1)
    ) dut (
        .clk(clk), .reset(reset), .start(start), .done(done),
        .device_control_write_enable(device_control_write_enable),
        .device_control_address(device_control_address),
        .device_control_data(device_control_data),
        
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

    // --- AXI Memories ---
    // [FIX] Changed ADDR_WIDTH to 16 to prevent Vivado Out-of-Memory limits at simulation Time 0.
    axi_ram #( .DATA_WIDTH(128), .ADDR_WIDTH(16) ) pmem (
        .clk(clk), .rst(reset),
        .s_axi_awid(8'b0), .s_axi_awaddr(16'b0), .s_axi_awlen(8'b0), .s_axi_awsize(3'b0),
        .s_axi_awburst(2'b0), .s_axi_awlock(1'b0), .s_axi_awcache(4'b0), .s_axi_awprot(3'b0),
        .s_axi_awvalid(1'b0), .s_axi_awready(), .s_axi_wdata(128'b0), .s_axi_wstrb(16'b0),
        .s_axi_wlast(1'b0), .s_axi_wvalid(1'b0), .s_axi_wready(), .s_axi_bid(), .s_axi_bresp(),
        .s_axi_bvalid(), .s_axi_bready(1'b0),
        
        .s_axi_arid(8'b0), .s_axi_araddr(m_axi_pmem_araddr[15:0]), .s_axi_arlen(m_axi_pmem_arlen),
        .s_axi_arsize(m_axi_pmem_arsize), .s_axi_arburst(m_axi_pmem_arburst), .s_axi_arlock(1'b0),
        .s_axi_arcache(4'b0), .s_axi_arprot(3'b0), .s_axi_arvalid(m_axi_pmem_arvalid),
        .s_axi_arready(m_axi_pmem_arready), .s_axi_rid(), .s_axi_rdata(m_axi_pmem_rdata),
        .s_axi_rresp(m_axi_pmem_rresp), .s_axi_rlast(m_axi_pmem_rlast),
        .s_axi_rvalid(m_axi_pmem_rvalid), .s_axi_rready(m_axi_pmem_rready)
    );

    axi_ram #( .DATA_WIDTH(128), .ADDR_WIDTH(16) ) dmem (
        .clk(clk), .rst(reset),
        .s_axi_awid(8'b0), .s_axi_awaddr(m_axi_dmem_awaddr[15:0]), .s_axi_awlen(m_axi_dmem_awlen),
        .s_axi_awsize(m_axi_dmem_awsize), .s_axi_awburst(m_axi_dmem_awburst), .s_axi_awlock(1'b0),
        .s_axi_awcache(4'b0), .s_axi_awprot(3'b0), .s_axi_awvalid(m_axi_dmem_awvalid),
        .s_axi_awready(m_axi_dmem_awready), .s_axi_wdata(m_axi_dmem_wdata), .s_axi_wstrb(m_axi_dmem_wstrb),
        .s_axi_wlast(m_axi_dmem_wlast), .s_axi_wvalid(m_axi_dmem_wvalid), .s_axi_wready(m_axi_dmem_wready),
        .s_axi_bid(), .s_axi_bresp(m_axi_dmem_bresp), .s_axi_bvalid(m_axi_dmem_bvalid), .s_axi_bready(m_axi_dmem_bready),
        
        .s_axi_arid(8'b0), .s_axi_araddr(m_axi_dmem_araddr[15:0]), .s_axi_arlen(m_axi_dmem_arlen),
        .s_axi_arsize(m_axi_dmem_arsize), .s_axi_arburst(m_axi_dmem_arburst), .s_axi_arlock(1'b0),
        .s_axi_arcache(4'b0), .s_axi_arprot(3'b0), .s_axi_arvalid(m_axi_dmem_arvalid),
        .s_axi_arready(m_axi_dmem_arready), .s_axi_rid(), .s_axi_rdata(m_axi_dmem_rdata),
        .s_axi_rresp(m_axi_dmem_rresp), .s_axi_rlast(m_axi_dmem_rlast),
        .s_axi_rvalid(m_axi_dmem_rvalid), .s_axi_rready(m_axi_dmem_rready)
    );

    // --- Program Setup & Execution ---
    reg [31:0] temp_pmem [0:1023];
    int errors;

    initial begin
        $display("==================================================");
        $display("   GPU FP32 Core Verification Testbench           ");
        $display("==================================================");

        // 1. Load Assembly into temporary 32-bit array
        for (int i=0; i<1024; i++) temp_pmem[i] = 0;
        $readmemh("C:\\Users\\Mahan\\Desktop\\tiny-gpu\\assembler\\out.hex", temp_pmem);
        
        // 2. Pack into 128-bit cache lines for AXI RAM
        for (int i=0; i<256; i++) begin
            pmem.mem[i] = {temp_pmem[i*4+3], temp_pmem[i*4+2], temp_pmem[i*4+1], temp_pmem[i*4+0]};
        end

        // 3. Reset GPU
        reset = 1;
        start = 0;
        device_control_write_enable = 0;
        device_control_address = 0;
        device_control_data = 0;
        #50 reset = 0;
        
        // 4. Configure DCR (Device Control Register) for 4 threads (1 Warp)
        #20 device_control_write_enable = 1;
        device_control_address = 8'h00; 
        device_control_data = 8'd4;
        #10 device_control_write_enable = 0;
        
        // 5. Start Execution
        $display("[%0t] Starting GPU Computation...", $time);
        #10 start = 1;
        #10 start = 0;

        // 6. Wait for program to naturally finish (and cache to flush)
        wait(done == 1'b1);
        $display("[%0t] Computation finished, inspecting Data Memory...", $time);
        #50;

        // 7. Verify FP32 Values generated by the FPU
        // Memory stores words at 0, 4, 8, 12 -> all land in the very first 128-bit AXI slot `dmem.mem[0]`
// 7. Verify Complex Math & Divergence
        // All threads write to a unique word offset based on their thread ID (`STR r5, r31, 0`)
        // which perfectly fills the first 128-bit block (dmem.mem[0]).
        errors = 0;

        // Thread 0: V = 1.0 -> 14.75 (0x416C0000)
        if (dmem.mem[0][31:0] !== 32'h416C0000) begin
            $display("FAIL [T0]: Expected 0x416C0000, Got 0x%08X", dmem.mem[0][31:0]);
            errors++;
        end else $display("PASS [T0]: Math Loop Correct! Iterative result = 14.75 (0x416C0000)");

        // Thread 1: V = 2.0 -> 30.75 (0x41F60000)
        if (dmem.mem[0][63:32] !== 32'h41F60000) begin
            $display("FAIL [T1]: Expected 0x41F60000, Got 0x%08X", dmem.mem[0][63:32]);
            errors++;
        end else $display("PASS [T1]: Divergence Correct! Iterative result = 30.75 (0x41F60000)");

        // Thread 2: V = 3.0 -> 46.75 (0x423B0000)
        if (dmem.mem[0][95:64] !== 32'h423B0000) begin
            $display("FAIL [T2]: Expected 0x423B0000, Got 0x%08X", dmem.mem[0][95:64]);
            errors++;
        end else $display("PASS [T2]: Reconvergence Correct! Iterative result = 46.75 (0x423B0000)");

        // Thread 3: V = 4.0 -> 62.75 (0x427B0000)
        if (dmem.mem[0][127:96] !== 32'h427B0000) begin
            $display("FAIL [T3] : Expected 0x427B0000, Got 0x%08X", dmem.mem[0][127:96]);
            errors++;
        end else $display("PASS [T3] : Store Coalescing Correct! Iterative result = 62.75 (0x427B0000)");

        $display("==================================================");
        if (errors == 0) $display("   STATUS: SUCCESS! COMPLEX FPU KERNEL WORKING.");
        else $display("   STATUS: FAILED WITH %0d ERRORS.", errors);
        $display("==================================================");

        $finish;
    end
endmodule