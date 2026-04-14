`default_nettype none
`timescale 1ns/1ns

// LOAD-STORE UNIT
// > Handles asynchronous memory load and store operations and waits for response
// > Each thread in each core has it's own LSU
// > LDR, STR instructions are executed here
module lsu #(
    parameter DATA_BITS = 16
)
(
    input wire clk,
    input wire reset,
    input wire enable, // If current block has less threads then block size, some LSUs will be inactive

    // State
    input reg [2:0] core_state,

    // Memory Control Sgiansl
    input reg decoded_mem_read_enable,
    input reg decoded_mem_write_enable,

    // Registers
    input reg [DATA_BITS-1:0] rs,
    input reg [DATA_BITS-1:0] rt,

    // Data Memory
    output reg mem_read_valid,
    output reg [7:0] mem_read_address,
    input reg mem_read_ready,
    input reg [DATA_BITS-1:0] mem_read_data,
    output reg mem_write_valid,
    output reg [7:0] mem_write_address,
    output reg [DATA_BITS-1:0] mem_write_data,
    input reg mem_write_ready,

    // shared memory                             
    input reg decoded_shared_read_enable,
    input reg decoded_shared_write_enable,
    output reg shared_mem_read_valid,    
    output reg [7:0] shared_mem_read_address,
    input reg shared_mem_read_ready,
    input reg [DATA_BITS-1:0] shared_mem_read_data,
    output reg shared_mem_write_valid,
    output reg [7:0] shared_mem_write_address,
    output reg [DATA_BITS-1:0] shared_mem_write_data,
    input reg shared_mem_write_ready,

    // LSU Outputs
    output reg [1:0] lsu_state,
    output reg [DATA_BITS-1:0] lsu_out
);
    localparam IDLE = 2'b00, REQUESTING = 2'b01, WAITING = 2'b10, DONE = 2'b11;
    reg [1:0] slsu_state;

    always @(posedge clk) begin
        if (reset) begin
            lsu_state  <= IDLE;
            slsu_state <= IDLE;
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
        end else if (enable) begin
            // Global memory state machine (unchanged)
            // ----------------------------------------------------            
            // If memory read enable is triggered (LDR instruction)
            if (decoded_mem_read_enable) begin 
                case (lsu_state)
                    IDLE: begin
                        // Only read when core_state = REQUEST
                        if (core_state == 3'b011) begin 
                            lsu_state <= REQUESTING;
                        end
                    end
                    REQUESTING: begin 
                        mem_read_valid <= 1;
                        mem_read_address <= rs;
                        lsu_state <= WAITING;
                    end
                    WAITING: begin
                        if (mem_read_ready == 1) begin
                            mem_read_valid <= 0;
                            lsu_out <= mem_read_data;
                            lsu_state <= DONE;
                        end
                    end
                    DONE: begin 
                        // Reset when core_state = UPDATE
                        if (core_state == 3'b110) begin 
                            lsu_state <= IDLE;
                        end
                    end
                endcase
            end

            // If memory write enable is triggered (STR instruction)
            if (decoded_mem_write_enable) begin 
                case (lsu_state)
                    IDLE: begin
                        // Only read when core_state = REQUEST
                        if (core_state == 3'b011) begin 
                            lsu_state <= REQUESTING;
                        end
                    end
                    REQUESTING: begin 
                        mem_write_valid <= 1;
                        mem_write_address <= rs;
                        mem_write_data <= rt;

                        $display("LSU Write: Addr=%0d, Data=%0d", rs, rt);
                        lsu_state <= WAITING;
                    end
                    WAITING: begin
                        if (mem_write_ready) begin
                            mem_write_valid <= 0;
                            lsu_state <= DONE;
                        end
                    end
                    DONE: begin 
                        // Reset when core_state = UPDATE
                        if (core_state == 3'b110) begin 
                            lsu_state <= IDLE;
                        end
                    end
                endcase
            end
            // Shared memory state machine
            // ---------------------------
            if (decoded_shared_read_enable) begin
                case (slsu_state)
                    IDLE: begin
                        if (core_state == 3'b011)
                            slsu_state <= REQUESTING;
                    end
                    REQUESTING: begin
                        shared_mem_read_valid   <= 1;
                        shared_mem_read_address <= rs;
                        slsu_state              <= WAITING;
                    end
                    WAITING: begin
                        if (shared_mem_read_ready) begin
                            shared_mem_read_valid <= 0;
                            lsu_out               <= shared_mem_read_data;
                            slsu_state            <= DONE;
                        end
                    end
                    DONE: begin
                        if (core_state == 3'b110)
                            slsu_state <= IDLE;
                    end
                    default: ;
                endcase
            end
            if (decoded_shared_write_enable) begin
                case (slsu_state)
                    IDLE: begin
                        if (core_state == 3'b011)
                            slsu_state <= REQUESTING;
                    end 
                    REQUESTING: begin
                        shared_mem_write_valid <= 1'b1;
                        shared_mem_write_address <= rs;
                        shared_mem_write_data    <= rt;

                        $display("SHARED Write: Addr=%0d, Data=%0d", rs, rt);

                        slsu_state <= WAITING;
                    end
                    WAITING: begin
                        if (shared_mem_write_ready) begin
                            shared_mem_write_valid <= 1'b0;
                            slsu_state <= DONE;
                        end
                    end
                    DONE: begin
                        if (core_state == 3'b110)
                            slsu_state <= IDLE;
                    end
                    default: ;
                endcase
            end
        end
    end
endmodule
