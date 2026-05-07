`default_nettype none
`timescale 1ns/1ns

module dcache #(
    parameter ADDR_BITS = 32,
    parameter BLOCK_BITS = 128,
    parameter CACHE_LINES = 16 // 16 lines of 128-bits = 256 bytes L1 D-Cache
) (
    input wire clk,
    input wire reset,

    // --- Core (LSU) Interface ---
    input wire core_read_valid,
    input wire [ADDR_BITS-1:0] core_read_block_addr,
    output logic core_read_ready,
    output logic [BLOCK_BITS-1:0] core_read_block_data,

    input wire core_write_valid,
    input wire [ADDR_BITS-1:0] core_write_block_addr,
    input wire [BLOCK_BITS-1:0] core_write_block_data,
    input wire [3:0] core_write_strobe,
    output logic core_write_ready,

    // --- Memory Controller Interface ---
    output logic mem_read_valid,
    output logic [ADDR_BITS-1:0] mem_read_block_addr,
    input wire mem_read_ready,
    input wire [BLOCK_BITS-1:0] mem_read_block_data,

    output logic mem_write_valid,
    output logic [ADDR_BITS-1:0] mem_write_block_addr,
    output logic [BLOCK_BITS-1:0] mem_write_block_data,
    output logic [3:0] mem_write_strobe,
    input wire mem_write_ready
);

    localparam INDEX_BITS = $clog2(CACHE_LINES);
    localparam TAG_BITS = ADDR_BITS - INDEX_BITS;

    // Cache Storage
    reg valid_array [CACHE_LINES];
    reg [TAG_BITS-1:0] tag_array [CACHE_LINES];
    reg [BLOCK_BITS-1:0] data_array [CACHE_LINES];

    // Address Decoding (Block Address provided by LSU)
    wire [INDEX_BITS-1:0] read_index = core_read_block_addr[INDEX_BITS-1:0];
    wire [TAG_BITS-1:0] read_tag = core_read_block_addr[ADDR_BITS-1:INDEX_BITS];

    wire [INDEX_BITS-1:0] write_index = core_write_block_addr[INDEX_BITS-1:0];
    wire [TAG_BITS-1:0] write_tag = core_write_block_addr[ADDR_BITS-1:INDEX_BITS];

    wire read_hit = valid_array[read_index] && (tag_array[read_index] == read_tag);
    wire write_hit = valid_array[write_index] && (tag_array[write_index] == write_tag);

    typedef enum logic [1:0] { IDLE, FETCHING_MEM, WRITING_MEM } state_t;
    state_t state;

    always @(posedge clk) begin
        if (reset) begin
            state <= IDLE;
            mem_read_valid <= 0; mem_write_valid <= 0;
            core_read_ready <= 0; core_write_ready <= 0;
            for (int i = 0; i < CACHE_LINES; i++) valid_array[i] <= 0;
        end else begin
            core_read_ready <= 0;
            core_write_ready <= 0;

            case (state)
                IDLE: begin
                    if (core_write_valid) begin
                        $display("[%0t] [DCACHE] WRITE REQ: BlockAddr=%0d, Strobe=%b, Hit=%b", $time, core_write_block_addr, core_write_strobe, write_hit);
                        
                        // Write-Through: Send to memory immediately
                        mem_write_valid <= 1;
                        mem_write_block_addr <= core_write_block_addr;
                        mem_write_block_data <= core_write_block_data;
                        mem_write_strobe <= core_write_strobe;
                        state <= WRITING_MEM;

                        // Write-Update: If it's in the cache, update the cached line too!
                        if (write_hit) begin
                            if (core_write_strobe[0]) data_array[write_index][31:0]   <= core_write_block_data[31:0];
                            if (core_write_strobe[1]) data_array[write_index][63:32]  <= core_write_block_data[63:32];
                            if (core_write_strobe[2]) data_array[write_index][95:64]  <= core_write_block_data[95:64];
                            if (core_write_strobe[3]) data_array[write_index][127:96] <= core_write_block_data[127:96];
                        end
                    end 
                    else if (core_read_valid) begin
                        if (read_hit) begin
                            $display("[%0t] [DCACHE] READ HIT: BlockAddr=%0d", $time, core_read_block_addr);
                            // CACHE HIT: Return data in 1 cycle
                            core_read_block_data <= data_array[read_index];
                            core_read_ready <= 1;
                        end else begin
                            $display("[%0t] [DCACHE] READ MISS: BlockAddr=%0d. Fetching from memory...", $time, core_read_block_addr);
                            // CACHE MISS: Fetch from memory
                            mem_read_valid <= 1;
                            mem_read_block_addr <= core_read_block_addr;
                            state <= FETCHING_MEM;
                        end
                    end
                end

                FETCHING_MEM: begin
                    if (mem_read_ready) begin
                        $display("[%0t] [DCACHE] MEM FETCH DONE: BlockAddr=%0d", $time, core_read_block_addr);
                        mem_read_valid <= 0;
                        // Allocate in Cache
                        valid_array[read_index] <= 1;
                        tag_array[read_index] <= read_tag;
                        data_array[read_index] <= mem_read_block_data;
                        
                        // Return to Core
                        core_read_block_data <= mem_read_block_data;
                        core_read_ready <= 1;
                        state <= IDLE;
                    end
                end

                WRITING_MEM: begin
                    if (mem_write_ready) begin
                        $display("[%0t] [DCACHE] MEM WRITE DONE: BlockAddr=%0d", $time, core_write_block_addr);
                        mem_write_valid <= 0;
                        core_write_ready <= 1;
                        state <= IDLE;
                    end
                end
            endcase
        end
    end

  // --- Performance Counters ---
    (* keep = "true" *) reg [31:0] stat_read_accesses;
    (* keep = "true" *) reg [31:0] stat_read_hits;
    (* keep = "true" *) reg [31:0] stat_write_accesses;
    (* keep = "true" *) reg [31:0] stat_write_hits;
    (* keep = "true" *) reg [31:0] stat_read_latency_cycles;
    (* keep = "true" *) reg [31:0] stat_write_latency_cycles;

    always @(posedge clk) begin
        if (reset) begin
            stat_read_accesses <= 0;
            stat_read_hits <= 0;
            stat_write_accesses <= 0;
            stat_write_hits <= 0;
            stat_read_latency_cycles <= 0;
            stat_write_latency_cycles <= 0;
        end else begin
            if (state == IDLE) begin
                if (core_read_valid) begin
                    stat_read_accesses <= stat_read_accesses + 1;
                    if (read_hit) stat_read_hits <= stat_read_hits + 1;
                end else if (core_write_valid) begin
                    stat_write_accesses <= stat_write_accesses + 1;
                    if (write_hit) stat_write_hits <= stat_write_hits + 1;
                end
            end
            
            // Track stall cycles for AMAT
            if (core_read_valid && !core_read_ready) stat_read_latency_cycles <= stat_read_latency_cycles + 1;
            if (core_write_valid && !core_write_ready) stat_write_latency_cycles <= stat_write_latency_cycles + 1;
        end
    end
endmodule