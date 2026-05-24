// --- Begin: src/dcache.sv ---
`default_nettype none
`timescale 1ns/1ns

module dcache #(
    parameter ADDR_BITS = 32,
    parameter BLOCK_BITS = 128,
    parameter CACHE_LINES = 64
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

    output wire ev_read_acc,
    output wire ev_read_hit,
    output wire ev_read_stall,
    output wire ev_write_acc,
    output wire ev_write_hit,
    output wire ev_write_stall
);

    localparam WAYS = 2;
    localparam SETS = CACHE_LINES / WAYS;
    localparam INDEX_BITS = $clog2(SETS);
    localparam TAG_BITS = ADDR_BITS - INDEX_BITS;

    reg valid_array [SETS][WAYS];
    reg [TAG_BITS-1:0] tag_array [SETS][WAYS];
    reg [BLOCK_BITS-1:0] data_array [SETS][WAYS];
    reg lru_bit [SETS]; 

    typedef enum logic [1:0] { IDLE, FETCHING_READ, WAITING_WRITE } state_t;
    state_t state;

    wire [INDEX_BITS-1:0] req_index = core_read_valid ? core_read_block_addr[INDEX_BITS-1:0] : core_write_block_addr[INDEX_BITS-1:0];
    wire [TAG_BITS-1:0]   req_tag   = core_read_valid ? core_read_block_addr[ADDR_BITS-1:INDEX_BITS] : core_write_block_addr[ADDR_BITS-1:INDEX_BITS];

    wire hit_w0 = valid_array[req_index][0] && (tag_array[req_index][0] == req_tag);
    wire hit_w1 = valid_array[req_index][1] && (tag_array[req_index][1] == req_tag);
    wire hit = hit_w0 || hit_w1;
    wire hit_way = hit_w1; 
    wire victim_way = lru_bit[req_index];

    always @(posedge clk) begin
        if (reset) begin
            state <= IDLE;
            mem_read_valid <= 0; mem_write_valid <= 0;
            core_read_ready <= 0; core_write_ready <= 0;
            flush_done <= 0;
            for (int s = 0; s < SETS; s++) begin
                lru_bit[s] <= 0;
                for (int w = 0; w < WAYS; w++) valid_array[s][w] <= 0;
            end
        end else begin
            core_read_ready <= 0; core_write_ready <= 0;
            flush_done <= 0;

            case (state)
                IDLE: begin
                    if (flush_en) begin
                        for (int s = 0; s < SETS; s++) begin
                            for (int w = 0; w < WAYS; w++) valid_array[s][w] <= 0;
                        end
                        flush_done <= 1; // Real registered handshake flag
                    end
                    else if (core_write_valid && !core_write_ready) begin
                        mem_write_valid <= 1;
                        mem_write_block_addr <= core_write_block_addr;
                        mem_write_block_data <= core_write_block_data;
                        mem_write_strobe <= core_write_strobe;
                        state <= WAITING_WRITE;

                        if (hit) begin
                            logic [BLOCK_BITS-1:0] merged_data;
                            merged_data = data_array[req_index][hit_way];
                            if (core_write_strobe[0]) merged_data[31:0] = core_write_block_data[31:0];
                            if (core_write_strobe[1]) merged_data[63:32] = core_write_block_data[63:32];
                            if (core_write_strobe[2]) merged_data[95:64] = core_write_block_data[95:64];
                            if (core_write_strobe[3]) merged_data[127:96] = core_write_block_data[127:96];
                            data_array[req_index][hit_way] <= merged_data;
                            lru_bit[req_index] <= ~hit_way;
                        end
                    end 
                    else if (core_read_valid && !core_read_ready) begin
                        if (hit) begin
                            core_read_block_data <= data_array[req_index][hit_way];
                            lru_bit[req_index] <= ~hit_way;
                            core_read_ready <= 1;
                        end else begin
                            mem_read_valid <= 1;
                            mem_read_block_addr <= core_read_block_addr;
                            state <= FETCHING_READ;
                        end
                    end
                end

                WAITING_WRITE: begin
                    if (mem_write_ready) begin
                        mem_write_valid <= 0;
                        core_write_ready <= 1;
                        state <= IDLE;
                    end
                end

                FETCHING_READ: begin
                    if (mem_read_ready) begin
                        mem_read_valid <= 0;
                        valid_array[req_index][victim_way] <= 1;
                        tag_array[req_index][victim_way] <= req_tag;
                        data_array[req_index][victim_way] <= mem_read_block_data;
                        lru_bit[req_index] <= ~victim_way;

                        core_read_block_data <= mem_read_block_data;
                        core_read_ready <= 1;
                        state <= IDLE;
                    end
                end
            endcase
        end
    end

    assign ev_read_acc   = (state == IDLE && core_read_valid);
    assign ev_read_hit   = (state == IDLE && core_read_valid && hit);
    assign ev_read_stall = (core_read_valid && !core_read_ready);
    assign ev_write_acc  = (state == IDLE && core_write_valid);
    assign ev_write_hit  = (state == IDLE && core_write_valid && hit);
    assign ev_write_stall= (core_write_valid && !core_write_ready);

endmodule