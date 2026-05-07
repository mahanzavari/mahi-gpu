`default_nettype none
`timescale 1ns/1ns

module icache #(
    parameter ADDR_BITS = 32,
    parameter DATA_BITS = 32,
    parameter BLOCK_BITS = 128,
    parameter CACHE_LINES = 16 // 16 lines of 128-bits = 256 bytes L1 I-Cache
) (
    input wire clk,
    input wire reset,

    // --- Core (Fetcher) Interface ---
    input wire core_read_valid,
    input wire [ADDR_BITS-1:0] core_read_addr, // Word Address
    output logic core_read_ready,
    output logic [DATA_BITS-1:0] core_read_data,

    // --- Memory Controller Interface (128-bit blocks) ---
    output logic mem_read_valid,
    output logic [ADDR_BITS-1:0] mem_read_block_addr,
    input wire mem_read_ready,
    input wire [BLOCK_BITS-1:0] mem_read_block_data
);

    localparam INDEX_BITS = $clog2(CACHE_LINES);
    // Because the core requests WORD addresses, we drop the bottom 2 bits to get the BLOCK address.
    localparam TAG_BITS = ADDR_BITS - 2 - INDEX_BITS; 

    // Cache Storage
    reg valid_array [CACHE_LINES];
    reg [TAG_BITS-1:0] tag_array [CACHE_LINES];
    reg [BLOCK_BITS-1:0] data_array [CACHE_LINES];

    // Address Decoding
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
                            $display("[%0t] [ICACHE] READ HIT: WordAddr=%0d, BlockAddr=%0d", $time, core_read_addr, core_read_addr >> 2);
                            // HIT: Extract the specific 32-bit word from the 128-bit block
                            core_read_data <= data_array[index][(word_offset * 32) +: 32];
                            core_read_ready <= 1;
                        end else begin
                            $display("[%0t] [ICACHE] READ MISS: WordAddr=%0d. Fetching BlockAddr=%0d...", $time, core_read_addr, core_read_addr >> 2);
                            // MISS: Fetch block
                            mem_read_valid <= 1;
                            mem_read_block_addr <= core_read_addr >> 2; // Convert word addr to block addr
                            state <= FETCHING_MEM;
                        end
                    end
                end

                FETCHING_MEM: begin
                    if (mem_read_ready) begin
                        $display("[%0t] [ICACHE] MEM FETCH DONE: BlockAddr=%0d", $time, mem_read_block_addr);
                        mem_read_valid <= 0;
                        // Allocate
                        valid_array[index] <= 1;
                        tag_array[index] <= tag;
                        data_array[index] <= mem_read_block_data;
                        
                        // Extract specific word and return
                        core_read_data <= mem_read_block_data[(word_offset * 32) +: 32];
                        core_read_ready <= 1;
                        state <= IDLE;
                    end
                end
            endcase
        end
    end

    // --- Performance Counters ---
    (* keep = "true" *) reg [31:0] stat_accesses;
    (* keep = "true" *) reg [31:0] stat_hits;
    (* keep = "true" *) reg [31:0] stat_latency_cycles;

    always @(posedge clk) begin
        if (reset) begin
            stat_accesses <= 0;
            stat_hits <= 0;
            stat_latency_cycles <= 0;
        end else begin
            if (state == IDLE && core_read_valid) begin
                stat_accesses <= stat_accesses + 1;
                if (hit) stat_hits <= stat_hits + 1;
            end
            
            // Track stall cycles for AMAT (Total Latency = Accesses + Stall Cycles)
            if (core_read_valid && !core_read_ready) begin
                stat_latency_cycles <= stat_latency_cycles + 1;
            end
        end
    end
endmodule