`default_nettype none
`timescale 1ns/1ns

// PROGRAM COUNTER (Pipeline Ready & Warp Aware)
// > NZP updates synchronously in EX stage
// > Next PC calculation is purely combinational for the EX stage
module pc #(
    parameter DATA_MEM_DATA_BITS = 16,
    parameter PROGRAM_MEM_ADDR_BITS = 8,
    parameter NUM_WARPS = 4 // NEW: Support for multiple warps
) (
    input wire clk,
    input wire reset,
    
    // EX pipeline active mask enable & warp identification
    input wire enable, 
    input wire [$clog2(NUM_WARPS)-1:0] warp_id,

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
    // NEW: Condition codes are now maintained per warp!
    reg [2:0] nzp [NUM_WARPS-1:0];

    // Combinational Next PC logic (Evaluated in EX stage)
    always @(*) begin
        if (!enable) begin
            next_pc = current_pc;
        end else if (decoded_pc_mux == 1'b1 && ((nzp[warp_id] & decoded_nzp) != 3'b0)) begin 
            // On BRnzp instruction, branch to immediate if NZP case matches previous CMP
            next_pc = decoded_immediate[PROGRAM_MEM_ADDR_BITS-1:0];
        end else begin 
            // Default to PC + 1
            next_pc = current_pc + 1;
        end
    end

    // Synchronous state updates and logging
    integer i;
    always @(posedge clk) begin
        if (reset) begin
            for (i = 0; i < NUM_WARPS; i++) nzp[i] <= 3'b0;
        end else if (enable) begin
            // Write to NZP register on CMP instruction (From EX stage)
            if (decoded_nzp_write_enable) begin
                nzp[warp_id] <= alu_out[2:0];
                $display("[%0t] [PC] Warp %0d updated condition codes (NZP) to %b", $time, warp_id, alu_out[2:0]);
            end
            
            // Log Branch Evaluation
            if (decoded_pc_mux == 1'b1) begin
                $display("[%0t] [PC] Warp %0d evaluating Branch. Current NZP=%b, Condition=%b. Result: %s", 
                         $time, warp_id, nzp[warp_id], decoded_nzp, 
                         ((nzp[warp_id] & decoded_nzp) != 3'b0) ? "TAKEN" : "FALLTHROUGH");
            end
        end
    end

endmodule