`default_nettype none
`timescale 1ns/1ns

// INSTRUCTION DECODER (Pipelined with Hazard Support)
// > Purely combinational. Immediately decodes the instruction for the ID stage.
module decoder #(
    parameter DATA_BITS = 16
) (
    input wire [15:0] instruction,
    
    // Instruction Signals
    output logic [3:0] decoded_rd_address,
    output logic [3:0] decoded_rs_address,
    output logic [3:0] decoded_rt_address,
    output logic [2:0] decoded_nzp,
    output logic [DATA_BITS-1:0] decoded_immediate,

    // Hazard & Forwarding Signals
    output logic decoded_rs_read_enable,
    output logic decoded_rt_read_enable,
    
    // Control Signals
    output logic decoded_reg_write_enable,           
    output logic decoded_mem_read_enable,            
    output logic decoded_mem_write_enable,           
    output logic decoded_nzp_write_enable,           
    output logic [1:0] decoded_reg_input_mux,        
    output logic [2:0] decoded_alu_arithmetic_mux,   
    output logic decoded_alu_output_mux,             
    output logic decoded_pc_mux,                     

    // Sync/Shared/Return
    output logic decoded_ret,
    output logic decoded_sync,
    output logic decoded_shared_read_enable,
    output logic decoded_shared_write_enable
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

    always_comb begin 
        // 1. Direct Field Extraction
        decoded_rd_address = instruction[11:8];
        decoded_rs_address = instruction[7:4];
        decoded_rt_address = instruction[3:0];
        decoded_immediate  = {8'b0, instruction[7:0]};
        decoded_nzp        = instruction[11:9];

        // 2. Default Control Signals (Prevents Latches)
        decoded_rs_read_enable      = 0;
        decoded_rt_read_enable      = 0;
        decoded_reg_write_enable    = 0;
        decoded_mem_read_enable     = 0;
        decoded_mem_write_enable    = 0;
        decoded_nzp_write_enable    = 0;
        decoded_reg_input_mux       = 2'b00;
        decoded_alu_arithmetic_mux  = 3'b000;
        decoded_alu_output_mux      = 0;
        decoded_pc_mux              = 0;
        decoded_ret                 = 0;
        decoded_sync                = 0;
        decoded_shared_read_enable  = 0;
        decoded_shared_write_enable = 0;

        // 3. Set specific control signals per opcode
        case (instruction[15:12])
            BRnzp: begin 
                decoded_pc_mux = 1;
            end
            CMP: begin 
                decoded_rs_read_enable = 1;
                decoded_rt_read_enable = 1;
                decoded_alu_output_mux = 1;
                decoded_nzp_write_enable = 1;
            end
            ADD: begin 
                decoded_rs_read_enable = 1;
                decoded_rt_read_enable = 1;
                decoded_reg_write_enable = 1;
                decoded_alu_arithmetic_mux = 3'b000; // ADD
            end
            SUB: begin 
                decoded_rs_read_enable = 1;
                decoded_rt_read_enable = 1;
                decoded_reg_write_enable = 1;
                decoded_alu_arithmetic_mux = 3'b001; // SUB
            end
            MUL: begin 
                decoded_rs_read_enable = 1;
                decoded_rt_read_enable = 1;
                decoded_reg_write_enable = 1;
                decoded_alu_arithmetic_mux = 3'b010; // MUL
            end
            DIV: begin 
                decoded_rs_read_enable = 1;
                decoded_rt_read_enable = 1;
                decoded_reg_write_enable = 1;
                decoded_alu_arithmetic_mux = 3'b011; // DIV
            end
            LDR: begin 
                decoded_rs_read_enable = 1;          // Only uses rs for address based on LSU
                decoded_reg_write_enable = 1;
                decoded_reg_input_mux = 2'b01;       // Select Memory
                decoded_mem_read_enable = 1;
            end
            STR: begin 
                decoded_rs_read_enable = 1;          // Address
                decoded_rt_read_enable = 1;          // Data to store
                decoded_mem_write_enable = 1;
            end
            CONST: begin 
                decoded_reg_write_enable = 1;
                decoded_reg_input_mux = 2'b10;       // Select Immediate
            end
            SYNC: begin
                decoded_sync = 1;
            end
            LDSH: begin
                decoded_rs_read_enable = 1;
                decoded_shared_read_enable = 1;
                decoded_reg_input_mux = 2'b11;       // Select Shared Memory
                decoded_reg_write_enable = 1;
            end
            STSH: begin
                decoded_rs_read_enable = 1;
                decoded_rt_read_enable = 1;
                decoded_shared_write_enable = 1;
            end
            RET: begin 
                decoded_ret = 1;
            end
            default: ; // NOP
        endcase
    end
endmodule