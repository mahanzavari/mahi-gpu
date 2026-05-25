`default_nettype none
`timescale 1ns/1ns

module l2_cache #(
    parameter ADDR_BITS   = 32,
    parameter BLOCK_BITS  = 128,
    parameter CACHE_LINES = 256,
    parameter WAYS        = 4,
    parameter SECTORS     = 4,
    parameter NUM_PORTS   = 2,
    parameter VWB_DEPTH   = 8
) (
    input wire clk,
    input wire reset,

    input wire [NUM_PORTS-1:0]   up_read_valid,
    input wire [ADDR_BITS-1:0]   up_read_addr    [NUM_PORTS],
    output logic [NUM_PORTS-1:0] up_read_ready,
    output logic [BLOCK_BITS-1:0] up_read_data   [NUM_PORTS],

    input wire [NUM_PORTS-1:0]   up_write_valid,
    input wire [ADDR_BITS-1:0]   up_write_addr   [NUM_PORTS],
    input wire [BLOCK_BITS-1:0]  up_write_data   [NUM_PORTS],
    input wire [SECTORS-1:0]     up_write_strobe [NUM_PORTS],
    output logic [NUM_PORTS-1:0] up_write_ready,

    output logic                 mem_read_valid,
    output logic [ADDR_BITS-1:0] mem_read_addr,
    input wire                   mem_read_ready,
    input wire [BLOCK_BITS-1:0]  mem_read_data,

    output logic                 mem_write_valid,
    output logic [ADDR_BITS-1:0] mem_write_addr,
    output logic [BLOCK_BITS-1:0] mem_write_data,
    output logic [SECTORS-1:0]   mem_write_strobe,
    input wire                   mem_write_ready,

    input wire  flush_en,
    output wire flush_done,

    output reg  ev_read_acc,
    output reg  ev_read_hit,
    output reg  ev_read_miss,
    output reg  ev_write_acc,
    output reg  ev_write_hit,
    output reg  ev_write_miss,
    output wire ev_stall,
    output wire ev_evict
);

    localparam SETS = CACHE_LINES / WAYS;
    localparam INDEX_BITS = $clog2(SETS);
    localparam TAG_BITS = ADDR_BITS - INDEX_BITS;
    localparam SECTOR_BITS = BLOCK_BITS / SECTORS;

    reg                  valid_array   [SETS][WAYS];
    reg [SECTORS-1:0]    sector_dirty  [SETS][WAYS];
    reg [TAG_BITS-1:0]   tag_array     [SETS][WAYS];
    reg [BLOCK_BITS-1:0] data_array    [SETS][WAYS];
    reg [WAYS-2:0]       plru_bits     [SETS];

    reg [$clog2(NUM_PORTS)-1:0] active_port;
    reg                  req_is_write;
    reg [ADDR_BITS-1:0]  req_addr;
    reg [BLOCK_BITS-1:0] req_data;
    reg [SECTORS-1:0]    req_strobe;

    wire [INDEX_BITS-1:0] req_index = req_addr[INDEX_BITS-1:0];
    wire [TAG_BITS-1:0]   req_tag   = req_addr[ADDR_BITS-1:INDEX_BITS];

    logic hit;
    logic [$clog2(WAYS)-1:0] hit_way;
    logic [$clog2(WAYS)-1:0] victim_way;

    always_comb begin
        hit = 0; hit_way = 0;
        for (int w = 0; w < WAYS; w++) begin
            if (valid_array[req_index][w] && tag_array[req_index][w] == req_tag) begin
                hit = 1; hit_way = w[$clog2(WAYS)-1:0];
            end
        end
        if (!plru_bits[req_index][0]) victim_way = !plru_bits[req_index][1] ? 2'd0 : 2'd1;
        else                          victim_way = !plru_bits[req_index][2] ? 2'd2 : 2'd3;
    end

    reg                  vwb_push_valid;
    reg [ADDR_BITS-1:0]  vwb_push_addr;
    reg [BLOCK_BITS-1:0] vwb_push_data;
    reg [SECTORS-1:0]    vwb_push_sector_dirty;
    wire                 vwb_push_ready;
    wire                 vwb_empty;

    wire                 vwb_probe_hit;
    wire [BLOCK_BITS-1:0] vwb_probe_data;
    wire [SECTORS-1:0]   vwb_probe_sector_valid;
    reg                  vwb_probe_pop;
    reg [ADDR_BITS-1:0]  vwb_pop_addr;

    victim_write_buffer #(
        .ADDR_BITS(ADDR_BITS), .BLOCK_BITS(BLOCK_BITS), .SECTORS(SECTORS), .DEPTH(VWB_DEPTH)
    ) vwb (
        .clk(clk), .reset(reset),
        .push_valid(vwb_push_valid), .push_addr(vwb_push_addr),
        .push_data(vwb_push_data), .push_sector_dirty(vwb_push_sector_dirty),
        .push_ready(vwb_push_ready),
        .probe_valid(!hit), .probe_addr(req_addr),
        .probe_hit(vwb_probe_hit), .probe_data(vwb_probe_data), .probe_sector_valid(vwb_probe_sector_valid),
        .probe_pop(vwb_probe_pop), .pop_addr(vwb_pop_addr),
        .mem_write_valid(mem_write_valid), .mem_write_addr(mem_write_addr),
        .mem_write_data(mem_write_data), .mem_write_strobe(mem_write_strobe),
        .mem_write_ready(mem_write_ready),
        .flush_en(flush_en), .empty(vwb_empty), .full()
    );

    typedef enum logic [2:0] { IDLE, SERVING, FETCHING, FLUSH_SCAN, FLUSH_WAIT } state_t;
    state_t state;
    
    reg [$clog2(NUM_PORTS)-1:0] arb_ptr;
    reg [INDEX_BITS-1:0] flush_set;
    reg [$clog2(WAYS)-1:0] flush_way_iter;
    
    assign flush_done = (state == FLUSH_WAIT) && vwb_empty;

    always @(posedge clk) begin
        if (reset) begin
            state <= IDLE;
            mem_read_valid <= 0; up_read_ready <= 0; up_write_ready <= 0;
            arb_ptr <= 0; vwb_push_valid <= 0; vwb_probe_pop <= 0;
            for (int s = 0; s < SETS; s++) begin
                plru_bits[s] <= 0;
                for (int w = 0; w < WAYS; w++) begin
                    valid_array[s][w] <= 0; sector_dirty[s][w] <= 0;
                end
            end
        end else begin
            up_read_ready <= 0; up_write_ready <= 0;
            vwb_push_valid <= 0; vwb_probe_pop <= 0;

            case (state)
                IDLE: begin
                    if (flush_en) begin
                        flush_set <= 0; flush_way_iter <= 0; state <= FLUSH_SCAN;
                    end else begin
                        logic found; found = 0;
                        for (int p = 0; p < NUM_PORTS; p++) begin
                            int check_p; check_p = (arb_ptr + p) % NUM_PORTS;
                            if (!found) begin
                                // FIX: Guard L2 requests as well to prevent Double-Writes!
                                if (up_read_valid[check_p] && !up_read_ready[check_p]) begin
                                    active_port <= check_p; req_is_write <= 0;
                                    req_addr <= up_read_addr[check_p];
                                    found = 1; state <= SERVING; arb_ptr <= (check_p + 1) % NUM_PORTS;
                                end else if (up_write_valid[check_p] && !up_write_ready[check_p]) begin
                                    active_port <= check_p; req_is_write <= 1;
                                    req_addr <= up_write_addr[check_p]; req_data <= up_write_data[check_p];
                                    req_strobe <= up_write_strobe[check_p];
                                    found = 1; state <= SERVING; arb_ptr <= (check_p + 1) % NUM_PORTS;
                                end
                            end
                        end
                    end
                end

                SERVING: begin
                    if (hit) begin
                        if (req_is_write) begin
                            logic [BLOCK_BITS-1:0] next_data;
                            logic [SECTORS-1:0] next_dirty;
                            next_data = data_array[req_index][hit_way];
                            next_dirty = sector_dirty[req_index][hit_way];
                            for (int sec = 0; sec < SECTORS; sec++) begin
                                if (req_strobe[sec]) begin
                                    next_data[(sec*SECTOR_BITS) +: SECTOR_BITS] = req_data[(sec*SECTOR_BITS) +: SECTOR_BITS];
                                    next_dirty[sec] = 1'b1;
                                end
                            end
                            data_array[req_index][hit_way] <= next_data;
                            sector_dirty[req_index][hit_way] <= next_dirty;
                            
                            up_write_ready[active_port] <= 1;
                        end else begin
                            up_read_data[active_port] <= data_array[req_index][hit_way];
                            up_read_ready[active_port] <= 1;
                        end
                        case (hit_way)
                            2'd0: begin plru_bits[req_index][0]<=1; plru_bits[req_index][1]<=1; end
                            2'd1: begin plru_bits[req_index][0]<=1; plru_bits[req_index][1]<=0; end
                            2'd2: begin plru_bits[req_index][0]<=0; plru_bits[req_index][2]<=1; end
                            2'd3: begin plru_bits[req_index][0]<=0; plru_bits[req_index][2]<=0; end
                        endcase
                        state <= IDLE;
                    end else if (vwb_probe_hit) begin
                        if (valid_array[req_index][victim_way] && |sector_dirty[req_index][victim_way] && !vwb_push_ready) begin
                            // Stall
                        end else begin
                            if (valid_array[req_index][victim_way] && |sector_dirty[req_index][victim_way]) begin
                                vwb_push_valid <= 1;
                                vwb_push_addr <= {tag_array[req_index][victim_way], req_index};
                                vwb_push_data <= data_array[req_index][victim_way];
                                vwb_push_sector_dirty <= sector_dirty[req_index][victim_way];
                            end
                            vwb_probe_pop <= 1; vwb_pop_addr <= req_addr;
                            
                            valid_array[req_index][victim_way] <= 1;
                            tag_array[req_index][victim_way] <= req_tag;
                            
                            if (req_is_write) begin
                                logic [BLOCK_BITS-1:0] merged; merged = vwb_probe_data;
                                for (int sec=0; sec<SECTORS; sec++) if(req_strobe[sec]) merged[(sec*SECTOR_BITS)+:SECTOR_BITS] = req_data[(sec*SECTOR_BITS)+:SECTOR_BITS];
                                data_array[req_index][victim_way] <= merged;
                                sector_dirty[req_index][victim_way] <= vwb_probe_sector_valid | req_strobe;
                                up_write_ready[active_port] <= 1;
                            end else begin
                                data_array[req_index][victim_way] <= vwb_probe_data;
                                sector_dirty[req_index][victim_way] <= vwb_probe_sector_valid;
                                up_read_data[active_port] <= vwb_probe_data;
                                up_read_ready[active_port] <= 1;
                            end
                            
                            case (victim_way)
                                2'd0: begin plru_bits[req_index][0]<=1; plru_bits[req_index][1]<=1; end
                                2'd1: begin plru_bits[req_index][0]<=1; plru_bits[req_index][1]<=0; end
                                2'd2: begin plru_bits[req_index][0]<=0; plru_bits[req_index][2]<=1; end
                                2'd3: begin plru_bits[req_index][0]<=0; plru_bits[req_index][2]<=0; end
                            endcase
                            state <= IDLE;
                        end
                    end else begin
                        if (valid_array[req_index][victim_way] && |sector_dirty[req_index][victim_way] && !vwb_push_ready) begin
                            // Stall
                        end else begin
                            if (valid_array[req_index][victim_way] && |sector_dirty[req_index][victim_way]) begin
                                vwb_push_valid <= 1;
                                vwb_push_addr <= {tag_array[req_index][victim_way], req_index};
                                vwb_push_data <= data_array[req_index][victim_way];
                                vwb_push_sector_dirty <= sector_dirty[req_index][victim_way];
                                sector_dirty[req_index][victim_way] <= 0;
                            end
                            mem_read_valid <= 1; mem_read_addr <= req_addr; state <= FETCHING;
                        end
                    end
                end

                FETCHING: begin
                    if (mem_read_ready) begin
                        mem_read_valid <= 0;
                        valid_array[req_index][victim_way] <= 1; tag_array[req_index][victim_way] <= req_tag;
                        
                        if (req_is_write) begin
                            logic [BLOCK_BITS-1:0] merged; merged = mem_read_data;
                            for (int sec=0; sec<SECTORS; sec++) if(req_strobe[sec]) merged[(sec*SECTOR_BITS)+:SECTOR_BITS] = req_data[(sec*SECTOR_BITS)+:SECTOR_BITS];
                            data_array[req_index][victim_way] <= merged;
                            sector_dirty[req_index][victim_way] <= req_strobe;
                            up_write_ready[active_port] <= 1;
                        end else begin
                            data_array[req_index][victim_way] <= mem_read_data;
                            sector_dirty[req_index][victim_way] <= 0;
                            up_read_data[active_port] <= mem_read_data;
                            up_read_ready[active_port] <= 1;
                        end
                        
                        case (victim_way)
                            2'd0: begin plru_bits[req_index][0]<=1; plru_bits[req_index][1]<=1; end
                            2'd1: begin plru_bits[req_index][0]<=1; plru_bits[req_index][1]<=0; end
                            2'd2: begin plru_bits[req_index][0]<=0; plru_bits[req_index][2]<=1; end
                            2'd3: begin plru_bits[req_index][0]<=0; plru_bits[req_index][2]<=0; end
                        endcase
                        state <= IDLE;
                    end
                end

                FLUSH_SCAN: begin
                    if (!flush_en) state <= IDLE;
                    else if (valid_array[flush_set][flush_way_iter] && |sector_dirty[flush_set][flush_way_iter]) begin
                        if (vwb_push_ready) begin
                            vwb_push_valid <= 1;
                            vwb_push_addr <= {tag_array[flush_set][flush_way_iter], flush_set};
                            vwb_push_data <= data_array[flush_set][flush_way_iter];
                            vwb_push_sector_dirty <= sector_dirty[flush_set][flush_way_iter];
                            sector_dirty[flush_set][flush_way_iter] <= 0;
                            
                            if (flush_way_iter == WAYS - 1) begin
                                if (flush_set == SETS - 1) state <= FLUSH_WAIT;
                                else begin flush_set <= flush_set + 1; flush_way_iter <= 0; end
                            end else flush_way_iter <= flush_way_iter + 1;
                        end
                    end else begin
                        if (flush_way_iter == WAYS - 1) begin
                            if (flush_set == SETS - 1) state <= FLUSH_WAIT;
                            else begin flush_set <= flush_set + 1; flush_way_iter <= 0; end
                        end else flush_way_iter <= flush_way_iter + 1;
                    end
                end

                FLUSH_WAIT: begin
                    if (vwb_empty && !flush_en) state <= IDLE;
                end
            endcase
        end
    end
endmodule