`default_nettype none
`timescale 1ns/1ns

// Line-granular data store for l2_cache, backed by ONE 512x32 SRAM (mahi_sram) when it fits
// (LINES*WORDS <= 512, true for the ASIC profile: 64 lines x 4 words), otherwise by an equivalent
// behavioural array so the larger simulation profile keeps working.
//
//   request  : req_valid (1-cycle pulse, only when !busy), req_we, req_line, req_wdata, req_wmask
//              wmask[i] selects 32-bit word i of the 128-bit line (= one L2 sector)
//   completion: `done` is a 1-cycle pulse after the last access; for reads `rdata` is valid with it
//   timing   : write = 4 cycles (masked-off words are skipped), read = 5 cycles, then done
module l2_data_array #(
    parameter LINES = 64,
    parameter WORDS = 4,                       // 32-bit words per line (BLOCK_BITS/32)
    parameter LINE_BITS = (LINES > 1) ? $clog2(LINES) : 1
) (
    input  wire                   clk,
    input  wire                   reset,
    input  wire                   req_valid,
    input  wire                   req_we,
    input  wire [LINE_BITS-1:0]   req_line,
    input  wire [WORDS*32-1:0]    req_wdata,
    input  wire [WORDS-1:0]       req_wmask,
    output wire                   busy,
    output reg                    done,
    output reg  [WORDS*32-1:0]    rdata
);
    localparam W_BITS = $clog2(WORDS);
    localparam USE_SRAM = (LINES * WORDS <= 512);

    localparam S_IDLE = 2'd0, S_WR = 2'd1, S_RD = 2'd2;
    reg [1:0]            state;
    reg [3:0]            cnt;
    reg [LINE_BITS-1:0]  line;
    reg [WORDS*32-1:0]   wdat;
    reg [WORDS-1:0]      wmask;
    reg [WORDS*32-1:0]   acc;

    assign busy = (state != S_IDLE) || req_valid;

    wire        wr_issue = (state == S_WR) && (cnt < WORDS) && wmask[cnt[W_BITS-1:0]];
    wire        rd_issue = (state == S_RD) && (cnt < WORDS);
    wire [31:0] wr_word  = wdat[cnt[W_BITS-1:0]*32 +: 32];
    wire [LINE_BITS+W_BITS-1:0] word_addr = {line, cnt[W_BITS-1:0]};
    wire [31:0] word_addr32 = word_addr;
    wire [8:0]  waddr    = word_addr32[8:0];          // only meaningful (and used) when USE_SRAM

    wire [31:0] dout1;
    generate
        if (USE_SRAM) begin : g_sram
            mahi_sram sram (
`ifdef USE_POWER_PINS
                .vccd1(1'bz), .vssd1(1'bz),
`endif
                .clk(clk),
                .csb0(!wr_issue), .web0(1'b0), .wmask0(4'hF), .addr0(waddr), .din0(wr_word), .dout0(),
                .csb1(!rd_issue), .addr1(waddr), .dout1(dout1));
        end else begin : g_beh
            reg [31:0] mem [0:LINES*WORDS-1];
            reg [31:0] q1;
            assign dout1 = q1;
            always @(posedge clk) begin
                if (wr_issue) mem[word_addr] <= wr_word;
                if (rd_issue) q1 <= mem[word_addr];
            end
        end
    endgenerate

    always @(posedge clk) begin
        done <= 1'b0;
        if (reset) begin
            state <= S_IDLE; cnt <= 0; done <= 1'b0; rdata <= 0; acc <= 0;
        end else begin
            case (state)
                S_IDLE: if (req_valid) begin
                    line <= req_line; wdat <= req_wdata; wmask <= req_wmask; cnt <= 0; acc <= 0;
                    state <= req_we ? S_WR : S_RD;
                end
                S_WR: begin
                    cnt <= cnt + 4'd1;
                    if (cnt == WORDS - 1) begin state <= S_IDLE; done <= 1'b1; end
                end
                S_RD: begin
                    // word k is issued at cnt=k and sampled at cnt=k+1
                    if (cnt >= 1) acc[(cnt-1)*32 +: 32] <= dout1;
                    cnt <= cnt + 4'd1;
                    if (cnt == WORDS) begin
                        rdata <= {dout1, acc[(WORDS-1)*32-1:0]};
                        state <= S_IDLE; done <= 1'b1;
                    end
                end
                default: state <= S_IDLE;
            endcase
        end
    end
endmodule
