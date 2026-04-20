`default_nettype none
`timescale 1ns/1ns

module registers #(
    parameter THREADS_PER_BLOCK = 4,
    parameter NUM_WARPS = 4,
    parameter DATA_BITS = 16
) (
    input wire clk,
    input wire reset,
    
    // Synchronous Pipeline Write Port (from WB stage)
    input wire enable, 
    input wire [$clog2(NUM_WARPS)-1:0] warp_id, 
    input wire [7:0] block_id,
    input wire [7:0] thread_id, 

    input wire [3:0] decoded_rd_address,
    input wire [3:0] decoded_rs_address,
    input wire [3:0] decoded_rt_address,

    input wire decoded_reg_write_enable,
    input wire [1:0] decoded_reg_input_mux,
    input wire [DATA_BITS-1:0] decoded_immediate,

    input wire [DATA_BITS-1:0] alu_out,
    input wire [DATA_BITS-1:0] lsu_out,

    // Asynchronous LSU Write Port (from Memory Controller)
    input wire lsu_we,
    input wire [$clog2(NUM_WARPS)-1:0] lsu_warp_id,
    input wire [3:0] lsu_rd,
    input wire [DATA_BITS-1:0] lsu_data,

    output wire [DATA_BITS-1:0] rs,
    output wire [DATA_BITS-1:0] rt
);
    localparam ARITHMETIC = 2'b00,
               MEMORY     = 2'b01,
               CONSTANT   = 2'b10,
               SHARED     = 2'b11;

    reg [DATA_BITS-1:0] registers [NUM_WARPS-1:0][15:0];

    wire [DATA_BITS-1:0] write_data = (decoded_reg_input_mux == ARITHMETIC) ? alu_out :
                                      (decoded_reg_input_mux == MEMORY)     ? lsu_out :
                                      (decoded_reg_input_mux == CONSTANT)   ? decoded_immediate :
                                                                              lsu_out;

    wire is_writing = enable && decoded_reg_write_enable && (decoded_rd_address < 13);

    // Internal Forwarding: Bypass register file if reading/writing same register
    assign rs = (is_writing && (decoded_rs_address == decoded_rd_address)) ? write_data : registers[warp_id][decoded_rs_address];
    assign rt = (is_writing && (decoded_rt_address == decoded_rd_address)) ? write_data : registers[warp_id][decoded_rt_address];

    integer w, i;
    always @(posedge clk) begin
        if (reset) begin
            for (w = 0; w < NUM_WARPS; w = w + 1) begin
                for (i = 0; i < 13; i = i + 1) begin
                    registers[w][i] <= {DATA_BITS{1'b0}};
                end
                registers[w][13] <= 0; 
                registers[w][14] <= THREADS_PER_BLOCK * NUM_WARPS; 
                registers[w][15] <= (w * THREADS_PER_BLOCK) + thread_id; 
            end
        end else begin 
            for (w = 0; w < NUM_WARPS; w = w + 1) begin
                registers[w][13] <= {{(DATA_BITS-8){1'b0}}, block_id}; 
            end

            // LSU async write port
            if (lsu_we && (lsu_rd < 13)) begin
                registers[lsu_warp_id][lsu_rd] <= lsu_data;
            end

            // Pipeline sync write port
            if (is_writing) begin
                registers[warp_id][decoded_rd_address] <= write_data;
            end
        end
    end
endmodule