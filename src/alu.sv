`default_nettype none
`timescale 1ns/1ns

// ARITHMETIC-LOGIC UNIT
// > Executes computations on register values
// > In this minimal implementation, the ALU supports the 4 basic arithmetic operations
// > Each thread in each core has it's own ALU
// > ADD, SUB, MUL, DIV instructions are all executed here
module alu #(
    parameter DATA_BITS = 16
) (
    input wire clk,
    input wire reset,
    input wire enable, // If current block has less threads then block size, some ALUs will be inactive

    input reg [2:0] core_state,

    input reg [2:0] decoded_alu_arithmetic_mux,
    input reg decoded_alu_output_mux,

    input reg [DATA_BITS-1:0] rs,
    input reg [DATA_BITS-1:0] rt,
    output wire [DATA_BITS-1:0] alu_out
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

    reg [DATA_BITS-1:0] alu_out_reg;
    assign alu_out = alu_out_reg;

    always @(posedge clk) begin 
        if (reset) begin 
            alu_out_reg <= {DATA_BITS{1'b0}};
        end else if (enable) begin
            // Calculate alu_out when core_state = EXECUTE
            if (core_state == 3'b101) begin 
                if (decoded_alu_output_mux == 1) begin 
                    // Set values to compare with NZP register in alu_out[2:0]
                    alu_out_reg <= {{DATA_BITS-3{1'b0}}, (rs > rt), (rs == rt), (rs < rt)};
                end else begin 
                    // Execute the specified arithmetic instruction
                    case (decoded_alu_arithmetic_mux)
                        ADD: alu_out_reg <= rs + rt;
                        SUB: alu_out_reg <= rs - rt;
                        MUL: alu_out_reg <= rs * rt;
                        DIV: alu_out_reg <= rs / rt;
                        AND: alu_out_reg <= rs & rt;
                        OR:  alu_out_reg <= rs | rt;
                        XOR: alu_out_reg <= rs ^ rt;
                        SHL: alu_out_reg <= rs << rt[3:0];
                        SHR: alu_out_reg <= rs >> rt[3:0];
                        MOD: alu_out_reg <= rs % rt;
                        default: alu_out_reg <= {DATA_BITS{1'b0}};
                    endcase
                end
            end
        end
    end
endmodule
