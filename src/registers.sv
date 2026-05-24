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
    input wire [$clog2(NUM_WARPS)-1:0] read_warp_id,   // ID stage warp ID
    input wire [7:0] block_id,
    input wire [7:0] thread_id, 

    input wire [4:0] decoded_rd_address, // Write Destination
    input wire [4:0] read_rd_address,    // Read Source (For MAC/CAS)
    input wire [4:0] decoded_rs_address, // Read Source
    input wire [4:0] decoded_rt_address, // Read Source

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
    output wire [DATA_BITS-1:0] rt,
    output wire [DATA_BITS-1:0] rd_val
);
    localparam ARITHMETIC = 2'b00, MEMORY = 2'b01, CONSTANT = 2'b10, SHARED = 2'b11;

    // 32 registers per warp
    reg [DATA_BITS-1:0] registers [NUM_WARPS][32];

    wire [DATA_BITS-1:0] write_data = (decoded_reg_input_mux == ARITHMETIC) ? alu_out :
                                      (decoded_reg_input_mux == MEMORY)     ? lsu_out :
                                      (decoded_reg_input_mux == CONSTANT)   ? decoded_immediate :
                                                                              lsu_out;

    wire is_writing = enable && decoded_reg_write_enable && (decoded_rd_address < 29);
    wire is_lsu_writing = lsu_we && (lsu_rd < 29);

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
                
    // Fix: Using read_rd_address to fetch the 3rd source register properly
    assign rd_val = (is_writing && (read_rd_address == decoded_rd_address) && (read_warp_id == warp_id))
                ? write_data
                : (is_lsu_writing && (read_rd_address == lsu_rd) && (read_warp_id == lsu_warp_id))
                ? lsu_data
                : registers[read_warp_id][read_rd_address];

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