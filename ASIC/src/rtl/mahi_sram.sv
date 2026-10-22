`default_nettype none
`timescale 1ns/1ns

// 512 x 32 dual-port SRAM wrapper (1 RW port + 1 R port, 4 byte-write lanes).
// Pin-compatible with the OpenRAM macro sky130_sram_2kbyte_1rw1r_32x512_8.
//
//   MAHI_SRAM_MACRO   -> instantiate the hard macro (physical flow; blackbox in synthesis)
//   (default)         -> behavioural model with the same timing contract: inputs are
//                        sampled on the rising edge and dout is valid in the following
//                        cycle (the real macro's dout settles ~0.5 cycle + 3 ns later).
// Port 0 write and port 1 read of the same address in the same cycle are not supported
// (the macro prints a warning and returns X); gpu_mem_subsys never does that.
module mahi_sram (
`ifdef USE_POWER_PINS
    inout  wire        vccd1,
    inout  wire        vssd1,
`endif
    input  wire        clk,
    // port 0: read/write (active-low controls, as on the macro)
    input  wire        csb0,
    input  wire        web0,
    input  wire [3:0]  wmask0,
    input  wire [8:0]  addr0,
    input  wire [31:0] din0,
    output wire [31:0] dout0,
    // port 1: read only
    input  wire        csb1,
    input  wire [8:0]  addr1,
    output wire [31:0] dout1
);
`ifdef MAHI_SRAM_MACRO
    sky130_sram_2kbyte_1rw1r_32x512_8 macro (
`ifdef USE_POWER_PINS
        .vccd1(vccd1), .vssd1(vssd1),
`endif
        .clk0(clk), .csb0(csb0), .web0(web0), .wmask0(wmask0), .addr0(addr0), .din0(din0), .dout0(dout0),
        .clk1(clk), .csb1(csb1), .addr1(addr1), .dout1(dout1)
    );
`else
    reg [31:0] mem [0:511];
    reg [31:0] q0, q1;
    assign dout0 = q0;
    assign dout1 = q1;

    always @(posedge clk) begin
        if (!csb0) begin
            if (!web0) begin
                if (wmask0[0]) mem[addr0][7:0]   <= din0[7:0];
                if (wmask0[1]) mem[addr0][15:8]  <= din0[15:8];
                if (wmask0[2]) mem[addr0][23:16] <= din0[23:16];
                if (wmask0[3]) mem[addr0][31:24] <= din0[31:24];
            end else begin
                q0 <= mem[addr0];
            end
        end
        if (!csb1) q1 <= mem[addr1];
    end
`endif
endmodule
