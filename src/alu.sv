`default_nettype none
`timescale 1ns/1ns

module alu #(
    parameter DATA_BITS = 16
) (
    input wire enable, // Active mask bit for this thread in the EX stage
    input wire [3:0] decoded_alu_arithmetic_mux,
    input wire decoded_alu_output_mux,

    input wire [DATA_BITS-1:0] rs,
    input wire [DATA_BITS-1:0] rt,
    input wire [DATA_BITS-1:0] rd_val,
    output reg [DATA_BITS-1:0] alu_out,
    output reg div_by_zero // Div0 flag EXCEPTION
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
               MOD = 4'd9,
               MIN = 4'd10,
               MAX = 4'd11,
               ABS = 4'd12,
               NEG = 4'd13,
               MAC = 4'd14;

    // always_comb, combinational logic
    always @(*) begin 
        div_by_zero = 1'b0; // Default
        
        if (!enable) begin
            alu_out = {DATA_BITS{1'b0}};
        end else if (decoded_alu_output_mux == 1'b1) begin 
            // NZP
            alu_out = {{DATA_BITS-3{1'b0}}, (rs < rt), (rs == rt), (rs > rt)};
        end else begin 
            case (decoded_alu_arithmetic_mux)
                ADD: alu_out = rs + rt;
                SUB: alu_out = rs - rt;
                MUL: alu_out = rs * rt;
                DIV: begin
                    if (rt == 0) begin
                        alu_out = {DATA_BITS{1'b0}};
                        div_by_zero = 1'b1; // Trigger DIV0 Execption
                    end else begin
                        alu_out = rs / rt;
                    end
                end
                AND: alu_out = rs & rt;
                OR:  alu_out = rs | rt;
                XOR: alu_out = rs ^ rt;
                // FIX: Support shifting for 32-bit registers by evaluating full rt
                SHL: alu_out = rs << rt;
                SHR: alu_out = rs >> rt;
                MOD: begin
                    if (rt == 0) begin
                        alu_out = {DATA_BITS{1'b0}};
                        div_by_zero = 1'b1; // Trigger Modulo 0
                    end else begin
                        alu_out = rs % rt;
                    end
                end
                MIN: alu_out = ($signed(rs) < $signed(rt)) ? rs : rt;
                MAX: alu_out = ($signed(rs) > $signed(rt)) ? rs : rt;
                ABS: alu_out = ($signed(rs) < 0) ? -$signed(rs) : rs;
                NEG: alu_out = -$signed(rs);
                MAC: alu_out = rd_val + ($signed(rs) * $signed(rt));
                default: alu_out = {DATA_BITS{1'b0}};
            endcase
        end
    end
endmodule