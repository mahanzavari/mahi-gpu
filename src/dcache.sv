`default_nettype none
`timescale 1ns/1ns

module dcache #(
    parameter ADDR_BITS = 32,
    parameter BLOCK_BITS = 128,
    parameter CACHE_LINES = 16 
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
    input wire mem_write_ready,

    // --- Hardware Flush Interface ---
    input wire flush_en,
    output logic flush_done,

    // --- PMU Event Pulses ---
    output wire ev_read_acc, output wire ev_read_hit, output wire ev_read_stall,
    output wire ev_write_acc, output wire ev_write_hit, output wire ev_write_stall
);

    // --- Phase 8: 2-Way Set Associative ---
    localparam WAYS = 2;
    localparam SETS = CACHE_LINES / WAYS;
    localparam INDEX_BITS = $clog2(SETS);
    localparam TAG_BITS = ADDR_BITS - INDEX_BITS;

    reg valid_array [SETS][WAYS];
    reg dirty_array [SETS][WAYS];
    reg [TAG_BITS-1:0] tag_array [SETS][WAYS];
    reg [BLOCK_BITS-1:0] data_array [SETS][WAYS];
    reg lru_bit [SETS]; // 0 = Way 0 is LRU, 1 = Way 1 is LRU

    wire [INDEX_BITS-1:0] req_index = core_read_valid ? core_read_block_addr[INDEX_BITS-1:0] : core_write_block_addr[INDEX_BITS-1:0];
    wire [TAG_BITS-1:0]   req_tag   = core_read_valid ? core_read_block_addr[ADDR_BITS-1:INDEX_BITS] : core_write_block_addr[ADDR_BITS-1:INDEX_BITS];

    wire hit_w0 = valid_array[req_index][0] && (tag_array[req_index][0] == req_tag);
    wire hit_w1 = valid_array[req_index][1] && (tag_array[req_index][1] == req_tag);
    wire hit = hit_w0 || hit_w1;
    wire hit_way = hit_w1; // If 0, it's way 0. If 1, it's way 1.

    // Victim Selection
    wire victim_way = lru_bit[req_index];
    wire victim_dirty = valid_array[req_index][victim_way] && dirty_array[req_index][victim_way];

    // Flush Iterators
    reg [INDEX_BITS-1:0] flush_set;
    reg flush_way;

    typedef enum logic [2:0] { IDLE, EVICT_WRITEBACK, FETCHING_MEM, FLUSH_CHECK, FLUSH_WRITEBACK, FLUSH_WAIT} state_t;
    state_t state;

    always @(posedge clk) begin
        if (reset) begin
            state <= IDLE;
            mem_read_valid <= 0; mem_write_valid <= 0;
            core_read_ready <= 0; core_write_ready <= 0; flush_done <= 0;
            for (int s=0; s<SETS; s++) begin
                lru_bit[s] <= 0;
                for (int w=0; w<WAYS; w++) begin valid_array[s][w] <= 0; dirty_array[s][w] <= 0; end
            end
        end else begin
            core_read_ready <= 0; core_write_ready <= 0; flush_done <= 0;

            case (state)
                IDLE: begin
                    if (flush_en) begin
                        flush_set <= 0; flush_way <= 0;
                        state <= FLUSH_CHECK;
                    end 
                    else if (core_write_valid) begin
                        if (hit) begin
                            // PHASE 7: WRITE HIT (Write-Back policy)
                            if (core_write_strobe[0]) data_array[req_index][hit_way][31:0]   <= core_write_block_data[31:0];
                            if (core_write_strobe[1]) data_array[req_index][hit_way][63:32]  <= core_write_block_data[63:32];
                            if (core_write_strobe[2]) data_array[req_index][hit_way][95:64]  <= core_write_block_data[95:64];
                            if (core_write_strobe[3]) data_array[req_index][hit_way][127:96] <= core_write_block_data[127:96];
                            dirty_array[req_index][hit_way] <= 1;
                            lru_bit[req_index] <= ~hit_way; // Protect this way
                            core_write_ready <= 1;
                        end else begin
                            // WRITE MISS: Evict if dirty, else fetch block for write-allocate
                            if (victim_dirty) begin
                                mem_write_block_addr <= {tag_array[req_index][victim_way], req_index};
                                mem_write_block_data <= data_array[req_index][victim_way];
                                mem_write_strobe <= 4'b1111; // Write full block back
                                mem_write_valid <= 1;
                                state <= EVICT_WRITEBACK;
                            end else begin
                                mem_read_block_addr <= core_write_block_addr;
                                mem_read_valid <= 1;
                                state <= FETCHING_MEM;
                            end
                        end
                    end 
                    else if (core_read_valid) begin
                        if (hit) begin
                            // READ HIT
                            core_read_block_data <= data_array[req_index][hit_way];
                            lru_bit[req_index] <= ~hit_way;
                            core_read_ready <= 1;
                        end else begin
                            // READ MISS
                            if (victim_dirty) begin
                                mem_write_block_addr <= {tag_array[req_index][victim_way], req_index};
                                mem_write_block_data <= data_array[req_index][victim_way];
                                mem_write_strobe <= 4'b1111;
                                mem_write_valid <= 1;
                                state <= EVICT_WRITEBACK;
                            end else begin
                                mem_read_block_addr <= core_read_block_addr;
                                mem_read_valid <= 1;
                                state <= FETCHING_MEM;
                            end
                        end
                    end
                end

                EVICT_WRITEBACK: begin
                    if (mem_write_ready) begin
                        mem_write_valid <= 0;
                        dirty_array[req_index][victim_way] <= 0;
                        // Now fetch the actual requested block
                        mem_read_block_addr <= core_read_valid ? core_read_block_addr : core_write_block_addr;
                        mem_read_valid <= 1;
                        state <= FETCHING_MEM;
                    end
                end

                FETCHING_MEM: begin
                    if (mem_read_ready) begin
                        mem_read_valid <= 0;
                        valid_array[req_index][victim_way] <= 1;
                        tag_array[req_index][victim_way] <= req_tag;
                        lru_bit[req_index] <= ~victim_way; 
                        
                        if (core_read_valid) begin
                            // Fulfill Read Miss
                            data_array[req_index][victim_way] <= mem_read_block_data;
                            dirty_array[req_index][victim_way] <= 0;
                            core_read_block_data <= mem_read_block_data;
                            core_read_ready <= 1;
                        end else begin
                            // Fulfill Write Miss (Write-Allocate)
                            logic [BLOCK_BITS-1:0] merged = mem_read_block_data;
                            if (core_write_strobe[0]) merged[31:0]   = core_write_block_data[31:0];
                            if (core_write_strobe[1]) merged[63:32]  = core_write_block_data[63:32];
                            if (core_write_strobe[2]) merged[95:64]  = core_write_block_data[95:64];
                            if (core_write_strobe[3]) merged[127:96] = core_write_block_data[127:96];
                            
                            data_array[req_index][victim_way] <= merged;
                            dirty_array[req_index][victim_way] <= 1; // Mark newly allocated line as dirty
                            core_write_ready <= 1;
                        end
                        state <= IDLE;
                    end
                end

                // --- Hardware Flush Logic ---
                FLUSH_CHECK: begin
                    if (!flush_en) begin
                        state <= IDLE; // Abort if driver drops flag
                    end else if (valid_array[flush_set][flush_way] && dirty_array[flush_set][flush_way]) begin
                        mem_write_block_addr <= {tag_array[flush_set][flush_way], flush_set};
                        mem_write_block_data <= data_array[flush_set][flush_way];
                        mem_write_strobe <= 4'b1111;
                        mem_write_valid <= 1;
                        state <= FLUSH_WRITEBACK;
                    end else begin
                        // Advance iterator
                        if (flush_way == 1) begin
                            if (flush_set == SETS - 1) begin
                                state <= FLUSH_WAIT;
                            end else begin
                                flush_set <= flush_set + 1;
                                flush_way <= 0;
                            end
                        end else begin
                            flush_way <= 1;
                        end
                    end
                end

                FLUSH_WRITEBACK: begin
                    if (mem_write_ready) begin
                        mem_write_valid <= 0;
                        dirty_array[flush_set][flush_way] <= 0; // Cleaned!
                        
                        // Advance iterator
                        if (flush_way == 1) begin
                            if (flush_set == SETS - 1) begin
                                state <= FLUSH_WAIT;
                            end else begin
                                flush_set <= flush_set + 1;
                                flush_way <= 0;
                                state <= FLUSH_CHECK;
                            end
                        end else begin
                            flush_way <= 1;
                            state <= FLUSH_CHECK;
                        end
                    end
                end
                FLUSH_WAIT: begin
                    flush_done <= 1; // Overrides the default 0, holding it high
                    // Wait patiently for the Dispatcher to acknowledge all cores
                    if (!flush_en) begin
                        $display("[%0t] DCACHE: Dispatcher dropped flush_en. Returning to IDLE.", $time);
                        state <= IDLE;
                    if (flush_set == SETS - 1 && flush_way == 1) // Just print once when it enters the wait
                        $display("[%0t] DCACHE: Core finished flushing. Waiting for Dispatcher...", $time);
                    end        
                end
            endcase
        end
    end

    // --- 1-Bit PMU Event Pulses ---
    assign ev_read_acc  = (state == IDLE && core_read_valid);
    assign ev_read_hit  = (state == IDLE && core_read_valid && hit);
    assign ev_read_stall= (core_read_valid && !core_read_ready);
    assign ev_write_acc = (state == IDLE && core_write_valid);
    assign ev_write_hit = (state == IDLE && core_write_valid && hit);
    assign ev_write_stall=(core_write_valid && !core_write_ready);

endmodule