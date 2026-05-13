// --- Begin: src/alu.sv ---
`default_nettype none
`timescale 1ns/1ns

module alu #(
    parameter DATA_BITS = 16
) (
    input wire enable,
    input wire [4:0] decoded_alu_arithmetic_mux, // 5-bit to support new ops
    input wire decoded_alu_output_mux,

    input wire [DATA_BITS-1:0] rs,
    input wire [DATA_BITS-1:0] rt,
    input wire [DATA_BITS-1:0] rd_val,
    
    output reg [DATA_BITS-1:0] alu_out,
    output reg div_by_zero, // Div0 flag EXCEPTION
    
    // --- ALU Flags ---
    output reg flag_c,      // Carry
    output reg flag_v,      // Overflow
    output reg flag_z,      // Zero
    output reg flag_n,      // Negative
    output reg flag_sat     // Saturation
);
    localparam ADD    = 5'd0,  SUB  = 5'd1,  MUL = 5'd2,  DIV = 5'd3,
               AND    = 5'd4,  OR   = 5'd5,  XOR = 5'd6,  SHL = 5'd7,
               SHR    = 5'd8,  MOD  = 5'd9,  MIN = 5'd10, MAX = 5'd11,
               ABS    = 5'd12, NEG  = 5'd13, MAC = 5'd14, 
               POPCNT = 5'd15, CLZ  = 5'd16, BREV= 5'd17;

    always @(*) begin 
        logic signed [DATA_BITS-1:0] min_val;
        logic signed [DATA_BITS-1:0] max_val;
        logic [DATA_BITS:0] ext_add;
        logic [DATA_BITS:0] ext_sub;
        logic signed [DATA_BITS*2-1:0] ext_mul;
        logic signed [DATA_BITS*2:0] ext_mac;

        min_val = {1'b1, {(DATA_BITS-1){1'b0}}};
        max_val = {1'b0, {(DATA_BITS-1){1'b1}}};
        
        ext_add = {1'b0, rs} + {1'b0, rt};
        ext_sub = {1'b0, rs} - {1'b0, rt};
        ext_mul = $signed(rs) * $signed(rt);
        ext_mac = $signed(rd_val) + ext_mul;

        div_by_zero = 1'b0; 
        flag_c = 1'b0; flag_v = 1'b0; flag_sat = 1'b0; flag_z = 1'b0; flag_n = 1'b0;
        
        if (!enable) begin
            alu_out = {DATA_BITS{1'b0}};
        end else if (decoded_alu_output_mux == 1'b1) begin 
            alu_out = {{DATA_BITS-3{1'b0}}, (rs < rt), (rs == rt), (rs > rt)};
        end else begin 
            case (decoded_alu_arithmetic_mux)
                ADD: begin
                    alu_out = ext_add[DATA_BITS-1:0];
                    flag_c  = ext_add[DATA_BITS];
                    flag_v  = (~(rs[DATA_BITS-1] ^ rt[DATA_BITS-1])) & (rs[DATA_BITS-1] ^ alu_out[DATA_BITS-1]);
                    if (flag_v) flag_sat = 1'b1;
                end
                SUB: begin
                    alu_out = ext_sub[DATA_BITS-1:0];
                    flag_c  = ext_sub[DATA_BITS];
                    flag_v  = (rs[DATA_BITS-1] ^ rt[DATA_BITS-1]) & (rs[DATA_BITS-1] ^ alu_out[DATA_BITS-1]);
                    if (flag_v) flag_sat = 1'b1;
                end
                MUL: begin
                    alu_out = ext_mul[DATA_BITS-1:0];
                    if (ext_mul > max_val || ext_mul < min_val) begin
                        flag_v = 1'b1; flag_sat = 1'b1;
                    end
                end
                DIV: begin
                    if (rt == 0) begin
                        alu_out = {DATA_BITS{1'b0}}; div_by_zero = 1'b1;
                    end else alu_out = rs / rt;
                end
                AND: alu_out = rs & rt;
                OR:  alu_out = rs | rt;
                XOR: alu_out = rs ^ rt;
                SHL: begin
                    alu_out = rs << rt;
                    if (rt > 0 && rt <= DATA_BITS) flag_c = rs[DATA_BITS - rt];
                end
                SHR: begin
                    alu_out = rs >> rt;
                    if (rt > 0 && rt <= DATA_BITS) flag_c = rs[rt - 1];
                end
                MOD: begin
                    if (rt == 0) begin
                        alu_out = {DATA_BITS{1'b0}}; div_by_zero = 1'b1;
                    end else alu_out = rs % rt;
                end
                MIN: alu_out = ($signed(rs) < $signed(rt)) ? rs : rt;
                MAX: alu_out = ($signed(rs) > $signed(rt)) ? rs : rt;
                ABS: alu_out = ($signed(rs) < 0) ? -$signed(rs) : rs;
                NEG: begin
                    alu_out = -$signed(rs);
                    if ($signed(rs) == min_val) begin
                        flag_v = 1'b1; flag_sat = 1'b1;
                    end
                end
                MAC: begin
                    alu_out = ext_mac[DATA_BITS-1:0];
                    if (ext_mac > max_val || ext_mac < min_val) begin
                        flag_v = 1'b1; flag_sat = 1'b1;
                    end
                end
                POPCNT: begin
                    alu_out = {DATA_BITS{1'b0}};
                    for (int b = 0; b < DATA_BITS; b++) alu_out = alu_out + rs[b];
                end
                CLZ: begin
                    alu_out = DATA_BITS;
                    for (int n = 0; n < DATA_BITS; n++) if (rs[n]) alu_out = (DATA_BITS-1) - n;
                end
                BREV: begin
                    for (int b = 0; b < DATA_BITS; b++) alu_out[b] = rs[DATA_BITS-1-b];
                end
                default: alu_out = {DATA_BITS{1'b0}};
            endcase
            
            // Standardise Zero and Negative flags for all ops
            flag_z = (alu_out == {DATA_BITS{1'b0}});
            flag_n = alu_out[DATA_BITS-1];
        end
    end
endmodule
// --- End: src/alu.sv ---