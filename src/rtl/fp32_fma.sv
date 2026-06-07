`default_nettype none
`timescale 1ns/1ns

module fp32_fma (
    input  wire        clk,
    input  wire        reset,

    // Issue port
    input  wire        valid_in,
    input  wire [31:0] a_in,
    input  wire [31:0] b_in,
    input  wire [31:0] c_in,
    input  wire [1:0]  op_in,

    // Result port
    output reg         valid_out,
    output reg  [31:0] result_out
);

    wire [31:0] fp_1_0 = 32'h3F800000;
    wire [31:0] fp_0_0 = 32'h00000000;

    reg [31:0] eff_a, eff_b, eff_c;
    always_comb begin
        case(op_in)
            2'b00: begin eff_a = a_in; eff_b = b_in;   eff_c = c_in; end                       
            2'b01: begin eff_a = a_in; eff_b = fp_1_0; eff_c = b_in; end                       
            2'b10: begin eff_a = a_in; eff_b = b_in;   eff_c = fp_0_0; end                     
            2'b11: begin eff_a = a_in; eff_b = fp_1_0; eff_c = {~b_in[31], b_in[30:0]}; end    
            default: begin eff_a = a_in; eff_b = b_in; eff_c = c_in; end
        endcase
    end

    wire sign_a = eff_a[31], sign_b = eff_b[31], sign_c = eff_c[31];
    wire [7:0] exp_a = eff_a[30:23], exp_b = eff_b[30:23], exp_c = eff_c[30:23];
    wire [23:0] fract_a = (|exp_a) ? {1'b1, eff_a[22:0]} : 24'b0;
    wire [23:0] fract_b = (|exp_b) ? {1'b1, eff_b[22:0]} : 24'b0;
    wire [23:0] fract_c = (|exp_c) ? {1'b1, eff_c[22:0]} : 24'b0;

    // --- Stage 1 ---
    reg [47:0]       stg1_mult_res;
    reg signed [9:0] stg1_exp_ab;
    reg              stg1_sign_ab;
    reg [23:0]       stg1_fract_c;
    reg [7:0]        stg1_exp_c;
    reg              stg1_sign_c;
    reg              stg1_v;

    always_ff @(posedge clk) begin
        if (reset) stg1_v <= 0;
        else stg1_v <= valid_in;

        stg1_mult_res <= (48'(fract_a)) * (48'(fract_b));
        stg1_exp_ab   <= $signed({2'b0, exp_a}) + $signed({2'b0, exp_b}) - 10'sd127;
        stg1_sign_ab  <= sign_a ^ sign_b;
        stg1_fract_c  <= fract_c;
        stg1_exp_c    <= exp_c;
        stg1_sign_c   <= sign_c;
        
        if (valid_in) begin
            $display("[%0t] [FPU-IN] OP %0d | A: %h | B: %h | C: %h", $time, op_in, a_in, b_in, c_in);
        end
    end

    // --- Stage 2a ---
    reg [71:0]       stg2a_aligned_ab;
    reg [71:0]       stg2a_aligned_c;
    reg signed [9:0] stg2a_target_exp;
    reg              stg2a_sign_ab, stg2a_sign_c;
    reg              stg2a_v;

    wire signed [9:0] exp_c_signed = $signed({2'b0, stg1_exp_c});
    wire [9:0] shift_ab_gt_c = (stg1_exp_ab - exp_c_signed);
    wire [9:0] shift_c_gt_ab = (exp_c_signed - stg1_exp_ab);

    always_ff @(posedge clk) begin
        if (reset) stg2a_v <= 0;
        else stg2a_v <= stg1_v;

        stg2a_sign_ab <= stg1_sign_ab;
        stg2a_sign_c  <= stg1_sign_c;

        if (stg1_exp_ab > exp_c_signed) begin
            stg2a_target_exp <= stg1_exp_ab;
            stg2a_aligned_ab <= {stg1_mult_res, 24'b0};
            stg2a_aligned_c  <= (shift_ab_gt_c >= 72) ? 72'b0 : ({1'b0, stg1_fract_c, 47'b0} >> shift_ab_gt_c);
        end else begin
            stg2a_target_exp <= exp_c_signed;
            stg2a_aligned_c  <= {1'b0, stg1_fract_c, 47'b0};
            stg2a_aligned_ab <= (shift_c_gt_ab >= 72) ? 72'b0 : ({stg1_mult_res, 24'b0} >> shift_c_gt_ab);
        end
    end

    // --- Stage 2b ---
    reg [72:0]       stg2b_sum;
    reg              stg2b_sign;
    reg signed [9:0] stg2b_exp;
    reg              stg2b_v;

    always_ff @(posedge clk) begin
        if (reset) stg2b_v <= 0;
        else stg2b_v <= stg2a_v;

        stg2b_exp <= stg2a_target_exp;
        if (stg2a_sign_ab == stg2a_sign_c) begin
            stg2b_sum  <= stg2a_aligned_ab + stg2a_aligned_c;
            stg2b_sign <= stg2a_sign_ab;
        end else begin
            if (stg2a_aligned_ab >= stg2a_aligned_c) begin
                stg2b_sum  <= stg2a_aligned_ab - stg2a_aligned_c;
                stg2b_sign <= stg2a_sign_ab;
            end else begin
                stg2b_sum  <= stg2a_aligned_c - stg2a_aligned_ab;
                stg2b_sign <= stg2a_sign_c;
            end
        end
    end

    // --- Stage 3 ---
    reg [23:0]       stg3_norm_fract;
    reg signed [9:0] stg3_norm_exp;
    reg              stg3_sign;
    reg              stg3_v;

    logic [6:0] s3_shift_amt;
    logic [72:0] s3_shifted;
    always_comb begin
        s3_shift_amt = 7'd0;
        for (int i = 0; i <= 72; i++) begin
            if (stg2b_sum[i]) s3_shift_amt = 7'(72 - i);
        end
        s3_shifted = stg2b_sum << s3_shift_amt;
    end

    always_ff @(posedge clk) begin
        if (reset) stg3_v <= 0;
        else stg3_v <= stg2b_v;

        stg3_sign <= stg2b_sign;
        stg3_norm_fract <= (stg2b_sum == 0) ? 24'b0 : s3_shifted[72:49];
        stg3_norm_exp <= (stg2b_sum == 0) ? 10'sb0 : (stg2b_exp + 10'sd2 - $signed({3'b0, s3_shift_amt}));
    end

    // --- Stage 4 ---
    always_ff @(posedge clk) begin
        if (reset) begin
            valid_out <= 0; result_out <= 0;
        end else begin
            valid_out <= stg3_v;
            if (stg3_v) begin
                if (stg3_norm_exp <= 0) begin
                    result_out <= {stg3_sign, 31'b0};
                end else if (stg3_norm_exp >= 255) begin
                    result_out <= {stg3_sign, 8'hFF, 23'b0};
                end else begin
                    result_out <= {stg3_sign, stg3_norm_exp[7:0], stg3_norm_fract[22:0]};
                end
                $display("[%0t] [FPU-OUT] Result: %h", $time, result_out);
            end
        end
    end

endmodule