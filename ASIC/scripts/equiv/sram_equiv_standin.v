// Equivalence stand-in for the OpenRAM macro: a deterministic function of every data/control input, so both
// netlists' macro outputs are equal exactly when their inputs are. (Same macro on both sides; this is not a model.)
module sky130_sram_2kbyte_1rw1r_32x512_8 (input clk0, input csb0, input web0, input [3:0] wmask0, input [8:0] addr0,
    input [31:0] din0, output [31:0] dout0, input clk1, input csb1, input [8:0] addr1, output [31:0] dout1);
  assign dout0 = din0 ^ {17'b0, wmask0, addr0, csb0, web0};
  assign dout1 = {22'b0, addr1, csb1} ^ {din0[15:0], din0[31:16]};
endmodule
