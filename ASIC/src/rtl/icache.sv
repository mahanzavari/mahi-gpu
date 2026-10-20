`default_nettype none
`timescale 1ns/1ns

module icache #(
    parameter ADDR_BITS = gpu_pkg::CFG_PMEM_ADDR_BITS,
    parameter DATA_BITS = gpu_pkg::DATA_BITS,
    parameter BLOCK_BITS = gpu_pkg::AXI_DATA_WIDTH,
    parameter CACHE_LINES = gpu_pkg::CFG_L1_CACHE_LINES
) (
    input wire clk,
    input wire reset,

    input wire core_read_valid,
    input wire [ADDR_BITS-1:0] core_read_addr, 
    output logic core_read_ready,
    output logic [DATA_BITS-1:0] core_read_data,

    output logic mem_read_valid,
    output logic [ADDR_BITS-1:0] mem_read_block_addr,
    input wire mem_read_ready,
    input wire [BLOCK_BITS-1:0] mem_read_block_data,

    output wire ev_access,
    output wire ev_hit,
    output wire ev_stall
);

    localparam INDEX_BITS = $clog2(CACHE_LINES);
    localparam TAG_BITS = ADDR_BITS - 2 - INDEX_BITS;
    // ASIC shrink guard: CACHE_LINES is never 1 in any profile, but keep the
    // index path safe if a future profile sets it to 1 ($clog2(1)==0).
    localparam INDEX_PTR_WIDTH = (CACHE_LINES > 1) ? $clog2(CACHE_LINES) : 1;

    reg valid_array [CACHE_LINES];
    reg [TAG_BITS-1:0] tag_array [CACHE_LINES];
    reg [BLOCK_BITS-1:0] data_array [CACHE_LINES];

    wire [1:0] word_offset = core_read_addr[1:0];
    wire [INDEX_BITS-1:0] index = core_read_addr[INDEX_BITS+1 : 2];
    wire [TAG_BITS-1:0] tag = core_read_addr[ADDR_BITS-1 : INDEX_BITS+2];

    wire hit = valid_array[index] && (tag_array[index] == tag);

    typedef enum logic { IDLE, FETCHING_MEM } state_t;
    state_t state;

    reg [INDEX_BITS-1:0] latched_index;
    reg [TAG_BITS-1:0]   latched_tag;

    always @(posedge clk) begin
        if (reset) begin
            state <= IDLE;
            mem_read_valid <= 0;
            core_read_ready <= 0;
            for (int i = 0; i < CACHE_LINES; i = i + 1) valid_array[i] <= 0;
        end else begin
            core_read_ready <= 0;

            case (state)
                IDLE: begin
                    if (core_read_valid && !core_read_ready) begin
                        if (hit) begin
                            core_read_data <= data_array[index][(word_offset * 32) +: 32];
                            core_read_ready <= 1;
                        end else begin
                            latched_index <= index;
                            latched_tag <= tag;
                            mem_read_valid <= 1;
                            mem_read_block_addr <= core_read_addr >> 2;
                            state <= FETCHING_MEM;
`ifdef MEM_TRACE
                            $display("[%0t] [ICACHE-MISS] core_read_addr=%0d index=%0d tag=%0d block_addr=%0d",
                                     $time, core_read_addr, index, tag, core_read_addr >> 2);
`endif
                        end
                    end
                end

                FETCHING_MEM: begin
                    if (mem_read_ready) begin
                        mem_read_valid <= 0;
                        
                        // Always save to the latched (original) location
                        valid_array[latched_index] <= 1;
                        tag_array[latched_index] <= latched_tag;
                        data_array[latched_index] <= mem_read_block_data;
                        
                        // Protect against core changing the block mid-flight, 
                        // but allow word_offset to evaluate cleanly.
                        if (core_read_valid && index == latched_index && tag == latched_tag) begin
                            core_read_data <= mem_read_block_data[(word_offset * 32) +: 32];
                            core_read_ready <= 1;
`ifdef MEM_TRACE
                            $display("[%0t] [ICACHE-FILL] latched_index=%0d word_offset=%0d block_data=%h -> word=%h",
                                     $time, latched_index, word_offset, mem_read_block_data, mem_read_block_data[(word_offset*32)+:32]);
`endif
                        end
                        state <= IDLE;
                    end
                end
            endcase
        end
    end

    assign ev_access = (state == IDLE && core_read_valid);
    assign ev_hit    = (state == IDLE && core_read_valid && hit);
    assign ev_stall  = (core_read_valid && !core_read_ready);

endmodule