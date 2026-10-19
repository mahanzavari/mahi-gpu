`default_nettype none
`timescale 1ns/1ns

module fetcher #(
    parameter PROGRAM_MEM_ADDR_BITS = 8,
    parameter PROGRAM_MEM_DATA_BITS = 16
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
    output reg [PROGRAM_MEM_DATA_BITS-1:0] instruction
);
    typedef enum logic [1:0] { IDLE, FETCHING, DONE } state_t;
    state_t state;

    reg [PROGRAM_MEM_ADDR_BITS-1:0] fetch_pc;
    assign mem_read_address = fetch_pc;

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
                    if (consume) begin
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