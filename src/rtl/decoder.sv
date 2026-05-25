// --- Begin: src/decoder.sv ---
`default_nettype none
`timescale 1ns/1ns

module decoder #(
    parameter DATA_BITS = 32
) (
    input wire [31:0] instruction,
    
    output logic [4:0] decoded_rd_address,
    output logic [4:0] decoded_rs_address,
    output logic [4:0] decoded_rt_address,
    output logic [2:0] decoded_nzp,
    output logic [DATA_BITS-1:0] decoded_immediate,

    output logic decoded_use_mem_offset,
    output logic [15:0] decoded_mem_addr_offset,

    output logic decoded_rs_read_enable,
    output logic decoded_rt_read_enable,
    output logic decoded_rd_read_enable,
    
    output logic decoded_reg_write_enable,           
    output logic decoded_mem_read_enable,            
    output logic decoded_mem_write_enable,           
    output logic decoded_nzp_write_enable,           
    output logic [1:0] decoded_reg_input_mux,        
    output logic [4:0] decoded_alu_arithmetic_mux, // 5-bit
    output logic decoded_alu_output_mux,             
    output logic decoded_pc_mux,                     

    output logic decoded_call,
    output logic decoded_ret_fn,
    output logic decoded_exit,           
    output logic decoded_sync,
    output logic decoded_shared_read_enable,
    output logic decoded_shared_write_enable,
    output logic [1:0] decoded_atomic,     
    output logic decoded_flags_write_enable        // NEW: Flag Write Enable
);

    localparam NOP      = 6'd0,  BRnzp    = 6'd1,  CMP      = 6'd2,
               ADD      = 6'd3,  SUB      = 6'd4,  MUL      = 6'd5,
               DIV      = 6'd6,  LDR      = 6'd7,  STR      = 6'd8,
               CONST    = 6'd9,  SYNC     = 6'd10, LDSH     = 6'd11,
               STSH     = 6'd12, CALL     = 6'd13, RET_FN   = 6'd14,
               EXIT     = 6'd15, ATOM_ADD = 6'd16, AND      = 6'd17,
               OR       = 6'd18, XOR      = 6'd19, SHL      = 6'd20,
               SHR      = 6'd21, MOD      = 6'd22, MIN      = 6'd23,
               MAX      = 6'd24, ABS      = 6'd25, NEG      = 6'd26,
               MAC      = 6'd27, ATOM_CAS = 6'd28, 
               LUI      = 6'd29, POPCNT   = 6'd30, CLZ      = 6'd31,
               BREV     = 6'd32; 

    always_comb begin
        decoded_rd_address = instruction[25:21];
        decoded_rs_address = instruction[20:16];
        
        if (instruction[31:26] == STR || instruction[31:26] == STSH) begin
            decoded_rt_address = instruction[25:21];
        end else begin
            decoded_rt_address = instruction[15:11];
        end

        decoded_nzp        = instruction[25:23];
        decoded_immediate  = {{ (DATA_BITS-16){instruction[15]} }, instruction[15:0]};
        decoded_mem_addr_offset = instruction[15:0];

        // Defaults
        decoded_rs_read_enable     = 0; decoded_rt_read_enable     = 0;
        decoded_reg_write_enable   = 0; decoded_mem_read_enable    = 0;
        decoded_mem_write_enable   = 0; decoded_nzp_write_enable   = 0;
        decoded_reg_input_mux      = 2'b00; decoded_alu_arithmetic_mux = 5'b00000;
        decoded_alu_output_mux     = 0; decoded_pc_mux             = 0;
        decoded_call               = 0; decoded_ret_fn             = 0;
        decoded_exit               = 0; decoded_sync               = 0;
        decoded_shared_read_enable = 0; decoded_shared_write_enable= 0;
        decoded_use_mem_offset     = 0; decoded_atomic             = 2'b00; 
        decoded_rd_read_enable     = 0; decoded_flags_write_enable = 0;

        case (instruction[31:26])
            BRnzp: decoded_pc_mux = 1;
            CMP: begin 
                decoded_rs_read_enable = 1; decoded_rt_read_enable = 1;
                decoded_alu_output_mux = 1; decoded_nzp_write_enable = 1;
            end
            ADD: begin 
                decoded_rs_read_enable = 1; decoded_rt_read_enable = 1;
                decoded_reg_write_enable = 1; decoded_alu_arithmetic_mux = 5'd0;
                decoded_flags_write_enable = 1;
            end
            SUB: begin 
                decoded_rs_read_enable = 1; decoded_rt_read_enable = 1;
                decoded_reg_write_enable = 1; decoded_alu_arithmetic_mux = 5'd1;
                decoded_flags_write_enable = 1;
            end
            MUL: begin 
                decoded_rs_read_enable = 1; decoded_rt_read_enable = 1;
                decoded_reg_write_enable = 1; decoded_alu_arithmetic_mux = 5'd2;
                decoded_flags_write_enable = 1;
            end
            DIV: begin 
                decoded_rs_read_enable = 1; decoded_rt_read_enable = 1;
                decoded_reg_write_enable = 1; decoded_alu_arithmetic_mux = 5'd3;
                decoded_flags_write_enable = 1;
            end
            AND: begin 
                decoded_rs_read_enable = 1; decoded_rt_read_enable = 1;
                decoded_reg_write_enable = 1; decoded_alu_arithmetic_mux = 5'd4;
                decoded_flags_write_enable = 1;
            end
            OR: begin 
                decoded_rs_read_enable = 1; decoded_rt_read_enable = 1;
                decoded_reg_write_enable = 1; decoded_alu_arithmetic_mux = 5'd5;
                decoded_flags_write_enable = 1;
            end
            XOR: begin 
                decoded_rs_read_enable = 1; decoded_rt_read_enable = 1;
                decoded_reg_write_enable = 1; decoded_alu_arithmetic_mux = 5'd6;
                decoded_flags_write_enable = 1;
            end
            SHL: begin 
                decoded_rs_read_enable = 1; decoded_rt_read_enable = 1;
                decoded_reg_write_enable = 1; decoded_alu_arithmetic_mux = 5'd7;
                decoded_flags_write_enable = 1;
            end
            SHR: begin 
                decoded_rs_read_enable = 1; decoded_rt_read_enable = 1;
                decoded_reg_write_enable = 1; decoded_alu_arithmetic_mux = 5'd8;
                decoded_flags_write_enable = 1;
            end
            MOD: begin 
                decoded_rs_read_enable = 1; decoded_rt_read_enable = 1;
                decoded_reg_write_enable = 1; decoded_alu_arithmetic_mux = 5'd9;
                decoded_flags_write_enable = 1;
            end
            MIN: begin 
                decoded_rs_read_enable = 1; decoded_rt_read_enable = 1;
                decoded_reg_write_enable = 1; decoded_alu_arithmetic_mux = 5'd10;
                decoded_flags_write_enable = 1;
            end
            MAX: begin 
                decoded_rs_read_enable = 1; decoded_rt_read_enable = 1;
                decoded_reg_write_enable = 1; decoded_alu_arithmetic_mux = 5'd11;
                decoded_flags_write_enable = 1;
            end
            ABS: begin 
                decoded_rs_read_enable = 1;
                decoded_reg_write_enable = 1; decoded_alu_arithmetic_mux = 5'd12;
                decoded_flags_write_enable = 1;
            end
            NEG: begin 
                decoded_rs_read_enable = 1;
                decoded_reg_write_enable = 1; decoded_alu_arithmetic_mux = 5'd13;
                decoded_flags_write_enable = 1;
            end
            MAC: begin
                decoded_rs_read_enable   = 1; decoded_rt_read_enable   = 1;
                decoded_rd_read_enable   = 1; decoded_reg_write_enable = 1;
                decoded_alu_arithmetic_mux = 5'd14; decoded_flags_write_enable = 1;
            end
            LUI: begin
                decoded_reg_write_enable = 1; decoded_reg_input_mux = 2'b10;
                decoded_immediate = {instruction[20:1], 12'b0};
            end
            POPCNT: begin
                decoded_rs_read_enable = 1; decoded_reg_write_enable = 1;
                decoded_alu_arithmetic_mux = 5'd15; decoded_flags_write_enable = 1;
            end
            CLZ: begin
                decoded_rs_read_enable = 1; decoded_reg_write_enable = 1;
                decoded_alu_arithmetic_mux = 5'd16; decoded_flags_write_enable = 1;
            end
            BREV: begin
                decoded_rs_read_enable = 1; decoded_reg_write_enable = 1;
                decoded_alu_arithmetic_mux = 5'd17; decoded_flags_write_enable = 1;
            end
            LDR: begin
                decoded_rs_read_enable = 1; decoded_reg_write_enable = 1;
                decoded_reg_input_mux = 2'b01; decoded_mem_read_enable = 1;
                decoded_use_mem_offset = 1;
            end
            STR: begin
                decoded_rs_read_enable = 1; decoded_rt_read_enable = 1;
                decoded_mem_write_enable = 1; decoded_use_mem_offset = 1;
            end
            CONST: begin 
                decoded_reg_write_enable = 1; decoded_reg_input_mux = 2'b10;
            end
            SYNC: decoded_sync = 1;
            LDSH: begin
                decoded_rs_read_enable = 1; decoded_shared_read_enable = 1;
                decoded_reg_input_mux = 2'b11; decoded_reg_write_enable = 1;
            end
            STSH: begin
                decoded_rs_read_enable = 1; decoded_rt_read_enable = 1;
                decoded_shared_write_enable = 1;
            end
            CALL: begin decoded_call = 1; decoded_pc_mux = 1; end
            RET_FN: decoded_ret_fn = 1;
            EXIT: decoded_exit = 1;
            ATOM_ADD: begin
                decoded_rs_read_enable = 1; decoded_rt_read_enable = 1;
                decoded_reg_write_enable = 1; decoded_reg_input_mux = 2'b01; 
                decoded_atomic = 2'b01; decoded_use_mem_offset = 0;
            end
            ATOM_CAS: begin
                decoded_rs_read_enable = 1; decoded_rt_read_enable = 1;
                decoded_rd_read_enable = 1; decoded_reg_write_enable = 1; 
                decoded_reg_input_mux = 2'b01; decoded_atomic = 2'b10; 
                decoded_use_mem_offset = 0;
            end
            default: ; // NOP
        endcase
    end
endmodule
// --- End: src/decoder.sv ---