`default_nettype none
`timescale 1ns/1ns

module icache #(
    parameter ADDR_BITS = 32,
    parameter DATA_BITS = 32,
    parameter BLOCK_BITS = 128,
    parameter CACHE_LINES = 16 
) (
    input wire clk,
    input wire reset,

    // --- Core (Fetcher) Interface ---
    input wire core_read_valid,
    input wire [ADDR_BITS-1:0] core_read_addr, 
    output logic core_read_ready,
    output logic [DATA_BITS-1:0] core_read_data,

    // --- Memory Controller Interface ---
    output logic mem_read_valid,
    output logic [ADDR_BITS-1:0] mem_read_block_addr,
    input wire mem_read_ready,
    input wire [BLOCK_BITS-1:0] mem_read_block_data,

    // --- PMU Event Pulses ---
    output wire ev_access,
    output wire ev_hit,
    output wire ev_stall
);

    localparam INDEX_BITS = $clog2(CACHE_LINES);
    localparam TAG_BITS = ADDR_BITS - 2 - INDEX_BITS; 

    reg valid_array [CACHE_LINES];
    reg [TAG_BITS-1:0] tag_array [CACHE_LINES];
    reg [BLOCK_BITS-1:0] data_array [CACHE_LINES];

    wire [1:0] word_offset = core_read_addr[1:0];
    wire [INDEX_BITS-1:0] index = core_read_addr[INDEX_BITS+1 : 2];
    wire [TAG_BITS-1:0] tag = core_read_addr[ADDR_BITS-1 : INDEX_BITS+2];

    wire hit = valid_array[index] && (tag_array[index] == tag);

    typedef enum logic { IDLE, FETCHING_MEM } state_t;
    state_t state;

    always @(posedge clk) begin
        if (reset) begin
            state <= IDLE;
            mem_read_valid <= 0;
            core_read_ready <= 0;
            for (int i = 0; i < CACHE_LINES; i++) valid_array[i] <= 0;
        end else begin
            core_read_ready <= 0;

            case (state)
                IDLE: begin
                    if (core_read_valid) begin
                        if (hit) begin
                            core_read_data <= data_array[index][(word_offset * 32) +: 32];
                            core_read_ready <= 1;
                        end else begin
                            mem_read_valid <= 1;
                            mem_read_block_addr <= core_read_addr >> 2; 
                            state <= FETCHING_MEM;
                        end
                    end
                end

                FETCHING_MEM: begin
                    if (mem_read_ready) begin
                        mem_read_valid <= 0;
                        valid_array[index] <= 1;
                        tag_array[index] <= tag;
                        data_array[index] <= mem_read_block_data;
                        
                        core_read_data <= mem_read_block_data[(word_offset * 32) +: 32];
                        core_read_ready <= 1;
                        state <= IDLE;
                    end
                end
            endcase
        end
    end

    // --- 1-Bit PMU Event Pulses ---
    assign ev_access = (state == IDLE && core_read_valid);
    assign ev_hit    = (state == IDLE && core_read_valid && hit);
    assign ev_stall  = (core_read_valid && !core_read_ready);

endmodule