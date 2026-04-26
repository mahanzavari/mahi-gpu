`default_nettype none
`timescale 1ns/1ns

module pc #(
    parameter DATA_MEM_DATA_BITS = 16,
    parameter PROGRAM_MEM_ADDR_BITS = 8,
    parameter NUM_WARPS = 4
) (
    input wire clk,
    input wire reset,
    
    input wire enable,
    input wire [$clog2(NUM_WARPS)-1:0] warp_id,

    // Control Signals from EX stage
    input wire [2:0] decoded_nzp,
    input wire [DATA_MEM_DATA_BITS-1:0] decoded_immediate,
    input wire decoded_nzp_write_enable,
    input wire decoded_pc_mux,
    input wire decoded_call,          // new
    input wire decoded_ret_fn,        // new

    input wire [DATA_MEM_DATA_BITS-1:0] alu_out,
    input wire [PROGRAM_MEM_ADDR_BITS-1:0] current_pc,
    output reg [PROGRAM_MEM_ADDR_BITS-1:0] next_pc
);

    // Per‑warp condition codes (unchanged)
    reg [2:0] nzp [NUM_WARPS-1:0];

    // ─── Hardware return stack (per warp) ───
    localparam STACK_DEPTH = 8;
    reg [PROGRAM_MEM_ADDR_BITS-1:0] return_stack [NUM_WARPS-1:0][STACK_DEPTH-1:0];
    reg [$clog2(STACK_DEPTH)-1:0]   stack_ptr    [NUM_WARPS-1:0];

    // Combinational next PC
    always @(*) begin
        if (!enable) begin
            next_pc = current_pc;
        end else if (decoded_call) begin
            // Unconditional jump; push return address in sequential block
            next_pc = decoded_immediate[PROGRAM_MEM_ADDR_BITS-1:0];
        end else if (decoded_ret_fn) begin
            // Pop stack
            next_pc = return_stack[warp_id][stack_ptr[warp_id] - 1];
        end else if (decoded_pc_mux && ((nzp[warp_id] & decoded_nzp) != 3'b0)) begin
            next_pc = decoded_immediate[PROGRAM_MEM_ADDR_BITS-1:0];
        end else begin
            next_pc = current_pc + 1;
        end
    end

    // Sequential state: NZP, stack push/pop
    integer i;
    always @(posedge clk) begin
        if (reset) begin
            for (i = 0; i < NUM_WARPS; i++) begin
                nzp[i] <= 3'b0;
                stack_ptr[i] <= 0;
                // Stack entries do not need explicit reset (undefined until used)
            end
        end else if (enable) begin
            // NZP update (CMP)
            if (decoded_nzp_write_enable) begin
                nzp[warp_id] <= alu_out[2:0];
                $display("[%0t] [PC] Warp %0d NZP <- %b", $time, warp_id, alu_out[2:0]);
            end

            // Function CALL: push return address
            if (decoded_call) begin
                return_stack[warp_id][stack_ptr[warp_id]] <= current_pc + 1;
                stack_ptr[warp_id] <= stack_ptr[warp_id] + 1;
                $display("[%0t] [PC] Warp %0d CALL: storing ret addr %0d (sp=%0d -> %0d)",
                         $time, warp_id, current_pc+1, stack_ptr[warp_id], stack_ptr[warp_id]+1);
            end

            // Function RET: pop (combinational read already used)
            if (decoded_ret_fn) begin
                stack_ptr[warp_id] <= stack_ptr[warp_id] - 1;
                $display("[%0t] [PC] Warp %0d RET: popping, sp %0d -> %0d, ret to %0d",
                         $time, warp_id, stack_ptr[warp_id], stack_ptr[warp_id]-1,
                         return_stack[warp_id][stack_ptr[warp_id]-1]);
            end

            // Branch logging (unchanged)
            if (decoded_pc_mux && !decoded_call) begin
                $display("[%0t] [PC] Warp %0d BR: NZP=%b Cond=%b %s", 
                         $time, warp_id, nzp[warp_id], decoded_nzp,
                         ((nzp[warp_id] & decoded_nzp) != 3'b0) ? "TAKEN" : "FALLTHROUGH");
            end
        end
    end
endmodule