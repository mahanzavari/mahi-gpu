`default_nettype none
`timescale 1ns/1ns

module dcache #(
    parameter ADDR_BITS = 32,
    parameter BLOCK_BITS = 128,
    parameter CACHE_LINES = 64, // 64 to reduce thrashing
    parameter VWB_DEPTH  = 4
) (
    input wire clk,
    input wire reset,

    input wire core_read_valid,
    input wire [ADDR_BITS-1:0] core_read_block_addr,
    output logic core_read_ready,
    output logic [BLOCK_BITS-1:0] core_read_block_data,

    input wire core_write_valid,
    input wire [ADDR_BITS-1:0] core_write_block_addr,
    input wire [BLOCK_BITS-1:0] core_write_block_data,
    input wire [3:0] core_write_strobe,
    output logic core_write_ready,

    output logic mem_read_valid,
    output logic [ADDR_BITS-1:0] mem_read_block_addr,
    input wire mem_read_ready,
    input wire [BLOCK_BITS-1:0] mem_read_block_data,

    output logic mem_write_valid,
    output logic [ADDR_BITS-1:0] mem_write_block_addr,
    output logic [BLOCK_BITS-1:0] mem_write_block_data,
    output logic [3:0] mem_write_strobe,
    input wire mem_write_ready,

    input wire flush_en,
    output logic flush_done,

    output wire ev_read_acc, output wire ev_read_hit, output wire ev_read_stall,
    output wire ev_write_acc, output wire ev_write_hit, output wire ev_write_stall
);

    localparam WAYS = 2;
    localparam SETS = CACHE_LINES / WAYS;
    localparam INDEX_BITS = $clog2(SETS);
    localparam TAG_BITS = ADDR_BITS - INDEX_BITS;

    reg valid_array [SETS][WAYS];
    reg dirty_array [SETS][WAYS];
    reg [TAG_BITS-1:0] tag_array [SETS][WAYS];
    reg [BLOCK_BITS-1:0] data_array [SETS][WAYS];
    reg [3:0] sector_dirty [SETS][WAYS];
    reg lru_bit [SETS]; 

    typedef enum logic [2:0] { IDLE, FETCHING_MEM, FLUSH_CHECK, FLUSH_WAIT } state_t;
    state_t state;
    
    // --- VWB Wires & Regs --- 
    reg                  vwb_push_valid;
    reg [ADDR_BITS-1:0]  vwb_push_addr;
    reg [BLOCK_BITS-1:0] vwb_push_data;
    reg [3:0]            vwb_push_sector_dirty;
    wire                 vwb_push_ready;

    wire                 vwb_probe_hit;
    wire [BLOCK_BITS-1:0] vwb_probe_data;
    wire [3:0]           vwb_probe_sector_valid;

    reg                  vwb_probe_pop;
    reg [ADDR_BITS-1:0]  vwb_pop_addr;

    wire                 vwb_empty;
    wire                 vwb_full;

    victim_write_buffer #(
        .ADDR_BITS(ADDR_BITS), .BLOCK_BITS(BLOCK_BITS), .SECTORS(4), .DEPTH(VWB_DEPTH)
    ) vwb_inst (
        .clk(clk), .reset(reset),
        .push_valid(vwb_push_valid), .push_addr(vwb_push_addr),
        .push_data(vwb_push_data), .push_sector_dirty(vwb_push_sector_dirty),
        .push_ready(vwb_push_ready),
        .probe_valid(state == IDLE && (core_read_valid || core_write_valid) && !hit),
        .probe_addr(core_read_valid ? core_read_block_addr : core_write_block_addr),
        .probe_hit(vwb_probe_hit), .probe_data(vwb_probe_data), .probe_sector_valid(vwb_probe_sector_valid),
        .probe_pop(vwb_probe_pop), .pop_addr(vwb_pop_addr),
        .mem_write_valid(mem_write_valid), .mem_write_addr(mem_write_block_addr),
        .mem_write_data(mem_write_block_data), .mem_write_strobe(mem_write_strobe),
        .mem_write_ready(mem_write_ready),
        .flush_en(flush_en), .empty(vwb_empty), .full(vwb_full)
    );

    wire [INDEX_BITS-1:0] req_index = core_read_valid ? core_read_block_addr[INDEX_BITS-1:0] : core_write_block_addr[INDEX_BITS-1:0];
    wire [TAG_BITS-1:0]   req_tag   = core_read_valid ? core_read_block_addr[ADDR_BITS-1:INDEX_BITS] : core_write_block_addr[ADDR_BITS-1:INDEX_BITS];

    wire hit_w0 = valid_array[req_index][0] && (tag_array[req_index][0] == req_tag);
    wire hit_w1 = valid_array[req_index][1] && (tag_array[req_index][1] == req_tag);
    wire hit = hit_w0 || hit_w1;
    wire hit_way = hit_w1; 

    wire victim_way = lru_bit[req_index];
    wire victim_dirty = valid_array[req_index][victim_way] && dirty_array[req_index][victim_way];

    reg [INDEX_BITS-1:0] flush_set;
    reg flush_way;

    always @(posedge clk) begin
        if (reset) begin
            state <= IDLE;
            mem_read_valid <= 0; core_read_ready <= 0; core_write_ready <= 0; flush_done <= 0;
            vwb_push_valid <= 0; vwb_probe_pop <= 0;
            for (int s = 0; s < SETS; s++) begin
                lru_bit[s] <= 0;
                for (int w = 0; w < WAYS; w++) begin
                    valid_array[s][w] <= 0; dirty_array[s][w] <= 0; sector_dirty[s][w] <= 4'b0000;
                end
            end
        end else begin
            core_read_ready <= 0; core_write_ready <= 0; flush_done <= 0;
            vwb_push_valid <= 0; vwb_probe_pop <= 0;

            case (state)
                IDLE: begin
                    if (flush_en) begin
                        flush_set <= 0; flush_way <= 0;
                        state <= FLUSH_CHECK;
                    end 
                    else if (core_write_valid) begin
                        if (hit) begin
                            if (core_write_strobe[0]) begin data_array[req_index][hit_way][31:0] <= core_write_block_data[31:0]; sector_dirty[req_index][hit_way][0] <= 1; end
                            if (core_write_strobe[1]) begin data_array[req_index][hit_way][63:32] <= core_write_block_data[63:32]; sector_dirty[req_index][hit_way][1] <= 1; end
                            if (core_write_strobe[2]) begin data_array[req_index][hit_way][95:64] <= core_write_block_data[95:64]; sector_dirty[req_index][hit_way][2] <= 1; end
                            if (core_write_strobe[3]) begin data_array[req_index][hit_way][127:96] <= core_write_block_data[127:96]; sector_dirty[req_index][hit_way][3] <= 1; end
                            dirty_array[req_index][hit_way] <= 1;
                            lru_bit[req_index] <= ~hit_way; 
                            core_write_ready <= 1;
                        end else if (vwb_probe_hit) begin
                            if (victim_dirty && !vwb_push_ready) begin
                                // Fix: Explicitly stall if VWB is full! Don't drop victim!
                            end else begin
                                if (victim_dirty) begin
                                    vwb_push_valid <= 1;
                                    vwb_push_addr <= {tag_array[req_index][victim_way], req_index};
                                    vwb_push_data <= data_array[req_index][victim_way];
                                    vwb_push_sector_dirty <= sector_dirty[req_index][victim_way];
                                end
                                vwb_probe_pop <= 1; // Pop from VWB to prevent duplicates
                                vwb_pop_addr <= core_write_block_addr;
                                
                                begin
                                    logic [BLOCK_BITS-1:0] merged;
                                    merged = vwb_probe_data;
                                    if (core_write_strobe[0]) merged[31:0]   = core_write_block_data[31:0];
                                    if (core_write_strobe[1]) merged[63:32]  = core_write_block_data[63:32];
                                    if (core_write_strobe[2]) merged[95:64]  = core_write_block_data[95:64];
                                    if (core_write_strobe[3]) merged[127:96] = core_write_block_data[127:96];
                                    data_array[req_index][victim_way] <= merged;
                                end
                                valid_array[req_index][victim_way] <= 1;
                                tag_array[req_index][victim_way] <= req_tag;
                                dirty_array[req_index][victim_way] <= 1;
                                sector_dirty[req_index][victim_way] <= vwb_probe_sector_valid | core_write_strobe;
                                lru_bit[req_index] <= ~victim_way;
                                core_write_ready <= 1;
                            end
                        end else begin
                            if (victim_dirty) begin
                                if (vwb_push_ready) begin
                                    vwb_push_valid <= 1;
                                    vwb_push_addr <= {tag_array[req_index][victim_way], req_index};
                                    vwb_push_data <= data_array[req_index][victim_way];
                                    vwb_push_sector_dirty <= sector_dirty[req_index][victim_way];
                                    dirty_array[req_index][victim_way] <= 0;
                                    sector_dirty[req_index][victim_way] <= 4'b0000;
                                    mem_read_block_addr <= core_write_block_addr;
                                    mem_read_valid <= 1;
                                    state <= FETCHING_MEM;
                                end
                            end else begin
                                mem_read_block_addr <= core_write_block_addr;
                                mem_read_valid <= 1;
                                state <= FETCHING_MEM;
                            end
                        end

                    end else if (core_read_valid) begin
                        if (hit) begin
                            core_read_block_data <= data_array[req_index][hit_way];
                            lru_bit[req_index] <= ~hit_way;
                            core_read_ready <= 1;
                        end else if (vwb_probe_hit) begin
                            if (victim_dirty && !vwb_push_ready) begin
                                // Fix: Explicitly stall
                            end else begin
                                if (victim_dirty) begin
                                    vwb_push_valid <= 1;
                                    vwb_push_addr <= {tag_array[req_index][victim_way], req_index};
                                    vwb_push_data <= data_array[req_index][victim_way];
                                    vwb_push_sector_dirty <= sector_dirty[req_index][victim_way];
                                end
                                vwb_probe_pop <= 1;
                                vwb_pop_addr <= core_read_block_addr;

                                data_array[req_index][victim_way] <= vwb_probe_data;
                                valid_array[req_index][victim_way] <= 1;
                                tag_array[req_index][victim_way] <= req_tag;
                                dirty_array[req_index][victim_way] <= 1; // It was dirty in VWB! Restore dirty status!
                                sector_dirty[req_index][victim_way] <= vwb_probe_sector_valid; // Restore dirty mask!
                                lru_bit[req_index] <= ~victim_way;
                                core_read_block_data <= vwb_probe_data;
                                core_read_ready <= 1;
                            end
                        end else begin
                            if (victim_dirty) begin
                                if (vwb_push_ready) begin
                                    vwb_push_valid <= 1;
                                    vwb_push_addr <= {tag_array[req_index][victim_way], req_index};
                                    vwb_push_data <= data_array[req_index][victim_way];
                                    vwb_push_sector_dirty <= sector_dirty[req_index][victim_way];
                                    dirty_array[req_index][victim_way] <= 0;
                                    sector_dirty[req_index][victim_way] <= 4'b0000;
                                    mem_read_block_addr <= core_read_block_addr;
                                    mem_read_valid <= 1;
                                    state <= FETCHING_MEM;
                                end
                            end else begin
                                mem_read_block_addr <= core_read_block_addr;
                                mem_read_valid <= 1;
                                state <= FETCHING_MEM;
                            end
                        end
                    end
                end

                FETCHING_MEM: begin
                    if (mem_read_ready) begin
                        mem_read_valid <= 0;
                        valid_array[req_index][victim_way] <= 1;
                        tag_array[req_index][victim_way] <= req_tag;
                        lru_bit[req_index] <= ~victim_way;

                        if (core_read_valid) begin
                            data_array[req_index][victim_way] <= mem_read_block_data;
                            dirty_array[req_index][victim_way] <= 0;
                            sector_dirty[req_index][victim_way] <= 4'b0000;
                            core_read_block_data <= mem_read_block_data;
                            core_read_ready <= 1;
                        end else begin
                            begin
                                logic [BLOCK_BITS-1:0] merged;
                                merged = mem_read_block_data;
                                if (core_write_strobe[0]) merged[31:0]   = core_write_block_data[31:0];
                                if (core_write_strobe[1]) merged[63:32]  = core_write_block_data[63:32];
                                if (core_write_strobe[2]) merged[95:64]  = core_write_block_data[95:64];
                                if (core_write_strobe[3]) merged[127:96] = core_write_block_data[127:96];
                                data_array[req_index][victim_way] <= merged;
                            end
                            dirty_array[req_index][victim_way] <= 1;
                            sector_dirty[req_index][victim_way] <= core_write_strobe;
                            core_write_ready <= 1;
                        end
                        state <= IDLE;
                    end
                end

                FLUSH_CHECK: begin
                    if (!flush_en) begin
                        state <= IDLE;
                    end else if (valid_array[flush_set][flush_way] && dirty_array[flush_set][flush_way]) begin
                        if (vwb_push_ready) begin
                            vwb_push_valid <= 1;
                            vwb_push_addr <= {tag_array[flush_set][flush_way], flush_set};
                            vwb_push_data <= data_array[flush_set][flush_way];
                            vwb_push_sector_dirty <= sector_dirty[flush_set][flush_way];
                            dirty_array[flush_set][flush_way] <= 0;
                            sector_dirty[flush_set][flush_way] <= 4'b0000;
                            if (flush_way == WAYS - 1) begin
                                if (flush_set == SETS - 1) state <= FLUSH_WAIT;
                                else begin flush_set <= flush_set + 1; flush_way <= 0; end
                            end else flush_way <= flush_way + 1;
                        end
                    end else begin
                        if (flush_way == WAYS - 1) begin
                            if (flush_set == SETS - 1) state <= FLUSH_WAIT;
                            else begin flush_set <= flush_set + 1; flush_way <= 0; end
                        end else flush_way <= flush_way + 1;
                    end
                end

                FLUSH_WAIT: begin
                    if (vwb_empty) begin
                        flush_done <= 1;
                        if (!flush_en) state <= IDLE;
                    end
                end
            endcase
        end
    end

    assign ev_read_acc  = (state == IDLE && core_read_valid);
    assign ev_read_hit  = (state == IDLE && core_read_valid && hit);
    assign ev_read_stall= (core_read_valid && !core_read_ready);
    assign ev_write_acc = (state == IDLE && core_write_valid);
    assign ev_write_hit = (state == IDLE && core_write_valid && hit);
    assign ev_write_stall=(core_write_valid && !core_write_ready);

endmodule