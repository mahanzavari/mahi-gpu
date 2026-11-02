`default_nettype none
`timescale 1ns/1ns

// Shared, iterative, unsigned 32-bit divider for DIV/MOD (one instance per core, used by all lanes).
//
// Cheap by design: one subtract-compare per cycle (radix-2 restoring), lanes processed one after another.
//   * per lane: count-leading-zeros normalisation, then (DATA_BITS - clz) cycles; a zero dividend takes 1 cycle
//   * worst case per instruction ~ LANES * (DATA_BITS + 1) cycles (66 on the mini profile, 132 on the full one)
//   * state: operands + results per lane, plus remainder/quotient/divisor work registers
// Protocol (driven by core.sv, same long-latency path as the FMA):
//   start   : 1-cycle pulse with the operands; only when !busy (the core stalls a second DIV in ID)
//   done    : held high with result/out_* valid until ack
//   ack     : 1-cycle pulse when the result was written back (the core writes it through the long-latency port)
// Division by zero never reaches the divider (the ALU raises the exception and the warp faults); if it did,
// the result is the all-ones quotient / the dividend as remainder and the unit still terminates.
module divider #(
    parameter LANES     = 4,
    parameter DATA_BITS = 32,
    parameter WARP_BITS = 1
) (
    input  wire                 clk,
    input  wire                 reset,
    input  wire                 start,
    input  wire                 is_mod,
    input  wire [LANES-1:0]     mask,
    input  wire [WARP_BITS-1:0] warp,
    input  wire [4:0]           rd,
    input  wire [DATA_BITS-1:0] a [LANES],
    input  wire [DATA_BITS-1:0] b [LANES],
    output wire                 busy,
    output reg                  done,
    input  wire                 ack,
    output reg  [DATA_BITS-1:0] result [LANES],
    output reg  [LANES-1:0]     out_mask,
    output reg  [WARP_BITS-1:0] out_warp,
    output reg  [4:0]           out_rd
);
    localparam CNT_BITS  = $clog2(DATA_BITS + 1);
    localparam LANE_BITS = (LANES > 1) ? $clog2(LANES) : 1;
    localparam S_IDLE = 2'd0, S_NEXT = 2'd1, S_RUN = 2'd2, S_DONE = 2'd3;

    reg [1:0]           state;
    reg                 mod_q;
    reg [DATA_BITS-1:0] opa [LANES];
    reg [DATA_BITS-1:0] opb [LANES];
    reg [LANES-1:0]     pend;
    reg [LANE_BITS-1:0] cur;
    reg [DATA_BITS-1:0] quo, rem, dvs;
    reg [CNT_BITS-1:0]  cnt;

    assign busy = (state != S_IDLE);

    // lowest pending lane
    reg [LANE_BITS-1:0] next_lane;
    integer k;
    always @(*) begin
        next_lane = 0;
        for (k = LANES - 1; k >= 0; k = k - 1) if (pend[k]) next_lane = k[LANE_BITS-1:0];
    end

    // count leading zeros of the selected dividend (normalisation = the early-out)
    wire [DATA_BITS-1:0] dividend = opa[next_lane];
    reg  [CNT_BITS-1:0]  clz;
    integer z;
    always @(*) begin
        clz = DATA_BITS[CNT_BITS-1:0];
        for (z = 0; z < DATA_BITS; z = z + 1) if (dividend[z]) clz = DATA_BITS - 1 - z;
    end

    // one restoring step
    wire [DATA_BITS:0]   rem_s  = {rem, quo[DATA_BITS-1]};
    wire                 ge     = (rem_s >= {1'b0, dvs});
    wire [DATA_BITS:0]   rem_d  = rem_s - {1'b0, dvs};
    wire [DATA_BITS-1:0] rem_n  = ge ? rem_d[DATA_BITS-1:0] : rem_s[DATA_BITS-1:0];
    wire [DATA_BITS-1:0] quo_n  = {quo[DATA_BITS-2:0], ge};

    integer i;
    always @(posedge clk) begin
        if (reset) begin
            state <= S_IDLE; done <= 1'b0; pend <= 0; out_mask <= 0; out_warp <= 0; out_rd <= 0;
            mod_q <= 1'b0; cur <= 0; quo <= 0; rem <= 0; dvs <= 0; cnt <= 0;
            for (i = 0; i < LANES; i = i + 1) begin result[i] <= 0; opa[i] <= 0; opb[i] <= 0; end
        end else begin
            case (state)
                S_IDLE: if (start) begin
                    for (i = 0; i < LANES; i = i + 1) begin opa[i] <= a[i]; opb[i] <= b[i]; result[i] <= 0; end
                    pend <= mask; out_mask <= mask; out_warp <= warp; out_rd <= rd; mod_q <= is_mod;
                    state <= S_NEXT;
                end
                S_NEXT: begin
                    if (pend == 0) begin
                        done <= 1'b1; state <= S_DONE;
                    end else if (dividend == 0) begin
                        result[next_lane] <= 0;                       // 0 / x = 0, 0 % x = 0
                        pend[next_lane] <= 1'b0;
                    end else begin
                        cur <= next_lane;
                        quo <= dividend << clz;                       // MSB-aligned; low bits become the quotient
                        rem <= 0;
                        dvs <= opb[next_lane];
                        cnt <= DATA_BITS - clz;
                        state <= S_RUN;
                    end
                end
                S_RUN: begin
                    quo <= quo_n; rem <= rem_n; cnt <= cnt - 1'b1;
                    if (cnt == 1) begin
                        result[cur] <= mod_q ? rem_n : quo_n;
                        pend[cur] <= 1'b0;
                        state <= S_NEXT;
                    end
                end
                S_DONE: if (ack) begin
                    done <= 1'b0; state <= S_IDLE;
                end
                default: state <= S_IDLE;
            endcase
        end
    end
endmodule
