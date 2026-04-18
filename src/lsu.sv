`default_nettype none
`timescale 1ns/1ns

// LOAD-STORE UNIT (Pipeline Ready)
// > Operates in the Memory (MEM) pipeline stage
// > Handles asynchronous memory load/store operations and asserts a stall signal until ready
module lsu #(
    parameter DATA_BITS = 16
)
(
    input wire clk,
    input wire reset,
    
    // Enable bit from the MEM stage pipeline register (Active Mask)
    input wire enable, 

    // Memory Control Signals from the MEM stage pipeline register
    input wire decoded_mem_read_enable,
    input wire decoded_mem_write_enable,
    input wire decoded_shared_read_enable,
    input wire decoded_shared_write_enable,

    // Registers data from EX/MEM pipeline register
    input wire [DATA_BITS-1:0] rs,
    input wire [DATA_BITS-1:0] rt,

    // Data Memory
    output reg mem_read_valid,
    output reg [7:0] mem_read_address,
    input wire mem_read_ready,
    input wire [DATA_BITS-1:0] mem_read_data,
    
    output reg mem_write_valid,
    output reg [7:0] mem_write_address,
    output reg [DATA_BITS-1:0] mem_write_data,
    input wire mem_write_ready,

    // Shared memory                             
    output reg shared_mem_read_valid,    
    output reg [7:0] shared_mem_read_address,
    input wire shared_mem_read_ready,
    input wire [DATA_BITS-1:0] shared_mem_read_data,
    
    output reg shared_mem_write_valid,
    output reg [7:0] shared_mem_write_address,
    output reg [DATA_BITS-1:0] shared_mem_write_data,
    input wire shared_mem_write_ready,

    // LSU Outputs
    output reg stall, // Stall signal to freeze the pipeline
    output reg [DATA_BITS-1:0] lsu_out
);
    typedef enum logic [2:0] {
        IDLE,
        WAIT_G_READ,
        WAIT_G_WRITE,
        WAIT_S_READ,
        WAIT_S_WRITE
    } state_t;

    state_t state;

    // Check if the current instruction in the MEM stage is a memory operation
    wire is_mem_op = enable && (decoded_mem_read_enable || decoded_mem_write_enable || 
                                decoded_shared_read_enable || decoded_shared_write_enable);

    // Combinational Stall Logic for Pipeline Controller
    always_comb begin
        stall = 1'b0;
        if (state == IDLE && is_mem_op) begin
            stall = 1'b1; // Need to start request, stall the pipeline
        end else if (state == WAIT_G_READ && !mem_read_ready) begin
            stall = 1'b1;
        end else if (state == WAIT_G_WRITE && !mem_write_ready) begin
            stall = 1'b1;
        end else if (state == WAIT_S_READ && !shared_mem_read_ready) begin
            stall = 1'b1;
        end else if (state == WAIT_S_WRITE && !shared_mem_write_ready) begin
            stall = 1'b1;
        end
    end

    always @(posedge clk) begin
        if (reset) begin
            state <= IDLE;
            lsu_out <= {DATA_BITS{1'b0}};
            
            mem_read_valid <= 0;
            mem_read_address <= 0;
            mem_write_valid <= 0;
            mem_write_address <= 0;
            mem_write_data <= {DATA_BITS{1'b0}};
            
            shared_mem_read_valid  <= 0;      
            shared_mem_read_address <= 0;     
            shared_mem_write_valid <= 0;    
            shared_mem_write_address <= 0;
            shared_mem_write_data  <= {DATA_BITS{1'b0}};
        end else begin
            case (state)
                IDLE: begin
                    if (enable) begin
                        if (decoded_mem_read_enable) begin
                            mem_read_valid <= 1'b1;
                            mem_read_address <= rs[7:0];
                            state <= WAIT_G_READ;
                        end else if (decoded_mem_write_enable) begin
                            mem_write_valid <= 1'b1;
                            mem_write_address <= rs[7:0];
                            mem_write_data <= rt;
                            $display("LSU Write: Addr=%0d, Data=%0d", rs, rt);
                            state <= WAIT_G_WRITE;
                        end else if (decoded_shared_read_enable) begin
                            shared_mem_read_valid <= 1'b1;
                            shared_mem_read_address <= rs[7:0];
                            state <= WAIT_S_READ;
                        end else if (decoded_shared_write_enable) begin
                            shared_mem_write_valid <= 1'b1;
                            shared_mem_write_address <= rs[7:0];
                            shared_mem_write_data <= rt;
                            $display("SHARED Write: Addr=%0d, Data=%0d", rs, rt);
                            state <= WAIT_S_WRITE;
                        end
                    end
                end
                WAIT_G_READ: begin
                    if (mem_read_ready) begin
                        mem_read_valid <= 1'b0;
                        lsu_out <= mem_read_data;
                        state <= IDLE;
                    end
                end
                WAIT_G_WRITE: begin
                    if (mem_write_ready) begin
                        mem_write_valid <= 1'b0;
                        state <= IDLE;
                    end
                end
                WAIT_S_READ: begin
                    if (shared_mem_read_ready) begin
                        shared_mem_read_valid <= 1'b0;
                        lsu_out <= shared_mem_read_data;
                        state <= IDLE;
                    end
                end
                WAIT_S_WRITE: begin
                    if (shared_mem_write_ready) begin
                        shared_mem_write_valid <= 1'b0;
                        state <= IDLE;
                    end
                end
            endcase
        end
    end
endmodule