`default_nettype none
`timescale 1ns/1ns

module gpu_asic_top (
`ifdef USE_POWER_PINS
    inout  wire        vccd1,
    inout  wire        vssd1,
`endif
    input  wire        clk,
    input  wire        reset,

    // --- Standard 32-bit Wishbone Slave Interface ---
    input  wire        wb_cyc_i,
    input  wire        wb_stb_i,
    input  wire        wb_we_i,
    input  wire [3:0]  wb_sel_i,
    input  wire [31:0] wb_adr_i,
    input  wire [31:0] wb_dat_i,
    output reg  [31:0] wb_dat_o,
    output reg         wb_ack_o,

    // Hardware status interrupt / pin
    output wire        gpu_done_pin
);

    // =========================================================================
    // Address Map (wb_adr_i[31:12] selects the page; every access is acked)
    //   0x3000_0000 CTRL   W: [0] start (level)  [1] soft reset (self-clearing, other bits ignored)
    //                         [15:8] thread_count
    //                      R: {16'd0, thread_count, 7'd0, start}
    //   0x3000_0004 STATUS R: [0] done  [1] busy  [2] gpu_oob (sticky)  [3] host_blocked (sticky)
    //                      W: writing 1 to [2] / [3] clears that flag
    //   0x3000_1000 - 0x3000_17FF  PMEM: 512 words, GPU instruction words 0..511
    //   0x3000_1800 - 0x3000_1FFF  DMEM: 512 words, GPU data words 0..511
    //   anything else: acked, reads return 0, writes ignored
    // The memory window is only reachable while the GPU is not running (busy = 0);
    // a blocked access is acked immediately, reads 32'hBAD0_BAD0, the write is dropped
    // and STATUS[3] is set.
    // =========================================================================
    localparam [19:0] PAGE_CSR = 20'h30000;
    localparam [19:0] PAGE_MEM = 20'h30001;
    localparam [31:0] BLOCKED_DATA = 32'hBAD0_BAD0;

    reg        start_req, start_d1, start_d2;
    wire       gpu_done;
    reg  [7:0] dcr_addr;
    reg  [7:0] dcr_data;
    reg        dcr_we;
    reg  [3:0] rst_cnt;                     // soft reset: gpu_reset held while non-zero
    reg        flag_oob, flag_blocked;

    wire       gpu_reset  = reset || (rst_cnt != 4'd0);
    wire       gpu_start  = start_d2;
    wire       run_active = start_req && !(gpu_done && start_d2);
    wire       mem_busy;                    // GPU transaction in flight in gpu_mem_subsys
    wire       oob_pulse;

    assign gpu_done_pin = gpu_done;

    // ---- host-side memory request registers
    localparam H_IDLE = 2'd0, H_ISSUE = 2'd1, H_WAIT = 2'd2;
    reg [1:0]  h_state;
    reg        h_bank, h_we;
    reg [3:0]  h_sel;
    reg [8:0]  h_addr;
    reg [31:0] h_wdata;
    wire [31:0] h_rdata;
    wire       h_en = (h_state == H_ISSUE);

    wire wb_valid = wb_cyc_i && wb_stb_i;
    wire [19:0] page = wb_adr_i[31:12];

    always_ff @(posedge clk) begin
        if (reset) begin
            wb_ack_o     <= 1'b0;
            wb_dat_o     <= 32'd0;
            start_req    <= 1'b0;
            start_d1     <= 1'b0;
            start_d2     <= 1'b0;
            dcr_we       <= 1'b0;
            dcr_addr     <= 8'd0;
            dcr_data     <= 8'd0;
            rst_cnt      <= 4'd0;
            flag_oob     <= 1'b0;
            flag_blocked <= 1'b0;
            h_state      <= H_IDLE;
            h_bank       <= 1'b0;
            h_we         <= 1'b0;
            h_sel        <= 4'd0;
            h_addr       <= 9'd0;
            h_wdata      <= 32'd0;
        end else begin
            wb_ack_o <= 1'b0;
            dcr_we   <= 1'b0;
            // start reaches the GPU two cycles after the thread_count write lands in the DCR
            start_d1 <= start_req;
            start_d2 <= start_d1;
            if (rst_cnt != 4'd0) rst_cnt <= rst_cnt - 4'd1;
            if (oob_pulse) flag_oob <= 1'b1;

            case (h_state)
                H_IDLE: if (wb_valid && !wb_ack_o) begin
                    if (page == PAGE_CSR) begin
                        wb_ack_o <= 1'b1;
                        if (wb_adr_i[7:0] == 8'h00) begin
                            if (wb_we_i) begin
                                if (wb_dat_i[1]) begin
                                    // soft reset: also drops start, clears the DCR and all GPU state/caches
                                    rst_cnt   <= 4'd8;
                                    start_req <= 1'b0;
                                end else begin
                                    start_req <= wb_dat_i[0];
                                    dcr_we    <= 1'b1;
                                    dcr_addr  <= 8'h00;
                                    dcr_data  <= wb_dat_i[15:8];
                                end
                            end else begin
                                wb_dat_o <= {16'd0, dcr_data, 7'd0, start_req};
                            end
                        end else if (wb_adr_i[7:0] == 8'h04) begin
                            if (wb_we_i) begin
                                if (wb_dat_i[2]) flag_oob     <= 1'b0;
                                if (wb_dat_i[3]) flag_blocked <= 1'b0;
                            end else begin
                                wb_dat_o <= {28'd0, flag_blocked, flag_oob, run_active, gpu_done};
                            end
                        end else if (!wb_we_i) begin
                            wb_dat_o <= 32'd0;
                        end
                    end else if (page == PAGE_MEM) begin
                        if (run_active || mem_busy || rst_cnt != 4'd0) begin
                            wb_ack_o     <= 1'b1;
                            flag_blocked <= 1'b1;
                            if (!wb_we_i) wb_dat_o <= BLOCKED_DATA;
                        end else begin
                            h_bank  <= wb_adr_i[11];
                            h_addr  <= wb_adr_i[10:2];
                            h_we    <= wb_we_i;
                            h_sel   <= wb_sel_i;
                            h_wdata <= wb_dat_i;
                            h_state <= H_ISSUE;
                        end
                    end else begin
                        wb_ack_o <= 1'b1;
                        if (!wb_we_i) wb_dat_o <= 32'd0;
                    end
                end
                H_ISSUE: begin                       // SRAM sees the request this cycle
                    if (h_we) begin
                        wb_ack_o <= 1'b1;
                        h_state  <= H_IDLE;
                    end else begin
                        h_state  <= H_WAIT;
                    end
                end
                H_WAIT: begin                        // SRAM dout is valid this cycle
                    wb_dat_o <= h_rdata;
                    wb_ack_o <= 1'b1;
                    h_state  <= H_IDLE;
                end
                default: h_state <= H_IDLE;
            endcase
        end
    end

    // =========================================================================
    // On-chip memory (2 x 2 KB SRAM) and the GPU's memory channels
    // =========================================================================
    wire         pm_rv, pm_rr, dm_rv, dm_rr, dm_wv, dm_wr;
    wire [11:0]  pm_ra [1];
    wire [127:0] pm_rd [1];
    wire [13:0]  dm_ra [1], dm_wa [1];
    wire [127:0] dm_rd [1], dm_wd [1];
    wire [3:0]   dm_ws [1];

    gpu_mem_subsys mem_inst (
`ifdef USE_POWER_PINS
        .vccd1(vccd1), .vssd1(vssd1),
`endif
        .clk(clk), .reset(gpu_reset),
        .h_en(h_en), .h_bank(h_bank), .h_we(h_we), .h_sel(h_sel), .h_addr(h_addr), .h_wdata(h_wdata),
        .h_rdata(h_rdata),
        .gpu_busy(mem_busy), .oob_pulse(oob_pulse),
        .pm_rv(pm_rv), .pm_ra(pm_ra[0]), .pm_rr(pm_rr), .pm_rd(pm_rd[0]),
        .dm_rv(dm_rv), .dm_ra(dm_ra[0]), .dm_rr(dm_rr), .dm_rd(dm_rd[0]),
        .dm_wv(dm_wv), .dm_wa(dm_wa[0]), .dm_wd(dm_wd[0]), .dm_ws(dm_ws[0]), .dm_wr(dm_wr)
    );

    gpu gpu_inst (
        .clk(clk),
        .reset(gpu_reset),
        .start(gpu_start),
        .done(gpu_done),

        .device_control_write_enable(dcr_we),
        .device_control_address(dcr_addr),
        .device_control_data(dcr_data),

        .program_mem_read_valid(pm_rv),
        .program_mem_read_address(pm_ra),
        .program_mem_read_ready(pm_rr),
        .program_mem_read_data(pm_rd),

        .data_mem_read_valid(dm_rv),
        .data_mem_read_address(dm_ra),
        .data_mem_read_ready(dm_rr),
        .data_mem_read_data(dm_rd),
        .data_mem_write_valid(dm_wv),
        .data_mem_write_address(dm_wa),
        .data_mem_write_data(dm_wd),
        .data_mem_write_strobe(dm_ws),
        .data_mem_write_ready(dm_wr),

        .pmu_snap_0(),
        .pmu_snap_1(),
        .pmu_snap_2(),
        .pmu_snap_3()
    );

endmodule
