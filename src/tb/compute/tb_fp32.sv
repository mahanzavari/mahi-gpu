`default_nettype none
`timescale 1ns/1ps

module tb_fp32;
    // System Parameters
    localparam DATA_WIDTH     = 32;
    localparam AXI_ADDR_WIDTH = 32;  // GPU core bus address width
    localparam RAM_ADDR_WIDTH = 16;  // 64 KB simulation RAM (4096 blocks of 128-bit) - Prevents xsim crash
    localparam AXI_DATA_WIDTH = 128; // 4 words per block
    localparam ID_WIDTH       = 8;

    localparam NUM_CORES         = 1;
    localparam THREADS_PER_BLOCK = 4;
    localparam NUM_WARPS         = 4;

    reg clk;
    reg reset;

    // AXI PMEM (32-bit bus from GPU)
    wire [AXI_ADDR_WIDTH-1:0] m_axi_pmem_araddr;
    wire                      m_axi_pmem_arvalid;
    wire                      m_axi_pmem_arready;
    wire [7:0]                m_axi_pmem_arlen;
    wire [2:0]                m_axi_pmem_arsize;
    wire [1:0]                m_axi_pmem_arburst;
    wire [AXI_DATA_WIDTH-1:0] m_axi_pmem_rdata;
    wire [1:0]                m_axi_pmem_rresp;
    wire                      m_axi_pmem_rlast;
    wire                      m_axi_pmem_rvalid;
    wire                      m_axi_pmem_rready;

    // AXI DMEM (32-bit bus from GPU)
    wire [AXI_ADDR_WIDTH-1:0] m_axi_dmem_awaddr;
    wire                      m_axi_dmem_awvalid;
    wire                      m_axi_dmem_awready;
    wire [7:0]                m_axi_dmem_awlen;
    wire [2:0]                m_axi_dmem_awsize;
    wire [1:0]                m_axi_dmem_awburst;
    wire [AXI_DATA_WIDTH-1:0] m_axi_dmem_wdata;
    wire [(AXI_DATA_WIDTH/8)-1:0] m_axi_dmem_wstrb;
    wire                      m_axi_dmem_wvalid;
    wire                      m_axi_dmem_wready;
    wire                      m_axi_dmem_wlast;
    wire [1:0]                m_axi_dmem_bresp;
    wire                      m_axi_dmem_bvalid;
    wire                      m_axi_dmem_bready;
    
    wire [AXI_ADDR_WIDTH-1:0] m_axi_dmem_araddr;
    wire                      m_axi_dmem_arvalid;
    wire                      m_axi_dmem_arready;
    wire [7:0]                m_axi_dmem_arlen;
    wire [2:0]                m_axi_dmem_arsize;
    wire [1:0]                m_axi_dmem_arburst;
    wire [AXI_DATA_WIDTH-1:0] m_axi_dmem_rdata;
    wire [1:0]                m_axi_dmem_rresp;
    wire                      m_axi_dmem_rlast;
    wire                      m_axi_dmem_rvalid;
    wire                      m_axi_dmem_rready;

    // GPU Control Signals
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

    // Instantiate GPU Wrapper (32-bit Address Interface)
    gpu_axi_wrapper #(
        .DATA_MEM_ADDR_BITS(AXI_ADDR_WIDTH),
        .PROGRAM_MEM_ADDR_BITS(AXI_ADDR_WIDTH),
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

    // PMEM RAM (Uses RAM_ADDR_WIDTH = 16 to keep memory depth safe)
    axi_ram #(
        .DATA_WIDTH(AXI_DATA_WIDTH),
        .ADDR_WIDTH(RAM_ADDR_WIDTH),
        .ID_WIDTH(ID_WIDTH)
    ) pmem_ram (
        .clk(clk), .rst(reset),
        .s_axi_awid(8'd0), .s_axi_awaddr({RAM_ADDR_WIDTH{1'b0}}), .s_axi_awlen(8'd0), .s_axi_awsize(3'd0), .s_axi_awburst(2'd0), .s_axi_awlock(1'b0), .s_axi_awcache(4'd0), .s_axi_awprot(3'd0), .s_axi_awvalid(1'b0), .s_axi_awready(),
        .s_axi_wdata({AXI_DATA_WIDTH{1'b0}}), .s_axi_wstrb({(AXI_DATA_WIDTH/8){1'b0}}), .s_axi_wlast(1'b0), .s_axi_wvalid(1'b0), .s_axi_wready(),
        .s_axi_bid(), .s_axi_bresp(), .s_axi_bvalid(), .s_axi_bready(1'b1),
        .s_axi_arid(8'd0),
        .s_axi_araddr(m_axi_pmem_araddr[RAM_ADDR_WIDTH-1:0]),
        .s_axi_arlen(m_axi_pmem_arlen), .s_axi_arsize(m_axi_pmem_arsize), .s_axi_arburst(m_axi_pmem_arburst), .s_axi_arlock(1'b0), .s_axi_arcache(4'd0), .s_axi_arprot(3'd0), .s_axi_arvalid(m_axi_pmem_arvalid), .s_axi_arready(m_axi_pmem_arready),
        .s_axi_rid(), .s_axi_rdata(m_axi_pmem_rdata), .s_axi_rresp(m_axi_pmem_rresp), .s_axi_rlast(m_axi_pmem_rlast), .s_axi_rvalid(m_axi_pmem_rvalid), .s_axi_rready(m_axi_pmem_rready)
    );

    // DMEM RAM (Uses RAM_ADDR_WIDTH = 16)
    axi_ram #(
        .DATA_WIDTH(AXI_DATA_WIDTH),
        .ADDR_WIDTH(RAM_ADDR_WIDTH),
        .ID_WIDTH(ID_WIDTH)
    ) dmem_ram (
        .clk(clk), .rst(reset),
        .s_axi_awid(8'd0),
        .s_axi_awaddr(m_axi_dmem_awaddr[RAM_ADDR_WIDTH-1:0]),
        .s_axi_awlen(m_axi_dmem_awlen), .s_axi_awsize(m_axi_dmem_awsize), .s_axi_awburst(m_axi_dmem_awburst), .s_axi_awlock(1'b0), .s_axi_awcache(4'd0), .s_axi_awprot(3'd0), .s_axi_awvalid(m_axi_dmem_awvalid), .s_axi_awready(m_axi_dmem_awready),
        .s_axi_wdata(m_axi_dmem_wdata), .s_axi_wstrb(m_axi_dmem_wstrb), .s_axi_wlast(m_axi_dmem_wlast), .s_axi_wvalid(m_axi_dmem_wvalid), .s_axi_wready(m_axi_dmem_wready),
        .s_axi_bid(), .s_axi_bresp(m_axi_dmem_bresp), .s_axi_bvalid(m_axi_dmem_bvalid), .s_axi_bready(m_axi_dmem_bready),
        .s_axi_arid(8'd0),
        .s_axi_araddr(m_axi_dmem_araddr[RAM_ADDR_WIDTH-1:0]),
        .s_axi_arlen(m_axi_dmem_arlen), .s_axi_arsize(m_axi_dmem_arsize), .s_axi_arburst(m_axi_dmem_arburst), .s_axi_arlock(1'b0), .s_axi_arcache(4'd0), .s_axi_arprot(3'd0), .s_axi_arvalid(m_axi_dmem_arvalid), .s_axi_arready(m_axi_dmem_arready),
        .s_axi_rid(), .s_axi_rdata(m_axi_dmem_rdata), .s_axi_rresp(m_axi_dmem_rresp), .s_axi_rlast(m_axi_dmem_rlast), .s_axi_rvalid(m_axi_dmem_rvalid), .s_axi_rready(m_axi_dmem_rready)
    );

    // 100 MHz Clock Generation
    initial begin
        clk = 0;
        forever #5 clk = ~clk;
    end

    // Load Program Memory
    initial begin
        // Delay by 1ns: axi_ram zeros its array at t=0; waiting 1ns avoids write clobbering
        #1;
        // Preload fp32_test kernel directly (Word3..Word0 per 128-bit block)
        pmem_ram.mem[0] = 128'h84821800_74680800_74480000_7427F000;
        pmem_ram.mem[1] = 128'h90E21800_74E7F000_88C31000_8CA21800;
        pmem_ram.mem[2] = 128'h25000000_06800010_081F0000_24000000;
        pmem_ram.mem[3] = 128'h20E80003_20C80002_20A80001_20880000;
        pmem_ram.mem[4] = 128'h00000000_00000000_00000000_3C000000;

        // Try reading from file if it exists in the Vivado simulation directory
        $readmemh("fp32_test.hex", pmem_ram.mem);
    end

    // DCR Host-Write Task
    task dcr_write(input [7:0] addr, input [7:0] data);
        begin
            @(posedge clk);
            device_control_write_enable <= 1'b1;
            device_control_address      <= addr;
            device_control_data         <= data;
            @(posedge clk);
            device_control_write_enable <= 1'b0;
        end
    endtask

    initial begin
        reset = 1;
        start = 0;
        device_control_write_enable = 0;
        device_control_address = 0;
        device_control_data = 0;
        
        #100;
        @(posedge clk);
        reset = 0;
        #50;
        
        // --- Configure DCR ---
        // Launch 16 threads (1 block = 4 warps x 4 threads)
        dcr_write(8'h00, 8'd16);

        // Configure PMU:
        // Counter 0: Event 3  (ev_cycle)
        // Counter 1: Event 24 (ex_fp_fire)
        // Counter 2: Event 25 (fp_wb_valid)
        // Counter 3: Event 26 (fp_raw_stall)
        dcr_write(8'h10, 5'd3);
        dcr_write(8'h11, 5'd24);
        dcr_write(8'h12, 5'd25);
        dcr_write(8'h13, 5'd26);

        // Reset PMU counters
        dcr_write(8'h01, 8'h01);

        #20;
        $display("\n[%0t] >>> Launching FP32 Kernel on mahi-gpu...", $time);
        @(posedge clk);
        start = 1;
        @(posedge clk);
        start = 0;

        // Wait for execution and cache drain
        wait(done);
        #100;

        // Snapshot PMU counters
        dcr_write(8'h02, 8'h01);
        #20;

        $display("\n==================================================");
        $display("   GPU COMPUTATION COMPLETE - VERIFYING RESULTS   ");
        $display("==================================================");

        begin : verify_memory
            logic [31:0] w0, w1, w2, w3;
            int errors;
            errors = 0;

            w0 = dmem_ram.mem[0][31:0];   // FADD: 2.0 + 3.0 = 5.0 (0x40A00000)
            w1 = dmem_ram.mem[0][63:32];  // FMUL: 2.0 * 3.0 = 6.0 (0x40C00000)
            w2 = dmem_ram.mem[0][95:64];  // FSUB: 3.0 - 2.0 = 1.0 (0x3F800000)
            w3 = dmem_ram.mem[0][127:96]; // FMA:  2.0 * 3.0 + 1.0 = 7.0 (0x40E00000)

            $display("Word 0 [FADD] -> Got: 0x%08h | Expected: 0x40A00000 (5.0f)", w0);
            if (w0 !== 32'h40A00000) begin
                $display("       >>> ERROR: FADD mismatch!");
                errors++;
            end

            $display("Word 1 [FMUL] -> Got: 0x%08h | Expected: 0x40C00000 (6.0f)", w1);
            if (w1 !== 32'h40C00000) begin
                $display("       >>> ERROR: FMUL mismatch!");
                errors++;
            end

            $display("Word 2 [FSUB] -> Got: 0x%08h | Expected: 0x3F800000 (1.0f)", w2);
            if (w2 !== 32'h3F800000) begin
                $display("       >>> ERROR: FSUB mismatch!");
                errors++;
            end

            $display("Word 3 [FMA ] -> Got: 0x%08h | Expected: 0x40E00000 (7.0f)", w3);
            if (w3 !== 32'h40E00000) begin
                $display("       >>> ERROR: FMA mismatch!");
                errors++;
            end

            $display("\n--- PMU Performance Counters (Core 0) ---");
            $display("Total Active Cycles : %0d", pmu_snap_0[0]);
            $display("FP Operations Fired : %0d", pmu_snap_1[0]);
            $display("FP Writebacks       : %0d", pmu_snap_2[0]);
            $display("FP RAW Stalls       : %0d", pmu_snap_3[0]);
            $display("-----------------------------------------");

            if (errors == 0) begin
                $display("\n==================================================");
                $display("   TEST STATUS: SUCCESS! All FPU units verified.  ");
                $display("==================================================\n");
            end else begin
                $display("\n==================================================");
                $display("   TEST STATUS: FAILED with %0d errors.            ", errors);
                $display("==================================================\n");
            end
        end

        $finish;
    end

    // Watchdog timeout
    initial begin
        #5000000;
        $display("[TIMEOUT] Simulation watchdog triggered at %0t ps.", $time);
        $finish;
    end
endmodule