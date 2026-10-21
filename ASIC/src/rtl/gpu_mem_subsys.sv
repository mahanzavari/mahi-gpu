`default_nettype none
`timescale 1ns/1ns

// On-chip memory for gpu_asic_top: two 512x32 SRAMs (2 KB each) = the 4 KB host window.
//
//   bank 0 "PMEM": GPU instruction fetch (read only) -- GPU word addresses 0..511
//   bank 1 "DMEM": GPU loads/stores                   -- GPU word addresses 0..511
//
// The GPU side speaks the 128-bit block protocol of controller.sv (valid/ready,
// ready held until valid drops); a block is four consecutive 32-bit words, so one
// block transfer takes 5 cycles (read) or 4 (write). Block addresses >= 128 are out of
// range: reads return zero, writes are dropped, and (DMEM only) `oob_pulse` fires.
// The host side is a simple one-cycle request: the caller guarantees the GPU is idle
// (`gpu_busy` tells it when it is not); the GPU FSMs wait while `h_en` is high.
module gpu_mem_subsys (
`ifdef USE_POWER_PINS
    inout  wire         vccd1,
    inout  wire         vssd1,
`endif
    input  wire         clk,
    input  wire         reset,

    // ---- host port (from the Wishbone front end)
    input  wire         h_en,        // 1 for exactly one cycle per request
    input  wire         h_bank,      // 0 = PMEM, 1 = DMEM
    input  wire         h_we,
    input  wire [3:0]   h_sel,
    input  wire [8:0]   h_addr,      // word index within the bank
    input  wire [31:0]  h_wdata,
    output wire [31:0]  h_rdata,     // valid the cycle after an h_en read (for h_bank held)

    output wire         gpu_busy,    // a GPU memory transaction is in flight
    output reg          oob_pulse,   // DMEM access outside the 512 words

    // ---- GPU program memory channel (read only)
    input  wire         pm_rv,
    input  wire [11:0]  pm_ra,
    output reg          pm_rr,
    output reg  [127:0] pm_rd,

    // ---- GPU data memory channel
    input  wire         dm_rv,
    input  wire [13:0]  dm_ra,
    output reg          dm_rr,
    output reg  [127:0] dm_rd,
    input  wire         dm_wv,
    input  wire [13:0]  dm_wa,
    input  wire [127:0] dm_wd,
    input  wire [3:0]   dm_ws,
    output reg          dm_wr
);
    localparam S_IDLE = 3'd0, S_RD = 3'd1, S_WR = 3'd2, S_DONE = 3'd3;

    // ---------------- PMEM GPU FSM (read only)
    reg [2:0]   p_state;
    reg [2:0]   p_cnt;
    reg [6:0]   p_blk;
    reg         p_oob;
    reg [127:0] p_acc;

    wire        p_rd_issue = (p_state == S_RD) && (p_cnt < 3'd4) && !p_oob;
    wire [8:0]  p_gaddr    = {p_blk, p_cnt[1:0]};

    // ---------------- DMEM GPU FSM
    reg [2:0]   d_state;
    reg [2:0]   d_cnt;
    reg [6:0]   d_blk;
    reg         d_oob;
    reg [127:0] d_acc;
    reg [127:0] d_wdat;
    reg [3:0]   d_wstb;

    wire        d_rd_issue = (d_state == S_RD) && (d_cnt < 3'd4) && !d_oob;
    wire        d_wr_issue = (d_state == S_WR) && (d_cnt < 3'd4) && !d_oob && d_wstb[d_cnt[1:0]];
    wire [8:0]  d_gaddr    = {d_blk, d_cnt[1:0]};

    assign gpu_busy = (p_state != S_IDLE) || (d_state != S_IDLE);

    // ---------------- SRAM arbitration: the host owns the ports whenever h_en is high
    wire [31:0] p_dout0, p_dout1, d_dout0, d_dout1;
    wire        hp = h_en && !h_bank;
    wire        hd = h_en &&  h_bank;

    // PMEM: port0 = host write only, port1 = host read / GPU fetch
    wire        p_csb0 = !(hp && h_we);
    wire        p_csb1 = !((hp && !h_we) || (!h_en && p_rd_issue));
    wire [8:0]  p_a1   = hp ? h_addr : p_gaddr;

    // DMEM: port0 = host write / GPU write, port1 = host read / GPU read
    wire        d_csb0 = !((hd && h_we) || (!h_en && d_wr_issue));
    wire        d_web0 = 1'b0;
    wire [3:0]  d_wm0  = hd ? h_sel : 4'hF;
    wire [8:0]  d_a0   = hd ? h_addr : d_gaddr;
    wire [31:0] d_din0 = hd ? h_wdata : dm_wd_sel(d_wdat, d_cnt[1:0]);
    wire        d_csb1 = !((hd && !h_we) || (!h_en && d_rd_issue));
    wire [8:0]  d_a1   = hd ? h_addr : d_gaddr;

    function [31:0] dm_wd_sel(input [127:0] w, input [1:0] i);
        dm_wd_sel = w[i*32 +: 32];
    endfunction

    mahi_sram pmem (
`ifdef USE_POWER_PINS
        .vccd1(vccd1), .vssd1(vssd1),
`endif
        .clk(clk), .csb0(p_csb0), .web0(1'b0), .wmask0(h_sel), .addr0(h_addr), .din0(h_wdata), .dout0(p_dout0),
        .csb1(p_csb1), .addr1(p_a1), .dout1(p_dout1));

    mahi_sram dmem (
`ifdef USE_POWER_PINS
        .vccd1(vccd1), .vssd1(vssd1),
`endif
        .clk(clk), .csb0(d_csb0), .web0(d_web0), .wmask0(d_wm0), .addr0(d_a0), .din0(d_din0), .dout0(d_dout0),
        .csb1(d_csb1), .addr1(d_a1), .dout1(d_dout1));

    assign h_rdata = h_bank ? d_dout1 : p_dout1;

    // ---------------- GPU FSMs
    always @(posedge clk) begin
        oob_pulse <= 1'b0;
        if (reset) begin
            p_state <= S_IDLE; p_cnt <= 0; p_blk <= 0; p_oob <= 0; p_acc <= 0; pm_rr <= 0; pm_rd <= 0;
            d_state <= S_IDLE; d_cnt <= 0; d_blk <= 0; d_oob <= 0; d_acc <= 0; dm_rr <= 0; dm_rd <= 0; dm_wr <= 0;
            d_wdat <= 0; d_wstb <= 0;
        end else begin
            // ---- PMEM read
            case (p_state)
                S_IDLE: if (pm_rv && !h_en) begin
                    p_state <= S_RD; p_cnt <= 0; p_blk <= pm_ra[6:0]; p_oob <= |pm_ra[11:7]; p_acc <= 0;
                end
                S_RD: begin
                    // issue words 0..3 on cycles p_cnt=0..3; word k is sampled when p_cnt=k+1
                    if (p_cnt >= 3'd1 && p_cnt <= 3'd4 && !p_oob) p_acc[(p_cnt-3'd1)*32 +: 32] <= p_dout1;
                    p_cnt <= p_cnt + 3'd1;
                    if (p_cnt == 3'd4) begin
                        pm_rd <= p_oob ? 128'd0 : {p_dout1, p_acc[95:0]};
                        pm_rr <= 1'b1; p_state <= S_DONE;
                    end
                end
                S_DONE: if (!pm_rv) begin pm_rr <= 1'b0; p_state <= S_IDLE; end
                default: p_state <= S_IDLE;
            endcase

            // ---- DMEM read / write
            case (d_state)
                S_IDLE: if (!h_en) begin
                    if (dm_rv) begin
                        d_state <= S_RD; d_cnt <= 0; d_blk <= dm_ra[6:0]; d_oob <= |dm_ra[13:7]; d_acc <= 0;
                        if (|dm_ra[13:7]) oob_pulse <= 1'b1;
                    end else if (dm_wv) begin
                        d_state <= S_WR; d_cnt <= 0; d_blk <= dm_wa[6:0]; d_oob <= |dm_wa[13:7];
                        d_wdat <= dm_wd; d_wstb <= dm_ws;
                        if (|dm_wa[13:7]) oob_pulse <= 1'b1;
                    end
                end
                S_RD: begin
                    if (d_cnt >= 3'd1 && d_cnt <= 3'd4 && !d_oob) d_acc[(d_cnt-3'd1)*32 +: 32] <= d_dout1;
                    d_cnt <= d_cnt + 3'd1;
                    if (d_cnt == 3'd4) begin
                        dm_rd <= d_oob ? 128'd0 : {d_dout1, d_acc[95:0]};
                        dm_rr <= 1'b1; d_state <= S_DONE;
                    end
                end
                S_WR: begin
                    d_cnt <= d_cnt + 3'd1;
                    if (d_cnt == 3'd3) begin dm_wr <= 1'b1; d_state <= S_DONE; end
                end
                S_DONE: begin
                    if (dm_rr && !dm_rv) begin dm_rr <= 1'b0; d_state <= S_IDLE; end
                    if (dm_wr && !dm_wv) begin dm_wr <= 1'b0; d_state <= S_IDLE; end
                end
                default: d_state <= S_IDLE;
            endcase
        end
    end
endmodule
