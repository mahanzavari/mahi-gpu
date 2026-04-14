`default_nettype none
`timescale 1ns/1ns

// REGISTER FILE
// > Each thread within each core has it's own register file with 13 free registers and 3 read-only registers
// > Read-only registers hold the familiar %blockIdx, %blockDim, and %threadIdx values critical to SIMD
module registers #(
    parameter THREADS_PER_BLOCK = 4,
    parameter THREAD_ID = 0,
    parameter DATA_BITS = 16
) (
    input wire clk,
    input wire reset,
    input wire enable, // If current block has less threads then block size, some registers will be inactive

    // Kernel Execution
    input reg [7:0] block_id,

    // State
    input reg [2:0] core_state,

    // Instruction Signals
    input reg [3:0] decoded_rd_address,
    input reg [3:0] decoded_rs_address,
    input reg [3:0] decoded_rt_address,

    // Control Signals
    input reg decoded_reg_write_enable,
    input reg [1:0] decoded_reg_input_mux,
    input reg [DATA_BITS-1:0] decoded_immediate,

    // Thread Unit Outputs
    input reg [DATA_BITS-1:0] alu_out,
    input reg [DATA_BITS-1:0] lsu_out,

    // Registers
    output reg [DATA_BITS-1:0] rs,
    output reg [DATA_BITS-1:0] rt
);
    localparam ARITHMETIC = 2'b00,
        MEMORY = 2'b01,
        CONSTANT = 2'b10,
        SHARED   = 2'b11;

    // 16 registers per thread (13 free registers and 3 read-only registers)
    reg [7:0] registers[15:0];

    always @(posedge clk) begin
        if (reset) begin
            // Empty rs, rt
            rs <= 0;
            rt <= 0;
            // Initialize all free registers
            registers[0]  <= {DATA_BITS{1'b0}};
            registers[1]  <= {DATA_BITS{1'b0}};
            registers[2]  <= {DATA_BITS{1'b0}};
            registers[3]  <= {DATA_BITS{1'b0}};
            registers[4]  <= {DATA_BITS{1'b0}};
            registers[5]  <= {DATA_BITS{1'b0}};
            registers[6]  <= {DATA_BITS{1'b0}};
            registers[7]  <= {DATA_BITS{1'b0}};
            registers[8]  <= {DATA_BITS{1'b0}};
            registers[9]  <= {DATA_BITS{1'b0}};
            registers[10] <= {DATA_BITS{1'b0}};
            registers[11] <= {DATA_BITS{1'b0}};
            registers[12] <= {DATA_BITS{1'b0}};
            // Initialize read-only registers
            registers[13] <= {DATA_BITS{1'b0}};             // %blockIdx
            registers[14] <= DATA_BITS'(THREADS_PER_BLOCK); // %blockDim
            registers[15] <= DATA_BITS'(THREAD_ID);         // %threadIdx
        end else if (enable) begin 
            // [Bad Solution] Shouldn't need to set this every cycle
            registers[13] <= block_id; // Update the block_id when a new block is issued from dispatcher
            
            // Fill rs/rt when core_state = REQUEST
            if (core_state == 3'b011) begin 
                rs <= registers[decoded_rs_address];
                rt <= registers[decoded_rt_address];
            end

            // Store rd when core_state = UPDATE
            if (core_state == 3'b110) begin 
                // Only allow writing to R0 - R12
                if (decoded_reg_write_enable && decoded_rd_address < 13) begin
                    // debug
                    $display("Time=%0t | CoreState=%b | Thread=%0d | rd=%0d <= %0d",
                        $time, core_state, THREAD_ID, decoded_rd_address,
                        (decoded_reg_input_mux == ARITHMETIC) ? alu_out :
                        (decoded_reg_input_mux == MEMORY)     ? lsu_out :
                        decoded_immediate);

                    case (decoded_reg_input_mux)
                        ARITHMETIC: begin 
                            // ADD, SUB, MUL, DIV
                            registers[decoded_rd_address] <= alu_out;
                        end
                        MEMORY: begin 
                            // LDR
                            registers[decoded_rd_address] <= lsu_out;
                        end
                        CONSTANT: begin 
                            // CONST
                            registers[decoded_rd_address] <= decoded_immediate;
                        end
                        SHARED: begin
                            registers[decoded_rd_address] <= lsu_out;
                        end
                    endcase
                end
            end
        end
    end
endmodule
