`default_nettype none
`timescale 1ns/1ns

// ARITHMETIC-LOGIC UNIT (Combinational for Pipelining)
// > Operates in the Execute (EX) stage
module alu #(
    parameter DATA_BITS = 16
) (
    input wire enable, // Active mask bit for this thread in the EX stage
    input wire [2:0] decoded_alu_arithmetic_mux,
    input wire decoded_alu_output_mux,

    input wire [DATA_BITS-1:0] rs,
    input wire [DATA_BITS-1:0] rt,
    output reg [DATA_BITS-1:0] alu_out
);
    localparam ADD = 4'd0,
        SUB = 4'd1,
        MUL = 4'd2,
        DIV = 4'd3,
        AND = 4'd4,
        OR  = 4'd5,
        XOR = 4'd6,
        SHL = 4'd7,
        SHR = 4'd8,
        MOD = 4'd9;

    always @(*) begin 
        if (!enable) begin
            alu_out = {DATA_BITS{1'b0}};
        end else if (decoded_alu_output_mux == 1'b1) begin 
            // Set values to compare with NZP register in alu_out[2:0]
            alu_out = {{DATA_BITS-3{1'b0}}, (rs < rt), (rs == rt), (rs > rt)};
        end else begin 
            // Execute the specified arithmetic instruction
            case (decoded_alu_arithmetic_mux)
                ADD: alu_out = rs + rt;
                SUB: alu_out = rs - rt;
                MUL: alu_out = rs * rt;
                DIV: alu_out = rs / rt;
                AND: alu_out = rs & rt;
                OR:  alu_out = rs | rt;
                XOR: alu_out = rs ^ rt;
                SHL: alu_out = rs << rt[3:0];
                SHR: alu_out = rs >> rt[3:0];
                MOD: alu_out = rs % rt;
                default: alu_out = {DATA_BITS{1'b0}};
            endcase
        end
    end
endmodule