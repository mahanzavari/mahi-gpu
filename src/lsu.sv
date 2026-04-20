`default_nettype none
`timescale 1ns/1ns

module lsu #(
    parameter DATA_BITS = 16,
    parameter NUM_WARPS = 4,
    parameter DEBUG = 1
) (
    input wire clk,
    input wire reset,
    
    // Pipeline Request Port
    input wire enable, 
    input wire [$clog2(NUM_WARPS)-1:0] warp_id,
    input wire decoded_mem_read_enable,
    input wire decoded_mem_write_enable,
    input wire decoded_shared_read_enable,
    input wire decoded_shared_write_enable,
    input wire [3:0] decoded_rd,
    input wire [DATA_BITS-1:0] rs,
    input wire [DATA_BITS-1:0] rt,

    // External Memory Ports
    output reg mem_read_valid,
    output reg [7:0] mem_read_address,
    input wire mem_read_ready,
    input wire [DATA_BITS-1:0] mem_read_data,
    
    output reg mem_write_valid,
    output reg [7:0] mem_write_address,
    output reg [DATA_BITS-1:0] mem_write_data,
    input wire mem_write_ready,

    output reg shared_mem_read_valid,    
    output reg [7:0] shared_mem_read_address,
    input wire shared_mem_read_ready,
    input wire [DATA_BITS-1:0] shared_mem_read_data,
    
    output reg shared_mem_write_valid,
    output reg [7:0] shared_mem_write_address,
    output reg [DATA_BITS-1:0] shared_mem_write_data,
    input wire shared_mem_write_ready,

    // Writeback to Register File
    output reg lsu_we,
    output reg [$clog2(NUM_WARPS)-1:0] lsu_warp_id,
    output reg [3:0] lsu_rd,
    output reg [DATA_BITS-1:0] lsu_data,

    // Core Tracking Pulse
    output reg done_pulse,
    output reg [$clog2(NUM_WARPS)-1:0] done_warp_id
);

    // Internal Buffers for outstanding requests
    reg req_valid [NUM_WARPS-1:0];
    reg [2:0] req_type [NUM_WARPS-1:0]; // 0:GRD, 1:GWR, 2:SRD, 3:SWR
    reg [7:0] req_addr [NUM_WARPS-1:0];
    reg [DATA_BITS-1:0] req_data_val [NUM_WARPS-1:0];
    reg [3:0] req_rd [NUM_WARPS-1:0];

    reg port_busy;
    reg [$clog2(NUM_WARPS)-1:0] active_warp;
    reg [2:0] active_type;

    always @(posedge clk) begin
        if (reset) begin
            lsu_we <= 0; done_pulse <= 0; port_busy <= 0;
            mem_read_valid <= 0; mem_write_valid <= 0;
            shared_mem_read_valid <= 0; shared_mem_write_valid <= 0;
            for (int w=0; w<NUM_WARPS; w++) req_valid[w] <= 0;
        end else begin
            lsu_we <= 0; done_pulse <= 0;

            // 1. Accept new pipeline request
            if (enable && (decoded_mem_read_enable || decoded_mem_write_enable || decoded_shared_read_enable || decoded_shared_write_enable)) begin
                req_valid[warp_id] <= 1;
                req_addr[warp_id] <= rs[7:0];
                req_data_val[warp_id] <= rt;
                req_rd[warp_id] <= decoded_rd;
                if (decoded_mem_read_enable) req_type[warp_id] <= 3'd0;
                else if (decoded_mem_write_enable) req_type[warp_id] <= 3'd1;
                else if (decoded_shared_read_enable) req_type[warp_id] <= 3'd2;
                else req_type[warp_id] <= 3'd3;
            end

            // 2. Handle active port responses
            if (port_busy) begin
                if (active_type == 3'd0 && mem_read_ready) begin
                    port_busy <= 0; mem_read_valid <= 0;
                    lsu_we <= 1; lsu_warp_id <= active_warp; lsu_rd <= req_rd[active_warp]; lsu_data <= mem_read_data;
                    done_pulse <= 1; done_warp_id <= active_warp; req_valid[active_warp] <= 0;
                    if (DEBUG) $display("[%0t] [LSU Async] Warp %0d Global Read Done! Data=%0d", $time, active_warp, mem_read_data);
                end
                else if (active_type == 3'd1 && mem_write_ready) begin
                    port_busy <= 0; mem_write_valid <= 0;
                    done_pulse <= 1; done_warp_id <= active_warp; req_valid[active_warp] <= 0;
                    if (DEBUG) $display("[%0t] [LSU Async] Warp %0d Global Write Done!", $time, active_warp);
                end
                else if (active_type == 3'd2 && shared_mem_read_ready) begin
                    port_busy <= 0; shared_mem_read_valid <= 0;
                    lsu_we <= 1; lsu_warp_id <= active_warp; lsu_rd <= req_rd[active_warp]; lsu_data <= shared_mem_read_data;
                    done_pulse <= 1; done_warp_id <= active_warp; req_valid[active_warp] <= 0;
                end
                else if (active_type == 3'd3 && shared_mem_write_ready) begin
                    port_busy <= 0; shared_mem_write_valid <= 0;
                    done_pulse <= 1; done_warp_id <= active_warp; req_valid[active_warp] <= 0;
                end
            end
            else begin
                // 3. Issue new request from buffers if port idle
                int selected_w = -1;
                for (int w = 0; w < NUM_WARPS; w++) begin
                    if (selected_w == -1 && req_valid[w]) selected_w = w;
                end

                if (selected_w != -1) begin
                    port_busy <= 1;
                    active_warp <= selected_w;
                    active_type <= req_type[selected_w];
                    if (req_type[selected_w] == 3'd0) begin
                        mem_read_valid <= 1; mem_read_address <= req_addr[selected_w];
                    end else if (req_type[selected_w] == 3'd1) begin
                        mem_write_valid <= 1; mem_write_address <= req_addr[selected_w]; mem_write_data <= req_data_val[selected_w];
                    end else if (req_type[selected_w] == 3'd2) begin
                        shared_mem_read_valid <= 1; shared_mem_read_address <= req_addr[selected_w];
                    end else begin
                        shared_mem_write_valid <= 1; shared_mem_write_address <= req_addr[selected_w]; shared_mem_write_data <= req_data_val[selected_w];
                    end
                end
            end
        end
    end
endmodule