`default_nettype none
`timescale 1ns/1ns

// Caravel-facing top: what user_project_wrapper instantiates (caravel/; the wrapper is hardened flat).
// Port names match the wrapper's, so the wrapper is a plain pass-through. It adds no logic to the GPU:
//   - wb_clk_i / wb_rst_i are the GPU clock and reset (one clock domain with the management SoC's Wishbone);
//     the GPU is closed at 40 ns, so the Caravel core clock must stay at or below 25 MHz.
//   - user_irq[0] = done, user_irq[1] = fault (STATUS[4]), user_irq[2] = 0.
//   - Every other output the wrapper exposes is tied off here, so the wrapper is a plain pass-through:
//     io_oeb = 1 (pads never driven by the user area), io_out = 0, la_data_out = 0.
module gpu_caravel_top (
`ifdef USE_POWER_PINS
    inout  wire         vccd1,
    inout  wire         vssd1,
`endif
    input  wire         wb_clk_i,
    input  wire         wb_rst_i,
    input  wire         wbs_stb_i,
    input  wire         wbs_cyc_i,
    input  wire         wbs_we_i,
    input  wire [3:0]   wbs_sel_i,
    input  wire [31:0]  wbs_dat_i,
    input  wire [31:0]  wbs_adr_i,
    output wire         wbs_ack_o,
    output wire [31:0]  wbs_dat_o,
    output wire [127:0] la_data_out,
    output wire [37:0]  io_out,
    output wire [37:0]  io_oeb,
    output wire [2:0]   user_irq
);
    wire done, fault;

    gpu_asic_top gpu (
`ifdef USE_POWER_PINS
        .vccd1(vccd1), .vssd1(vssd1),
`endif
        .clk(wb_clk_i), .reset(wb_rst_i),
        .wb_cyc_i(wbs_cyc_i), .wb_stb_i(wbs_stb_i), .wb_we_i(wbs_we_i), .wb_sel_i(wbs_sel_i),
        .wb_adr_i(wbs_adr_i), .wb_dat_i(wbs_dat_i), .wb_dat_o(wbs_dat_o), .wb_ack_o(wbs_ack_o),
        .gpu_done_pin(done), .gpu_fault_pin(fault));

    assign user_irq    = {1'b0, fault, done};
    assign la_data_out = 128'd0;
    assign io_out      = 38'd0;
    assign io_oeb      = {38{1'b1}};
endmodule
