`default_nettype none
`timescale 1ns/1ns

module fetcher #(
    parameter PROGRAM_MEM_ADDR_BITS = gpu_pkg::CFG_PMEM_ADDR_BITS,
    parameter PROGRAM_MEM_DATA_BITS = gpu_pkg::CFG_PMEM_DATA_BITS
) (
    input wire clk,
    input wire reset,
    
    // Pipeline Controls
    input wire valid_request, 
    input wire consume,       
    input wire flush,
    
    input wire [PROGRAM_MEM_ADDR_BITS-1:0] current_pc,

    // Program Memory
    output wire mem_read_valid,
    output wire [PROGRAM_MEM_ADDR_BITS-1:0] mem_read_address,
    input wire mem_read_ready,
    input wire [PROGRAM_MEM_DATA_BITS-1:0] mem_read_data,

    // Fetcher Output to IF/ID Pipeline Register
    output wire instruction_valid,
    output wire [PROGRAM_MEM_DATA_BITS-1:0] instruction,
    // PC the held instruction was fetched for. The scheduler's warp selection
    // is combinational and can move to a different warp/PC while a fetch is in
    // flight; consumers must only accept `instruction` when this equals the PC
    // of the warp they are issuing.
    output wire [PROGRAM_MEM_ADDR_BITS-1:0] fetched_pc
);
    // Single-cycle fetch: the instruction cache answers a hit combinationally, so the instruction for the PC
    // the scheduler selects this cycle is available this cycle and loads into the ID latch at the clock edge
    // (one instruction per cycle on hits). A miss holds instruction_valid low until the line is filled; the
    // scheduler simply does not issue. consume and flush are no longer needed (nothing is held here).
    // The previous FSM (IDLE -> FETCHING -> DONE -> IDLE) took 4 cycles per instruction.
    assign mem_read_valid    = valid_request;
    assign mem_read_address  = current_pc;
    assign fetched_pc        = current_pc;
    assign instruction_valid = valid_request && mem_read_ready;
    assign instruction       = mem_read_data;

`ifdef MEM_TRACE
    always @(posedge clk) begin
        if (!reset && valid_request)
            $display("[%0t] [FETCH] %m req=%0d consume=%0d flush=%0d cur_pc=%0h ready=%0d",
                     $time, valid_request, consume, flush, current_pc, mem_read_ready);
    end
`endif
endmodule