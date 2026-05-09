`default_nettype none
`timescale 1ns/1ns

module victim_write_buffer #(
    parameter ADDR_BITS  = 32,
    parameter BLOCK_BITS = 128,
    parameter SECTORS    = 4,
    parameter DEPTH      = 4
) (
    input wire clk,
    input wire reset,

    // --- Push Interface (from dcache eviction) ---
    input wire                   push_valid,
    input wire [ADDR_BITS-1:0]   push_addr,
    input wire [BLOCK_BITS-1:0]  push_data,
    input wire [SECTORS-1:0]     push_sector_dirty,
    output wire                  push_ready,

    // --- Probe Interface (dcache checks before going to memory) ---
    input wire                   probe_valid,
    input wire [ADDR_BITS-1:0]   probe_addr,
    output logic                 probe_hit,
    output logic [BLOCK_BITS-1:0] probe_data,
    output logic [SECTORS-1:0]   probe_sector_valid,

    // --- Pop Interface (dcache removes line if it hits) ---
    input wire                   probe_pop,
    input wire [ADDR_BITS-1:0]   pop_addr,

    // --- Drain Interface (to memory controller) ---
    output reg                   mem_write_valid,
    output reg [ADDR_BITS-1:0]   mem_write_addr,
    output reg [BLOCK_BITS-1:0]  mem_write_data,
    output reg [SECTORS-1:0]     mem_write_strobe,
    input wire                   mem_write_ready,

    // --- Control / Status ---
    input wire                   flush_en,
    output wire                  empty,
    output wire                  full
);

    localparam SECTOR_BITS = BLOCK_BITS / SECTORS;

    reg                  valid   [DEPTH];
    reg [ADDR_BITS-1:0]  addr    [DEPTH];
    reg [BLOCK_BITS-1:0] data    [DEPTH];
    reg [SECTORS-1:0]    dirty   [DEPTH];

    reg [15:0] count;
    reg [15:0] next_count;

    assign empty = (count == 0);
    assign full  = (count == DEPTH);
    assign push_ready = !full;

    // --- Merge & Allocate Detection ---
    logic merge_found;
    logic [$clog2(DEPTH)-1:0] merge_idx;
    logic free_found;
    logic [$clog2(DEPTH)-1:0] free_idx;

    always_comb begin
        merge_found = 1'b0; merge_idx = '0;
        free_found  = 1'b0; free_idx  = '0;
        for (int i = 0; i < DEPTH; i++) begin
            if (valid[i] && addr[i] == push_addr && !merge_found) begin
                merge_found = 1'b1; merge_idx = i[$clog2(DEPTH)-1:0];
            end
            if (!valid[i] && !free_found) begin
                free_found = 1'b1; free_idx = i[$clog2(DEPTH)-1:0];
            end
        end
    end

    // --- Combinational Probe ---
    always_comb begin
        probe_hit = 1'b0; probe_data = '0; probe_sector_valid = '0;
        if (probe_valid) begin
            for (int i = 0; i < DEPTH; i++) begin
                if (valid[i] && addr[i] == probe_addr) begin
                    probe_hit = 1'b1;
                    probe_data = data[i];
                    probe_sector_valid = dirty[i];
                end
            end
        end
    end

    // --- Drain Target Selection ---
    logic drain_pending;
    logic [$clog2(DEPTH)-1:0] drain_idx;
    always_comb begin
        drain_pending = 1'b0; drain_idx = '0;
        for (int i = 0; i < DEPTH; i++) begin
            if (valid[i] && !drain_pending) begin
                drain_pending = 1'b1; drain_idx = i[$clog2(DEPTH)-1:0];
            end
        end
    end

    typedef enum logic [1:0] { IDLE, DRAINING } state_t;
    state_t state;

    // --- Active Drain State Registers (FIXES THE SILENT DROP BUG) ---
    reg [$clog2(DEPTH)-1:0] active_drain_idx;
    reg                     active_drain_valid;

    always @(posedge clk) begin
        if (reset) begin
            state <= IDLE;
            mem_write_valid <= 0;
            count <= 0;
            active_drain_idx <= 0;
            active_drain_valid <= 0;
            for (int k = 0; k < DEPTH; k++) begin
                valid[k] <= 0; dirty[k] <= 0;
            end
        end else begin
            // 1. Data Merging & Allocation
            if (push_valid && push_ready) begin
                if (merge_found) begin
                    for (int s = 0; s < SECTORS; s++) begin
                        if (push_sector_dirty[s]) begin
                            data[merge_idx][(s*SECTOR_BITS) +: SECTOR_BITS] <= push_data[(s*SECTOR_BITS) +: SECTOR_BITS];
                        end
                    end
                    dirty[merge_idx] <= dirty[merge_idx] | push_sector_dirty;
                end else if (free_found) begin
                    addr[free_idx]  <= push_addr;
                    data[free_idx]  <= push_data;
                    dirty[free_idx] <= push_sector_dirty;
                end
            end

            // 2. Memory Drain FSM
            case (state)
                IDLE: begin
                    if (drain_pending && (flush_en || count > DEPTH/2)) begin
                        // Prevent draining if the dcache is Popping this exact slot right now
                        if (!(probe_pop && addr[drain_idx] == pop_addr)) begin
                            mem_write_valid  <= 1;
                            mem_write_addr   <= addr[drain_idx];
                            mem_write_data   <= data[drain_idx];
                            mem_write_strobe <= dirty[drain_idx];
                            active_drain_idx <= drain_idx;
                            active_drain_valid <= 1'b1;
                            state <= DRAINING;
                        end
                    end
                end
                DRAINING: begin
                    // If the dcache pops the line while it's inflight to memory, 
                    // clear the flag so we don't accidentally delete a new occupant later!
                    if (probe_pop && valid[active_drain_idx] && addr[active_drain_idx] == pop_addr) begin
                        active_drain_valid <= 1'b0;
                    end

                    if (mem_write_ready) begin
                        mem_write_valid <= 0;
                        state <= IDLE;
                    end
                end
            endcase

            // 3. Collision-Safe Occupancy Tracking
            next_count = 0;
            for (int i = 0; i < DEPTH; i++) begin
                logic v_next;
                v_next = valid[i];

                if (push_valid && push_ready && !merge_found && free_found && i == free_idx)
                    v_next = 1'b1;

                // Clear slot ONLY if it wasn't popped by the dcache during the drain!
                if (state == DRAINING && mem_write_ready && i == active_drain_idx && active_drain_valid) begin
                    v_next = 1'b0; dirty[i] <= 0;
                end

                if (probe_pop && valid[i] && addr[i] == pop_addr) begin
                    v_next = 1'b0; dirty[i] <= 0;
                end

                valid[i] <= v_next;
                if (v_next) next_count = next_count + 1;
            end
            count <= next_count;
        end
    end
endmodule