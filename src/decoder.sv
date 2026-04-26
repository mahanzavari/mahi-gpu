`default_nettype none
`timescale 1ns/1ns

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

    // Immediate offset addressing
    output logic decoded_use_mem_offset,
    output logic [7:0] decoded_mem_addr_offset,

    // Hazard & Forwarding
    output logic decoded_rs_read_enable,
    output logic decoded_rt_read_enable,
    
    // Control
    output logic decoded_reg_write_enable,           
    output logic decoded_mem_read_enable,            
    output logic decoded_mem_write_enable,           
    output logic decoded_nzp_write_enable,           
    output logic [1:0] decoded_reg_input_mux,        
    output logic [2:0] decoded_alu_arithmetic_mux,   
    output logic decoded_alu_output_mux,             
    output logic decoded_pc_mux,                     

    // Function call / return
    output logic decoded_call,
    output logic decoded_ret_fn,
    output logic decoded_exit,           // thread termination (was RET)
    output logic decoded_sync,
    output logic decoded_shared_read_enable,
    output logic decoded_shared_write_enable
);

    localparam NOP     = 4'b0000,
               BRnzp   = 4'b0001,
               CMP     = 4'b0010,
               ADD     = 4'b0011,
               SUB     = 4'b0100,
               MUL     = 4'b0101,
               DIV     = 4'b0110,
               LDR     = 4'b0111,
               STR     = 4'b1000,
               CONST   = 4'b1001,
               SYNC    = 4'b1010,
               LDSH    = 4'b1011,
               STSH    = 4'b1100,
               CALL    = 4'b1101,   // freed by merging LDR_IMM
               RET_FN  = 4'b1110,   // function return
               EXIT    = 4'b1111;   // thread exit (previously RET)

    always_comb begin
        // Direct field extraction
        decoded_rd_address = instruction[11:8];
        decoded_rs_address = instruction[7:4];
        decoded_rt_address = instruction[3:0];
        decoded_immediate  = {8'b0, instruction[7:0]};
        decoded_nzp        = instruction[11:9];

        // Default all control signals to zero
        decoded_rs_read_enable     = 0;
        decoded_rt_read_enable     = 0;
        decoded_reg_write_enable   = 0;
        decoded_mem_read_enable    = 0;
        decoded_mem_write_enable   = 0;
        decoded_nzp_write_enable   = 0;
        decoded_reg_input_mux      = 2'b00;
        decoded_alu_arithmetic_mux = 3'b000;
        decoded_alu_output_mux     = 0;
        decoded_pc_mux             = 0;
        decoded_call               = 0;
        decoded_ret_fn             = 0;
        decoded_exit               = 0;
        decoded_sync               = 0;
        decoded_shared_read_enable = 0;
        decoded_shared_write_enable= 0;
        decoded_use_mem_offset     = 0;
        decoded_mem_addr_offset    = 0;

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
            LDR: begin   // now LDR Rd, [Rs + imm4] – imm4 from rt field
                decoded_rs_read_enable = 1;
                decoded_reg_write_enable = 1;
                decoded_reg_input_mux = 2'b01;       // Memory
                decoded_mem_read_enable = 1;
                decoded_use_mem_offset = 1;
                decoded_mem_addr_offset = {4'b0, instruction[3:0]}; // rt field
            end
            STR: begin   // STR [Rs + imm4], Rt – imm4 from rd field
                decoded_rs_read_enable = 1;
                decoded_rt_read_enable = 1;
                decoded_mem_write_enable = 1;
                decoded_use_mem_offset = 1;
                decoded_mem_addr_offset = {4'b0, instruction[11:8]}; // rd field
            end
            CONST: begin 
                decoded_reg_write_enable = 1;
                decoded_reg_input_mux = 2'b10;       // Immediate
            end
            SYNC: begin
                decoded_sync = 1;
            end
            LDSH: begin
                decoded_rs_read_enable = 1;
                decoded_shared_read_enable = 1;
                decoded_reg_input_mux = 2'b11;       // Shared
                decoded_reg_write_enable = 1;
            end
            STSH: begin
                decoded_rs_read_enable = 1;
                decoded_rt_read_enable = 1;
                decoded_shared_write_enable = 1;
            end
            CALL: begin
                decoded_call = 1;                    // new: function call
                decoded_pc_mux = 1;                  // jump to immediate
            end
            RET_FN: begin
                decoded_ret_fn = 1;                  // function return
            end
            EXIT: begin
                decoded_exit = 1;                    // thread termination
            end
            default: ; // NOP
        endcase
    end
endmodule