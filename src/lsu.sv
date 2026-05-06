`default_nettype none
`timescale 1ns/1ns

module lsu #(
    parameter DATA_BITS = 32,
    parameter NUM_WARPS = 4,
    parameter THREADS_PER_BLOCK = 4,
    parameter WORDS_PER_BLOCK = 4,
    parameter DEBUG = 1
) (
    input wire clk,
    input wire reset,
    
    input wire [THREADS_PER_BLOCK-1:0] enable_mask, 
    input wire [$clog2(NUM_WARPS)-1:0] warp_id,
    input wire decoded_mem_read_enable,
    input wire decoded_mem_write_enable,
    input wire decoded_shared_read_enable,
    input wire decoded_shared_write_enable,
    input wire decoded_atomic, // <--- [ATOMIC] Port 
    input wire [4:0] decoded_rd,
    input wire [DATA_BITS-1:0] rs [THREADS_PER_BLOCK],
    input wire [DATA_BITS-1:0] rt [THREADS_PER_BLOCK],

    input wire [15:0] addr_offset,
    input wire        use_offset,

    output reg mem_read_valid,
    output reg [31:0] mem_read_block_address,
    input wire mem_read_ready,
    input wire [(DATA_BITS*WORDS_PER_BLOCK)-1:0] mem_read_block_data,
    
    output reg mem_write_valid,
    output reg [31:0] mem_write_block_address,
    output reg [(DATA_BITS*WORDS_PER_BLOCK)-1:0] mem_write_block_data,
    output reg [WORDS_PER_BLOCK-1:0] mem_write_strobe,
    input wire mem_write_ready,

    output reg [THREADS_PER_BLOCK-1:0] shared_mem_read_valid,    
    output reg [31:0] shared_mem_read_address [THREADS_PER_BLOCK],
    input wire [THREADS_PER_BLOCK-1:0] shared_mem_read_ready,
    input wire [DATA_BITS-1:0] shared_mem_read_data [THREADS_PER_BLOCK],
    
    output reg [THREADS_PER_BLOCK-1:0] shared_mem_write_valid,
    output reg [31:0] shared_mem_write_address [THREADS_PER_BLOCK],
    output reg [DATA_BITS-1:0] shared_mem_write_data [THREADS_PER_BLOCK],
    input wire [THREADS_PER_BLOCK-1:0] shared_mem_write_ready,

    output reg [THREADS_PER_BLOCK-1:0] lsu_we,
    output reg [$clog2(NUM_WARPS)-1:0] lsu_warp_id,
    output reg [4:0] lsu_rd, 
    output reg [DATA_BITS-1:0] lsu_data [THREADS_PER_BLOCK],

    output reg [THREADS_PER_BLOCK-1:0] done_pulse,
    output reg [$clog2(NUM_WARPS)-1:0] done_warp_id [THREADS_PER_BLOCK]
);

    reg req_valid [NUM_WARPS];
    reg [2:0] req_type [NUM_WARPS]; 
    reg [THREADS_PER_BLOCK-1:0] req_mask [NUM_WARPS];
    reg [31:0] req_addr [NUM_WARPS][THREADS_PER_BLOCK];
    reg [DATA_BITS-1:0] req_data_val [NUM_WARPS][THREADS_PER_BLOCK];
    reg [4:0] req_rd [NUM_WARPS]; 

    wire [31:0] incoming_effective_addr [THREADS_PER_BLOCK];
    genvar i;
    generate
        for (i = 0; i < THREADS_PER_BLOCK; i++) begin
            assign incoming_effective_addr[i] = use_offset ? (rs[i] + {{16{addr_offset[15]}}, addr_offset}) : rs[i];
        end
    endgenerate

    typedef enum logic [3:0] { 
        IDLE, COALESCE_READ, WAIT_READ, COALESCE_WRITE, WAIT_WRITE, WAIT_SHARED,
        ATOMIC_READ, ATOMIC_WAIT_READ, ATOMIC_WAIT_WRITE 
    } state_t;
    
    state_t state;

    reg [$clog2(NUM_WARPS)-1:0] active_warp;
    reg [THREADS_PER_BLOCK-1:0] pending_threads;
    reg [31:0] current_block_addr;
    reg [2:0] active_t; // Serial tracking for atomics

    wire [31:0] active_block_addr [THREADS_PER_BLOCK];
    wire [1:0] active_word_offset [THREADS_PER_BLOCK];
    
    generate
        for (i = 0; i < THREADS_PER_BLOCK; i++) begin
            assign active_block_addr[i] = req_addr[active_warp][i] >> $clog2(WORDS_PER_BLOCK);
            assign active_word_offset[i] = req_addr[active_warp][i] & (WORDS_PER_BLOCK - 1);
        end
    endgenerate

    integer w, t;

    always @(posedge clk) begin
        if (reset) begin
            state <= IDLE; mem_read_valid <= 0; mem_write_valid <= 0;
            shared_mem_read_valid <= 0; shared_mem_write_valid <= 0;
            lsu_we <= 0; done_pulse <= 0;
            for (w = 0; w < NUM_WARPS; w++) req_valid[w] <= 0;
        end else begin
            lsu_we <= 0; done_pulse <= 0;

            if (|enable_mask && (decoded_mem_read_enable || decoded_mem_write_enable || decoded_shared_read_enable || decoded_shared_write_enable || decoded_atomic)) begin
                req_valid[warp_id] <= 1;
                req_mask[warp_id] <= enable_mask;
                req_rd[warp_id] <= decoded_rd;
                for (t = 0; t < THREADS_PER_BLOCK; t++) begin
                    req_addr[warp_id][t] <= incoming_effective_addr[t];
                    req_data_val[warp_id][t] <= rt[t];
                end
                
                // Priority Routing
                if (decoded_atomic) req_type[warp_id] <= 3'd4;
                else if (decoded_mem_read_enable) req_type[warp_id] <= 3'd0;
                else if (decoded_mem_write_enable) req_type[warp_id] <= 3'd1;
                else if (decoded_shared_read_enable) req_type[warp_id] <= 3'd2;
                else req_type[warp_id] <= 3'd3;
            end

            case (state)
                IDLE: begin
                    int selected_w = -1;
                    for (w = 0; w < NUM_WARPS; w++) begin
                        if (selected_w == -1 && req_valid[w]) selected_w = w;
                    end

                    if (selected_w != -1) begin
                        active_warp <= selected_w; pending_threads <= req_mask[selected_w];
                        lsu_warp_id <= selected_w; lsu_rd <= req_rd[selected_w];

                        if (req_type[selected_w] == 3'd0) state <= COALESCE_READ;
                        else if (req_type[selected_w] == 3'd1) state <= COALESCE_WRITE;
                        else if (req_type[selected_w] == 3'd4) state <= ATOMIC_READ; // Route to ATOM_ADD
                        else begin
                            for (t = 0; t < THREADS_PER_BLOCK; t++) begin
                                if (req_mask[selected_w][t]) begin
                                    if (req_type[selected_w] == 3'd2) begin
                                        shared_mem_read_valid[t] <= 1; shared_mem_read_address[t] <= req_addr[selected_w][t];
                                    end else begin
                                        shared_mem_write_valid[t] <= 1; shared_mem_write_address[t] <= req_addr[selected_w][t];
                                        shared_mem_write_data[t] <= req_data_val[selected_w][t];
                                    end
                                end
                            end
                            state <= WAIT_SHARED;
                        end
                    end
                end

                COALESCE_READ: begin
                    if (|pending_threads) begin
                        int first_pending = -1;
                        for (t = 0; t < THREADS_PER_BLOCK; t++) if (first_pending == -1 && pending_threads[t]) first_pending = t;
                        current_block_addr <= active_block_addr[first_pending];
                        mem_read_block_address <= active_block_addr[first_pending];
                        mem_read_valid <= 1; state <= WAIT_READ;
                    end else begin
                        req_valid[active_warp] <= 0; state <= IDLE;
                    end
                end

                WAIT_READ: begin
                    if (mem_read_ready) begin
                        mem_read_valid <= 0;
                        for (t = 0; t < THREADS_PER_BLOCK; t++) begin
                            if (pending_threads[t] && active_block_addr[t] == current_block_addr) begin
                                pending_threads[t] <= 0; lsu_we[t] <= 1;
                                lsu_data[t] <= mem_read_block_data[(active_word_offset[t] * DATA_BITS) +: DATA_BITS];
                                done_pulse[t] <= 1; done_warp_id[t] <= lsu_warp_id;
                            end
                        end
                        state <= COALESCE_READ; 
                    end
                end

                COALESCE_WRITE: begin
                    if (|pending_threads) begin
                        int first_pending = -1;
                        for (t = 0; t < THREADS_PER_BLOCK; t++) if (first_pending == -1 && pending_threads[t]) first_pending = t;
                        current_block_addr <= active_block_addr[first_pending];
                        mem_write_block_address <= active_block_addr[first_pending];
                        
                        // Robust Write Combination logic
                        begin : coalesce_wr
                            logic [(DATA_BITS*WORDS_PER_BLOCK)-1:0] next_wd;
                            logic [WORDS_PER_BLOCK-1:0] next_strobe;
                            next_wd = 0;
                            next_strobe = 0;
                            
                            for (t = 0; t < THREADS_PER_BLOCK; t++) begin
                                if (pending_threads[t] && active_block_addr[t] == active_block_addr[first_pending]) begin
                                    next_wd[(active_word_offset[t] * DATA_BITS) +: DATA_BITS] = req_data_val[active_warp][t];
                                    next_strobe[active_word_offset[t]] = 1'b1;
                                end
                            end
                            
                            mem_write_block_data <= next_wd;
                            mem_write_strobe <= next_strobe;
                        end
                        
                        mem_write_valid <= 1; 
                        state <= WAIT_WRITE;
                    end else begin
                        req_valid[active_warp] <= 0; state <= IDLE;
                    end
                end

                WAIT_WRITE: begin
                    if (mem_write_ready) begin
                        mem_write_valid <= 0;
                        for (t = 0; t < THREADS_PER_BLOCK; t++) begin
                            if (pending_threads[t] && active_block_addr[t] == current_block_addr) begin
                                pending_threads[t] <= 0; done_pulse[t] <= 1; done_warp_id[t] <= lsu_warp_id;
                            end
                        end
                        state <= COALESCE_WRITE;
                    end
                end
                
                // --- ATOMIC SERIALIZATION ENGINE -----------------------------
                ATOMIC_READ: begin
                    if (|pending_threads) begin
                        int first_pending = -1;
                        for (t = 0; t < THREADS_PER_BLOCK; t++) 
                            if (first_pending == -1 && pending_threads[t]) first_pending = t;
                            
                        active_t <= first_pending;
                        current_block_addr <= active_block_addr[first_pending];
                        mem_read_block_address <= active_block_addr[first_pending];
                        mem_read_valid <= 1;
                        state <= ATOMIC_WAIT_READ;
                    end else begin
                        req_valid[active_warp] <= 0; 
                        state <= IDLE;
                    end
                end
                
                ATOMIC_WAIT_READ: begin
                    if (mem_read_ready) begin
                        mem_read_valid <= 0;
                        
                        // Robust compute block: No partial/non-blocking vector overwrites
                        begin : atomic_math
                            logic [DATA_BITS-1:0] old_val;
                            logic [DATA_BITS-1:0] sum;
                            
                            // 1. Shift and Mask out the correct old value word
                            old_val = (mem_read_block_data >> (active_word_offset[active_t] * DATA_BITS)) & 32'hFFFFFFFF;
                            
                            // 2. Perform the Addition
                            sum = old_val + req_data_val[active_warp][active_t];
                            
                            // 3. Prep the target old value to write back to Rd
                            lsu_data[active_t] <= old_val;
                            
                            // 4. Setup the LSU output pins explicitly (Clean assignments)
                            mem_write_block_address <= current_block_addr;
                            mem_write_strobe <= (4'b0001 << active_word_offset[active_t]);
                            mem_write_block_data <= ({96'd0, sum} << (active_word_offset[active_t] * DATA_BITS));
                        end
                        
                        mem_write_valid <= 1;
                        state <= ATOMIC_WAIT_WRITE;
                    end
                end
                
                ATOMIC_WAIT_WRITE: begin
                    if (mem_write_ready) begin
                        mem_write_valid <= 0;
                        
                        // Clean bitwise clear prevents array-overwrite simulation bugs
                        pending_threads <= pending_threads & ~(1 << active_t);
                        
                        // Awaken the thread simultaneously with the write acknowledgement
                        lsu_we[active_t] <= 1;
                        done_pulse[active_t] <= 1;
                        done_warp_id[active_t] <= lsu_warp_id;
                        
                        state <= ATOMIC_READ; // Loop to next thread
                    end
                end
                // -------------------------------------------------------------

                WAIT_SHARED: begin
                    for (t = 0; t < THREADS_PER_BLOCK; t++) begin
                        if (pending_threads[t]) begin
                            if (shared_mem_read_ready[t]) begin
                                lsu_we[t] <= 1; lsu_data[t] <= shared_mem_read_data[t];
                                pending_threads[t] <= 0; shared_mem_read_valid[t] <= 0;
                                done_pulse[t] <= 1; done_warp_id[t] <= lsu_warp_id;
                            end else if (shared_mem_write_ready[t]) begin
                                pending_threads[t] <= 0; shared_mem_write_valid[t] <= 0;
                                done_pulse[t] <= 1; done_warp_id[t] <= lsu_warp_id;
                            end
                        end
                    end
                    if (pending_threads == 0) begin
                        req_valid[active_warp] <= 0; state <= IDLE;
                    end
                end
            endcase
        end
    end
endmodule