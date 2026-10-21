// Black-box declaration of the OpenRAM macro for lint / synthesis (the real views are the
// gds/lef/lib listed under MACROS in ../config.yaml). Not used for simulation.
(* blackbox *)
module sky130_sram_2kbyte_1rw1r_32x512_8 (
`ifdef USE_POWER_PINS
    inout         vccd1,
    inout         vssd1,
`endif
    input         clk0,
    input         csb0,
    input         web0,
    input  [3:0]  wmask0,
    input  [8:0]  addr0,
    input  [31:0] din0,
    output [31:0] dout0,
    input         clk1,
    input         csb1,
    input  [8:0]  addr1,
    output [31:0] dout1
);
endmodule
