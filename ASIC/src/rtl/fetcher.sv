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
    output reg mem_read_valid,
    output wire [PROGRAM_MEM_ADDR_BITS-1:0] mem_read_address,
    input wire mem_read_ready,
    input wire [PROGRAM_MEM_DATA_BITS-1:0] mem_read_data,

    // Fetcher Output to IF/ID Pipeline Register
    output reg instruction_valid,
    output reg [PROGRAM_MEM_DATA_BITS-1:0] instruction,
    // PC the held instruction was fetched for. The scheduler's warp selection
    // is combinational and can move to a different warp/PC while a fetch is in
    // flight; consumers must only accept `instruction` when this equals the PC
    // of the warp they are issuing.
    output wire [PROGRAM_MEM_ADDR_BITS-1:0] fetched_pc
);
    typedef enum logic [1:0] { IDLE, FETCHING, DONE } state_t;
    state_t state;

    reg [PROGRAM_MEM_ADDR_BITS-1:0] fetch_pc;
    assign mem_read_address = fetch_pc;
    assign fetched_pc = fetch_pc;

`ifdef MEM_TRACE
    always @(posedge clk) begin
        if (!reset && (flush || state != IDLE || valid_request))
            $display("[%0t] [FETCH] %m st=%0d req=%0d consume=%0d flush=%0d cur_pc=%0h fetch_pc=%0h mrv=%0d mrr=%0d ivalid=%0d",
                     $time, state, valid_request, consume, flush, current_pc, fetch_pc, mem_read_valid, mem_read_ready, instruction_valid);
    end
`endif

    always @(posedge clk) begin
        if (reset || flush) begin
            state <= IDLE;
            mem_read_valid <= 0;
            instruction_valid <= 0;
            instruction <= {PROGRAM_MEM_DATA_BITS{1'b0}};
            fetch_pc <= 0;
        end else begin
            case (state)
                IDLE: begin
                    instruction_valid <= 0;
                    if (valid_request) begin
                        state <= FETCHING;
                        mem_read_valid <= 1;
                        fetch_pc <= current_pc;
                    end
                end
                FETCHING: begin
                    if (mem_read_ready) begin
                        state <= DONE;
                        mem_read_valid <= 0;
                        instruction_valid <= 1;
                        instruction <= mem_read_data;
                    end
                end
                DONE: begin
                    if (!consume && valid_request && current_pc != fetch_pc) begin
                        // Selected warp/PC changed after this fetch completed:
                        // drop the stale instruction and refetch for the new PC.
                        state <= IDLE;
                        instruction_valid <= 0;
                    end else if (consume) begin
                        // Transition to IDLE for 1 cycle so the Scheduler 
                        // can update current_pc to the next address!
                        state <= IDLE;
                        instruction_valid <= 0;
                    end else begin
                        instruction_valid <= 1;
                    end
                end
            endcase
        end
    end
endmodule