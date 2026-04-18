`default_nettype none
`timescale 1ns/1ns

// PROGRAM COUNTER (Pipeline Ready)
// > NZP updates synchronously in EX or WB stage
// > Next PC calculation is purely combinational for the EX stage
module pc #(
    parameter DATA_MEM_DATA_BITS = 16,
    parameter PROGRAM_MEM_ADDR_BITS = 8
) (
    input wire clk,
    input wire reset,
    
    // EX pipeline active mask enable
    input wire enable, 

    // Control Signals from EX stage
    input wire [2:0] decoded_nzp,
    input wire [DATA_MEM_DATA_BITS-1:0] decoded_immediate,
    input wire decoded_nzp_write_enable,
    input wire decoded_pc_mux, 

    // ALU Output from EX stage
    input wire [DATA_MEM_DATA_BITS-1:0] alu_out,

    // Current & Next PCs
    input wire [PROGRAM_MEM_ADDR_BITS-1:0] current_pc,
    output reg [PROGRAM_MEM_ADDR_BITS-1:0] next_pc
);
    reg [2:0] nzp;

    // Combinational Next PC logic (Evaluated in EX stage)
    always @(*) begin
        if (!enable) begin
            next_pc = current_pc;
        end else if (decoded_pc_mux == 1'b1 && ((nzp & decoded_nzp) != 3'b0)) begin 
            // On BRnzp instruction, branch to immediate if NZP case matches previous CMP
            next_pc = decoded_immediate[PROGRAM_MEM_ADDR_BITS-1:0];
        end else begin 
            // Default to PC + 1
            next_pc = current_pc + 1;
        end
    end

    // Synchronous state updates
    always @(posedge clk) begin
        if (reset) begin
            nzp <= 3'b0;
        end else if (enable) begin
            // Write to NZP register on CMP instruction (From EX stage)
            if (decoded_nzp_write_enable) begin
                nzp <= alu_out[2:0];
            end      
        end
    end

endmodule