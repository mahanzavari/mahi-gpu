`default_nettype none
`timescale 1ns/1ns

module registers #(
    parameter THREADS_PER_BLOCK = 4,
    parameter NUM_WARPS = 4,
    parameter DATA_BITS = 32
) (
    input wire clk,
    input wire reset,
    
    input wire enable, 
    input wire [$clog2(NUM_WARPS)-1:0] warp_id,        // Write‑back warp ID
    input wire [$clog2(NUM_WARPS)-1:0] read_warp_id,   // ID stage warp ID (new)
    input wire [7:0] block_id,
    input wire [7:0] thread_id, 

    input wire [4:0] decoded_rd_address,
    input wire [4:0] decoded_rs_address,
    input wire [4:0] decoded_rt_address,

    input wire decoded_reg_write_enable,
    input wire [1:0] decoded_reg_input_mux,
    input wire [DATA_BITS-1:0] decoded_immediate,

    input wire [DATA_BITS-1:0] alu_out,
    input wire [DATA_BITS-1:0] lsu_out,

    input wire lsu_we,
    input wire [$clog2(NUM_WARPS)-1:0] lsu_warp_id,
    input wire [4:0] lsu_rd,
    input wire [DATA_BITS-1:0] lsu_data,

    output wire [DATA_BITS-1:0] rs,
    output wire [DATA_BITS-1:0] rt
);
    localparam ARITHMETIC = 2'b00, MEMORY = 2'b01, CONSTANT = 2'b10, SHARED = 2'b11;

    // 32 registers per warp
    reg [DATA_BITS-1:0] registers [NUM_WARPS][32];

    // Data to be written back (from ALU, memory, constant, or shared load)
    wire [DATA_BITS-1:0] write_data = (decoded_reg_input_mux == ARITHMETIC) ? alu_out :
                                      (decoded_reg_input_mux == MEMORY)     ? lsu_out :
                                      (decoded_reg_input_mux == CONSTANT)   ? decoded_immediate :
                                                                              lsu_out;

    // Write‑back logic – uses write‑back warp ID
    wire is_writing = enable && decoded_reg_write_enable && (decoded_rd_address < 29);
    wire is_lsu_writing = lsu_we && (lsu_rd < 29);

    // ---- Read ports now use the ID stage warp ID ----
    assign rs = (is_writing && (decoded_rs_address == decoded_rd_address) && (read_warp_id == warp_id))
                ? write_data
                : (is_lsu_writing && (decoded_rs_address == lsu_rd) && (read_warp_id == lsu_warp_id))
                ? lsu_data
                : registers[read_warp_id][decoded_rs_address];

    assign rt = (is_writing && (decoded_rt_address == decoded_rd_address) && (read_warp_id == warp_id))
                ? write_data
                : (is_lsu_writing && (decoded_rt_address == lsu_rd) && (read_warp_id == lsu_warp_id))
                ? lsu_data
                : registers[read_warp_id][decoded_rt_address];

    integer w, i;
    always @(posedge clk) begin
        if (reset) begin
            for (w = 0; w < NUM_WARPS; w = w + 1) begin
                for (i = 0; i < 29; i = i + 1) registers[w][i] <= 0;
                registers[w][29] <= 0;                                       
                registers[w][30] <= THREADS_PER_BLOCK * NUM_WARPS;           
                registers[w][31] <= (w * THREADS_PER_BLOCK) + thread_id;     
            end
        end else begin
            for (w = 0; w < NUM_WARPS; w = w + 1) begin
                registers[w][29] <= {{(DATA_BITS-8){1'b0}}, block_id};       
            end
            if (lsu_we && (lsu_rd < 29))
                registers[lsu_warp_id][lsu_rd] <= lsu_data;
            if (is_writing)
                registers[warp_id][decoded_rd_address] <= write_data;
        end
    end
endmodule