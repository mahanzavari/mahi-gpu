`default_nettype none
`timescale 1ns/1ns

module l2_cache #(
    parameter ADDR_BITS   = gpu_pkg::CFG_DMEM_ADDR_BITS,
    parameter BLOCK_BITS  = gpu_pkg::AXI_DATA_WIDTH,
    parameter CACHE_LINES = gpu_pkg::CFG_L2_CACHE_LINES,
    parameter WAYS        = gpu_pkg::CFG_L2_WAYS,
    parameter SECTORS     = gpu_pkg::CFG_L2_SECTORS,
    // Trap 4 fix: L2 upstream ports MUST equal core count (1 dcache per core).
    // Bind directly to CFG_NUM_CORES so the two can never diverge.
    parameter NUM_PORTS   = gpu_pkg::CFG_NUM_CORES,
    parameter VWB_DEPTH   = gpu_pkg::CFG_VWB_DEPTH
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

    output wire ev_read_acc,
    output wire ev_read_hit,
    output wire ev_read_miss,
    output wire ev_write_acc,
    output wire ev_write_hit,
    output wire ev_write_miss,
    output wire ev_stall,
    output wire ev_evict
);

    localparam SETS = CACHE_LINES / WAYS;
    localparam INDEX_BITS = $clog2(SETS);
    localparam TAG_BITS = ADDR_BITS - INDEX_BITS;
    localparam SECTOR_BITS = BLOCK_BITS / SECTORS;
    // Bug 1 fix: $clog2(1)==0 produces illegal [-1:0]. Guard all 1-deep cases.
    // (mirrors the safe PTR_WIDTH pattern already used in controller.sv)
    localparam PORT_PTR_WIDTH = (NUM_PORTS > 1) ? $clog2(NUM_PORTS) : 1;
    localparam WAY_PTR_WIDTH  = (WAYS > 1) ? $clog2(WAYS) : 1;
    localparam LINE_BITS      = INDEX_BITS + WAY_PTR_WIDTH;

    reg                  valid_array   [SETS][WAYS];
    reg [SECTORS-1:0]    sector_dirty  [SETS][WAYS];
    reg [TAG_BITS-1:0]   tag_array     [SETS][WAYS];
    reg [WAYS-2:0]       plru_bits     [SETS];

    // Line data lives in l2_data_array (one SRAM macro in the ASIC profile). A line access takes
    // several cycles, so every data access below is "issue request -> WAIT_DATA -> act on done".
    reg                          eng_valid, eng_we;
    reg [LINE_BITS-1:0]          eng_line;
    reg [BLOCK_BITS-1:0]         eng_wdata;
    reg [SECTORS-1:0]            eng_wmask;
    wire                         eng_busy, eng_done;
    wire [BLOCK_BITS-1:0]        eng_rdata;

    l2_data_array #(.LINES(CACHE_LINES), .WORDS(BLOCK_BITS / 32)) data_eng (
        .clk(clk), .reset(reset), .req_valid(eng_valid), .req_we(eng_we), .req_line(eng_line),
        .req_wdata(eng_wdata), .req_wmask(eng_wmask), .busy(eng_busy), .done(eng_done), .rdata(eng_rdata));

    // Bug 1 fix: $clog2(1)==0 -> illegal [-1:0] when NUM_PORTS==1 (ASIC).
    reg [PORT_PTR_WIDTH-1:0] active_port;
    reg                  req_is_write;
    reg [ADDR_BITS-1:0]  req_addr;
    reg [BLOCK_BITS-1:0] req_data;
    reg [SECTORS-1:0]    req_strobe;
    reg [BLOCK_BITS-1:0] resp_data;      // read response held while the line write completes

    wire [INDEX_BITS-1:0] req_index = req_addr[INDEX_BITS-1:0];
    wire [TAG_BITS-1:0]   req_tag   = req_addr[ADDR_BITS-1:INDEX_BITS];

    logic hit;
    logic [WAY_PTR_WIDTH-1:0] hit_way;
    logic [WAY_PTR_WIDTH-1:0] victim_way;

    always_comb begin
        hit = 0; hit_way = 0;
        for (int w = 0; w < WAYS; w++) begin
            if (valid_array[req_index][w] && tag_array[req_index][w] == req_tag) begin
                hit = 1; hit_way = w[WAY_PTR_WIDTH-1:0];
            end
        end
        if (!plru_bits[req_index][0]) victim_way = !plru_bits[req_index][1] ? 2'd0 : 2'd1;
        else                          victim_way = !plru_bits[req_index][2] ? 2'd2 : 2'd3;
    end

    // Tree-PLRU update for an access to `way` (4 ways).
    function automatic [WAYS-2:0] plru_touch(input [WAYS-2:0] cur, input [1:0] way);
        reg [WAYS-2:0] n;
        begin
            n = cur;
            case (way)
                2'd0: begin n[0] = 1; n[1] = 1; end
                2'd1: begin n[0] = 1; n[1] = 0; end
                2'd2: begin n[0] = 0; n[2] = 1; end
                2'd3: begin n[0] = 0; n[2] = 0; end
            endcase
            plru_touch = n;
        end
    endfunction

    reg                  vwb_push_valid;
    reg [ADDR_BITS-1:0]  vwb_push_addr;
    reg [BLOCK_BITS-1:0] vwb_push_data;
    reg [SECTORS-1:0]    vwb_push_sector_dirty;
    wire                 vwb_push_ready;
    // push_ready reflects entries *already counted*; a push issued last cycle
    // (vwb_push_valid still high) has not been counted yet. Deciding to push
    // based on push_ready alone let back-to-back pushes overflow the buffer,
    // where the VWB silently drops the line (lost dirty data).
    // The victim line is read from the data engine (several cycles) between this check and the
    // actual push; the VWB only drains in that window and only this FSM pushes, so it stays true.
    wire                 vwb_can_push = vwb_push_ready && !vwb_push_valid;
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

    typedef enum logic [2:0] { IDLE, SERVING, FETCHING, FLUSH_SCAN, FLUSH_WAIT, WAIT_DATA, FLUSH_READ } state_t;
    state_t state;
    // What to do when the data engine finishes (state WAIT_DATA)
    typedef enum logic [1:0] { K_HIT_READ, K_RESPOND, K_PUSH_VICTIM } cont_t;
    cont_t cont;

    reg [PORT_PTR_WIDTH-1:0] arb_ptr;
    reg [INDEX_BITS-1:0] flush_set;
    reg [$clog2(WAYS)-1:0] flush_way_iter;

    assign flush_done = (state == FLUSH_WAIT) && vwb_empty;

    // hoisted scratch (Verilator makes block-local initialised variables static)
    logic found;
    int   check_p;
    logic victim_dirty;
    logic [BLOCK_BITS-1:0] merged;
    logic [SECTORS-1:0]    next_dirty;

    always @(posedge clk) begin
        if (reset) begin
            state <= IDLE;
            mem_read_valid <= 0; up_read_ready <= 0; up_write_ready <= 0;
            arb_ptr <= 0; vwb_push_valid <= 0; vwb_probe_pop <= 0;
            eng_valid <= 0; eng_we <= 0; eng_line <= 0; eng_wdata <= 0; eng_wmask <= 0;
            cont <= K_HIT_READ; resp_data <= 0;
            for (int s = 0; s < SETS; s++) begin
                plru_bits[s] <= 0;
                for (int w = 0; w < WAYS; w++) begin
                    valid_array[s][w] <= 0; sector_dirty[s][w] <= 0;
                end
            end
        end else begin
            up_read_ready <= 0; up_write_ready <= 0;
            vwb_push_valid <= 0; vwb_probe_pop <= 0;
            eng_valid <= 0;

            case (state)
                IDLE: begin
                    if (flush_en) begin
                        flush_set <= 0; flush_way_iter <= 0; state <= FLUSH_SCAN;
                    end else begin
                        found = 0;
                        for (int p = 0; p < NUM_PORTS; p++) begin
                            check_p = (arb_ptr + p) % NUM_PORTS;
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
                        plru_bits[req_index] <= plru_touch(plru_bits[req_index], hit_way);
                        eng_valid <= 1; eng_line <= {req_index, hit_way};
                        if (req_is_write) begin
                            // sectors are whole 32-bit words: write only the strobed words, no read needed
                            next_dirty = sector_dirty[req_index][hit_way];
                            for (int sec = 0; sec < SECTORS; sec++) if (req_strobe[sec]) next_dirty[sec] = 1'b1;
                            sector_dirty[req_index][hit_way] <= next_dirty;
                            eng_we <= 1; eng_wdata <= req_data; eng_wmask <= req_strobe;
                            cont <= K_RESPOND;
                        end else begin
                            eng_we <= 0; eng_wmask <= 0;
                            cont <= K_HIT_READ;
                        end
                        state <= WAIT_DATA;
                    end else begin
                        victim_dirty = valid_array[req_index][victim_way] && |sector_dirty[req_index][victim_way];
                        if (victim_dirty) begin
                            // Write the victim back first (read its line, push to the VWB), then re-decide:
                            // the victim is clean afterwards, so the VWB-probe / miss paths below apply.
                            if (vwb_can_push) begin
                                eng_valid <= 1; eng_we <= 0; eng_line <= {req_index, victim_way}; eng_wmask <= 0;
                                cont <= K_PUSH_VICTIM; state <= WAIT_DATA;
                            end // else stall until the VWB has room
                        end else if (vwb_probe_hit) begin
                            vwb_probe_pop <= 1; vwb_pop_addr <= req_addr;
                            valid_array[req_index][victim_way] <= 1;
                            tag_array[req_index][victim_way] <= req_tag;
                            merged = vwb_probe_data;
                            if (req_is_write) begin
                                for (int sec=0; sec<SECTORS; sec++) if (req_strobe[sec]) merged[(sec*SECTOR_BITS)+:SECTOR_BITS] = req_data[(sec*SECTOR_BITS)+:SECTOR_BITS];
                                sector_dirty[req_index][victim_way] <= vwb_probe_sector_valid | req_strobe;
                            end else begin
                                sector_dirty[req_index][victim_way] <= vwb_probe_sector_valid;
                            end
                            resp_data <= vwb_probe_data;
                            eng_valid <= 1; eng_we <= 1; eng_line <= {req_index, victim_way};
                            eng_wdata <= merged; eng_wmask <= {SECTORS{1'b1}};
                            plru_bits[req_index] <= plru_touch(plru_bits[req_index], victim_way);
                            cont <= K_RESPOND; state <= WAIT_DATA;
                        end else begin
                            mem_read_valid <= 1; mem_read_addr <= req_addr; state <= FETCHING;
                        end
                    end
                end

                FETCHING: begin
                    if (mem_read_ready) begin
                        mem_read_valid <= 0;
                        valid_array[req_index][victim_way] <= 1; tag_array[req_index][victim_way] <= req_tag;
                        merged = mem_read_data;
                        if (req_is_write) begin
                            for (int sec=0; sec<SECTORS; sec++) if (req_strobe[sec]) merged[(sec*SECTOR_BITS)+:SECTOR_BITS] = req_data[(sec*SECTOR_BITS)+:SECTOR_BITS];
                            sector_dirty[req_index][victim_way] <= req_strobe;
                        end else begin
                            sector_dirty[req_index][victim_way] <= 0;
                        end
                        resp_data <= mem_read_data;
                        eng_valid <= 1; eng_we <= 1; eng_line <= {req_index, victim_way};
                        eng_wdata <= merged; eng_wmask <= {SECTORS{1'b1}};
                        plru_bits[req_index] <= plru_touch(plru_bits[req_index], victim_way);
                        cont <= K_RESPOND; state <= WAIT_DATA;
                    end
                end

                WAIT_DATA: begin
                    if (eng_done) begin
                        case (cont)
                            K_HIT_READ: begin
                                up_read_data[active_port] <= eng_rdata;
                                up_read_ready[active_port] <= 1;
                                state <= IDLE;
                            end
                            K_RESPOND: begin
                                if (req_is_write) up_write_ready[active_port] <= 1;
                                else begin
                                    up_read_data[active_port] <= resp_data;
                                    up_read_ready[active_port] <= 1;
                                end
                                state <= IDLE;
                            end
                            K_PUSH_VICTIM: begin
                                vwb_push_valid <= 1;
                                vwb_push_addr <= {tag_array[req_index][victim_way], req_index};
                                vwb_push_data <= eng_rdata;
                                vwb_push_sector_dirty <= sector_dirty[req_index][victim_way];
                                sector_dirty[req_index][victim_way] <= 0;
                                state <= SERVING;
                            end
                            default: state <= IDLE;
                        endcase
                    end
                end

                FLUSH_SCAN: begin
                    if (!flush_en) state <= IDLE;
                    else if (valid_array[flush_set][flush_way_iter] && |sector_dirty[flush_set][flush_way_iter]) begin
                        if (vwb_can_push) begin
                            eng_valid <= 1; eng_we <= 0; eng_wmask <= 0; eng_line <= {flush_set, flush_way_iter};
                            state <= FLUSH_READ;
                        end
                    end else begin
                        if (flush_way_iter == WAYS - 1) begin
                            if (flush_set == SETS - 1) state <= FLUSH_WAIT;
                            else begin flush_set <= flush_set + 1; flush_way_iter <= 0; end
                        end else flush_way_iter <= flush_way_iter + 1;
                    end
                end

                FLUSH_READ: begin
                    if (eng_done) begin
                        vwb_push_valid <= 1;
                        vwb_push_addr <= {tag_array[flush_set][flush_way_iter], flush_set};
                        vwb_push_data <= eng_rdata;
                        vwb_push_sector_dirty <= sector_dirty[flush_set][flush_way_iter];
                        sector_dirty[flush_set][flush_way_iter] <= 0;
                        if (flush_way_iter == WAYS - 1) begin
                            if (flush_set == SETS - 1) state <= FLUSH_WAIT;
                            else begin flush_set <= flush_set + 1; flush_way_iter <= 0; state <= FLUSH_SCAN; end
                        end else begin flush_way_iter <= flush_way_iter + 1; state <= FLUSH_SCAN; end
                    end
                end

                FLUSH_WAIT: begin
                    if (vwb_empty && !flush_en) state <= IDLE;
                end

                default: state <= IDLE;
            endcase
        end
    end

    assign ev_read_acc   = 1'b0;
    assign ev_read_hit   = 1'b0;
    assign ev_read_miss  = 1'b0;
    assign ev_write_acc  = 1'b0;
    assign ev_write_hit  = 1'b0;
    assign ev_write_miss = 1'b0;
    assign ev_stall      = 1'b0;
    assign ev_evict      = 1'b0;
endmodule
