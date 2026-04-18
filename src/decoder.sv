`default_nettype none
`timescale 1ns/1ns

// INSTRUCTION DECODER (Combinational for Pipelining)
// > Decodes an instruction into the control signals necessary to execute it
// > Operates in the Instruction Decode (ID) stage
module decoder #(
    parameter DATA_BITS = 16
)
(
    input wire [15:0] instruction,
    
    // Instruction Signals
    output reg [3:0] decoded_rd_address,
    output reg [3:0] decoded_rs_address,
    output reg [3:0] decoded_rt_address,
    output reg [2:0] decoded_nzp,
    output reg [DATA_BITS-1:0] decoded_immediate,
    
    // Control Signals
    output reg decoded_reg_write_enable,           
    output reg decoded_mem_read_enable,            
    output reg decoded_mem_write_enable,           
    output reg decoded_nzp_write_enable,           
    output reg [1:0] decoded_reg_input_mux,        
    output reg [2:0] decoded_alu_arithmetic_mux,   
    output reg decoded_alu_output_mux,             
    output reg decoded_pc_mux,                     
    output reg decoded_ret,
    output reg decoded_sync,
    output reg decoded_shared_read_enable,
    output reg decoded_shared_write_enable
);
    localparam NOP   = 4'b0000,
               BRnzp = 4'b0001,
               CMP   = 4'b0010,
               ADD   = 4'b0011,
               SUB   = 4'b0100,
               MUL   = 4'b0101,
               DIV   = 4'b0110,
               LDR   = 4'b0111,
               STR   = 4'b1000,
               CONST = 4'b1001,
               SYNC  = 4'b1010,
               LDSH  = 4'b1011,
               STSH  = 4'b1100,
               RET   = 4'b1111;

    always @(*) begin 
        // Default assignments to prevent latches
        decoded_rd_address = instruction[11:8];
        decoded_rs_address = instruction[7:4];
        decoded_rt_address = instruction[3:0];
        decoded_immediate  = {8'b0, instruction[7:0]};
        decoded_nzp        = instruction[11:9];

        decoded_reg_write_enable    = 0;
        decoded_mem_read_enable     = 0;
        decoded_mem_write_enable    = 0;
        decoded_nzp_write_enable    = 0;
        decoded_reg_input_mux       = 0;
        decoded_alu_arithmetic_mux  = 0;
        decoded_alu_output_mux      = 0;
        decoded_pc_mux              = 0;
        decoded_ret                 = 0;
        decoded_sync                = 0;
        decoded_shared_read_enable  = 0;
        decoded_shared_write_enable = 0;

        // Set the control signals for each instruction
        case (instruction[15:12])
            BRnzp: begin 
                decoded_pc_mux = 1;
            end
            CMP: begin 
                decoded_alu_output_mux = 1;
                decoded_nzp_write_enable = 1;
            end
            ADD: begin 
                decoded_reg_write_enable = 1;
                decoded_reg_input_mux = 2'b00;
                decoded_alu_arithmetic_mux = 2'b00;
            end
            SUB: begin 
                decoded_reg_write_enable = 1;
                decoded_reg_input_mux = 2'b00;
                decoded_alu_arithmetic_mux = 2'b01;
            end
            MUL: begin 
                decoded_reg_write_enable = 1;
                decoded_reg_input_mux = 2'b00;
                decoded_alu_arithmetic_mux = 2'b10;
            end
            DIV: begin 
                decoded_reg_write_enable = 1;
                decoded_reg_input_mux = 2'b00;
                decoded_alu_arithmetic_mux = 2'b11;
            end
            LDR: begin 
                decoded_reg_write_enable = 1;
                decoded_reg_input_mux = 2'b01;
                decoded_mem_read_enable = 1;
            end
            STR: begin 
                decoded_mem_write_enable = 1;
            end
            CONST: begin 
                decoded_reg_write_enable = 1;
                decoded_reg_input_mux = 2'b10;
            end
            SYNC: begin
                decoded_sync = 1;
            end
            LDSH: begin
                decoded_shared_read_enable  = 1'b1;
                decoded_reg_input_mux       = 2'b11;
                decoded_reg_write_enable    = 1'b1;
            end
            STSH: begin
                decoded_shared_write_enable = 1'b1;
            end
            RET: begin 
                decoded_ret = 1;
            end
            default: ; // NOP or undefined
        endcase
    end
endmodule