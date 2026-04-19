`default_nettype none
`timescale 1ns/1ns

// REGISTER FILE (Pipeline Ready)
// > Read occurs asynchronously in the Instruction Decode (ID) stage
// > Write occurs synchronously in the Write-Back (WB) stage
module registers #(
    parameter THREADS_PER_BLOCK = 4,
    parameter THREAD_ID = 0,
    parameter DATA_BITS = 16
) (
    input wire clk,
    input wire reset,
    
    // Enable bit from the WB pipeline stage
    input wire enable, 

    // Kernel Execution
    input wire [7:0] block_id,

    // Instruction Signals (Read Addresses from ID stage, Write Address from WB stage)
    input wire [3:0] decoded_rd_address,
    input wire [3:0] decoded_rs_address,
    input wire [3:0] decoded_rt_address,

    // Control Signals (From WB Stage)
    input wire decoded_reg_write_enable,
    input wire [1:0] decoded_reg_input_mux,
    input wire [DATA_BITS-1:0] decoded_immediate,

    // Thread Unit Outputs (From WB stage)
    input wire [DATA_BITS-1:0] alu_out,
    input wire [DATA_BITS-1:0] lsu_out,

    // Registers Output (To ID stage)
    output wire [DATA_BITS-1:0] rs,
    output wire [DATA_BITS-1:0] rt
);
    localparam ARITHMETIC = 2'b00,
               MEMORY     = 2'b01,
               CONSTANT   = 2'b10,
               SHARED     = 2'b11;

    // 16 registers per thread
    reg [DATA_BITS-1:0] registers[15:0];

    // Asynchronous Read for ID stage
    assign rs = registers[decoded_rs_address];
    assign rt = registers[decoded_rt_address];

    integer i;
    always @(posedge clk) begin
        if (reset) begin
            for (i = 0; i < 13; i = i + 1) begin
                registers[i] <= {DATA_BITS{1'b0}};
            end
            registers[13] <= {DATA_BITS{1'b0}};             // %blockIdx
            registers[14] <= DATA_BITS'(THREADS_PER_BLOCK); // %blockDim
            registers[15] <= DATA_BITS'(THREAD_ID);         // %threadIdx
        end else begin 
            // Update special register continuously
            registers[13] <= {{(DATA_BITS-8){1'b0}}, block_id}; 

            // Synchronous Write for WB stage
            if (enable && decoded_reg_write_enable && decoded_rd_address < 13) begin
                case (decoded_reg_input_mux)
                    ARITHMETIC: registers[decoded_rd_address] <= alu_out;
                    MEMORY:     registers[decoded_rd_address] <= lsu_out;
                    CONSTANT:   registers[decoded_rd_address] <= decoded_immediate;
                    SHARED:     registers[decoded_rd_address] <= lsu_out;
                endcase
            end
        end
    end
endmodule