/*

Copyright (c) 2018 Alex Forencich
(Modified for Realistic DDR Latency Behavioral Modeling & Enhanced Logging)

*/

// Language: Verilog 2001

`resetall
`timescale 1ns / 1ps
`default_nettype none

/*
 * AXI4 RAM (With Realistic DDR Latency Simulation)
 */
module axi_ram #
(
    // Width of data bus in bits
    parameter DATA_WIDTH = 32,
    // Width of address bus in bits
    parameter ADDR_WIDTH = 32,
    // Width of wstrb (width of data bus in words)
    parameter STRB_WIDTH = (DATA_WIDTH/8),
    // Width of ID signal
    parameter ID_WIDTH = 8,
    // Extra pipeline register on output
    parameter PIPELINE_OUTPUT = 0,

    // --- DDR Latency Simulation Parameters ---
    parameter DDR_tCAS      = 15, // Latency for Page Hit (Cycles)
    parameter DDR_tRCD      = 15, // Row to Column Delay (Cycles)
    parameter DDR_tRP       = 15, // Row Precharge Delay (Cycles)
    parameter DDR_BANK_BITS = 2,  // Number of Bank Bits (2 bits = 4 Banks)
    parameter DDR_COL_BITS  = 10  // Number of Column Bits (10 bits = 1KB Pages)
)
(
    input  wire                   clk,
    input  wire                   rst,

    input  wire [ID_WIDTH-1:0]    s_axi_awid,
    input  wire [ADDR_WIDTH-1:0]  s_axi_awaddr,
    input  wire [7:0]             s_axi_awlen,
    input  wire [2:0]             s_axi_awsize,
    input  wire [1:0]             s_axi_awburst,
    input  wire                   s_axi_awlock,
    input  wire [3:0]             s_axi_awcache,
    input  wire [2:0]             s_axi_awprot,
    input  wire                   s_axi_awvalid,
    output wire                   s_axi_awready,
    input  wire [DATA_WIDTH-1:0]  s_axi_wdata,
    input  wire [STRB_WIDTH-1:0]  s_axi_wstrb,
    input  wire                   s_axi_wlast,
    input  wire                   s_axi_wvalid,
    output wire                   s_axi_wready,
    output wire [ID_WIDTH-1:0]    s_axi_bid,
    output wire [1:0]             s_axi_bresp,
    output wire                   s_axi_bvalid,
    input  wire                   s_axi_bready,
    input  wire [ID_WIDTH-1:0]    s_axi_arid,
    input  wire [ADDR_WIDTH-1:0]  s_axi_araddr,
    input  wire [7:0]             s_axi_arlen,
    input  wire [2:0]             s_axi_arsize,
    input  wire [1:0]             s_axi_arburst,
    input  wire                   s_axi_arlock,
    input  wire [3:0]             s_axi_arcache,
    input  wire [2:0]             s_axi_arprot,
    input  wire                   s_axi_arvalid,
    output wire                   s_axi_arready,
    output wire [ID_WIDTH-1:0]    s_axi_rid,
    output wire [DATA_WIDTH-1:0]  s_axi_rdata,
    output wire [1:0]             s_axi_rresp,
    output wire                   s_axi_rlast,
    output wire                   s_axi_rvalid,
    input  wire                   s_axi_rready
);

parameter VALID_ADDR_WIDTH = ADDR_WIDTH - $clog2(STRB_WIDTH);
parameter WORD_WIDTH = STRB_WIDTH;
parameter WORD_SIZE = DATA_WIDTH/WORD_WIDTH;

// bus width assertions
initial begin
    if (WORD_SIZE * STRB_WIDTH != DATA_WIDTH) begin
        $error("Error: AXI data width not evenly divisble (instance %m)");
        $finish;
    end

    if (2**$clog2(WORD_WIDTH) != WORD_WIDTH) begin
        $error("Error: AXI word width must be even power of two (instance %m)");
        $finish;
    end
end

// --- DDR Behavioral State Tracking ---
localparam NUM_BANKS = 2**DDR_BANK_BITS;
localparam ROW_BITS = (ADDR_WIDTH > (DDR_BANK_BITS + DDR_COL_BITS)) ? 
                      (ADDR_WIDTH - DDR_BANK_BITS - DDR_COL_BITS) : 1;

reg [ROW_BITS-1:0] open_row_read [0:NUM_BANKS-1];
reg [ROW_BITS-1:0] open_row_write [0:NUM_BANKS-1];

reg [7:0] read_delay_reg = 8'd0, read_delay_next;
reg [7:0] write_delay_reg = 8'd0, write_delay_next;

wire [DDR_BANK_BITS-1:0] r_bank = s_axi_araddr[DDR_COL_BITS +: DDR_BANK_BITS];
wire [ROW_BITS-1:0]      r_row  = s_axi_araddr[(DDR_COL_BITS+DDR_BANK_BITS) +: ROW_BITS];

wire [DDR_BANK_BITS-1:0] w_bank = s_axi_awaddr[DDR_COL_BITS +: DDR_BANK_BITS];
wire [ROW_BITS-1:0]      w_row  = s_axi_awaddr[(DDR_COL_BITS+DDR_BANK_BITS) +: ROW_BITS];

// --- Modified State Machines ---
localparam [1:0]
    READ_STATE_IDLE  = 2'd0,
    READ_STATE_WAIT  = 2'd1, // Added Latency State
    READ_STATE_BURST = 2'd2;

reg [1:0] read_state_reg = READ_STATE_IDLE, read_state_next;

localparam [2:0]
    WRITE_STATE_IDLE  = 3'd0,
    WRITE_STATE_WAIT  = 3'd1, // Added Latency State
    WRITE_STATE_BURST = 3'd2,
    WRITE_STATE_RESP  = 3'd3;

reg [2:0] write_state_reg = WRITE_STATE_IDLE, write_state_next;

reg mem_wr_en;
reg mem_rd_en;

reg [ID_WIDTH-1:0] read_id_reg = {ID_WIDTH{1'b0}}, read_id_next;
reg [ADDR_WIDTH-1:0] read_addr_reg = {ADDR_WIDTH{1'b0}}, read_addr_next;
reg [7:0] read_count_reg = 8'd0, read_count_next;
reg [2:0] read_size_reg = 3'd0, read_size_next;
reg [1:0] read_burst_reg = 2'd0, read_burst_next;
reg [ID_WIDTH-1:0] write_id_reg = {ID_WIDTH{1'b0}}, write_id_next;
reg [ADDR_WIDTH-1:0] write_addr_reg = {ADDR_WIDTH{1'b0}}, write_addr_next;
reg [7:0] write_count_reg = 8'd0, write_count_next;
reg [2:0] write_size_reg = 3'd0, write_size_next;
reg [1:0] write_burst_reg = 2'd0, write_burst_next;

reg s_axi_awready_reg = 1'b0, s_axi_awready_next;
reg s_axi_wready_reg = 1'b0, s_axi_wready_next;
reg [ID_WIDTH-1:0] s_axi_bid_reg = {ID_WIDTH{1'b0}}, s_axi_bid_next;
reg s_axi_bvalid_reg = 1'b0, s_axi_bvalid_next;
reg s_axi_arready_reg = 1'b0, s_axi_arready_next;
reg [ID_WIDTH-1:0] s_axi_rid_reg = {ID_WIDTH{1'b0}}, s_axi_rid_next;
reg [DATA_WIDTH-1:0] s_axi_rdata_reg = {DATA_WIDTH{1'b0}}, s_axi_rdata_next;
reg s_axi_rlast_reg = 1'b0, s_axi_rlast_next;
reg s_axi_rvalid_reg = 1'b0, s_axi_rvalid_next;
reg [ID_WIDTH-1:0] s_axi_rid_pipe_reg = {ID_WIDTH{1'b0}};
reg [DATA_WIDTH-1:0] s_axi_rdata_pipe_reg = {DATA_WIDTH{1'b0}};
reg s_axi_rlast_pipe_reg = 1'b0;
reg s_axi_rvalid_pipe_reg = 1'b0;

// (* RAM_STYLE="BLOCK" *)
reg [DATA_WIDTH-1:0] mem[(2**VALID_ADDR_WIDTH)-1:0];

wire [VALID_ADDR_WIDTH-1:0] s_axi_awaddr_valid = s_axi_awaddr >> (ADDR_WIDTH - VALID_ADDR_WIDTH);
wire [VALID_ADDR_WIDTH-1:0] s_axi_araddr_valid = s_axi_araddr >> (ADDR_WIDTH - VALID_ADDR_WIDTH);
wire [VALID_ADDR_WIDTH-1:0] read_addr_valid = read_addr_reg >> (ADDR_WIDTH - VALID_ADDR_WIDTH);
wire [VALID_ADDR_WIDTH-1:0] write_addr_valid = write_addr_reg >> (ADDR_WIDTH - VALID_ADDR_WIDTH);

assign s_axi_awready = s_axi_awready_reg;
assign s_axi_wready = s_axi_wready_reg;
assign s_axi_bid = s_axi_bid_reg;
assign s_axi_bresp = 2'b00;
assign s_axi_bvalid = s_axi_bvalid_reg;
assign s_axi_arready = s_axi_arready_reg;
assign s_axi_rid = PIPELINE_OUTPUT ? s_axi_rid_pipe_reg : s_axi_rid_reg;
assign s_axi_rdata = PIPELINE_OUTPUT ? s_axi_rdata_pipe_reg : s_axi_rdata_reg;
assign s_axi_rresp = 2'b00;
assign s_axi_rlast = PIPELINE_OUTPUT ? s_axi_rlast_pipe_reg : s_axi_rlast_reg;
assign s_axi_rvalid = PIPELINE_OUTPUT ? s_axi_rvalid_pipe_reg : s_axi_rvalid_reg;

integer i, j, b;

initial begin
    // Initialize DDR Open Rows to an invalid state
    for (b = 0; b < NUM_BANKS; b = b + 1) begin
        open_row_read[b] = {ROW_BITS{1'b1}};
        open_row_write[b] = {ROW_BITS{1'b1}};
    end

    // Init memory
    for (i = 0; i < 2**VALID_ADDR_WIDTH; i = i + 2**(VALID_ADDR_WIDTH/2)) begin
        for (j = i; j < i + 2**(VALID_ADDR_WIDTH/2); j = j + 1) begin
            mem[j] = 0;
        end
    end
end

// --- WRITE LOGIC ---
always @* begin
    write_state_next = WRITE_STATE_IDLE;
    write_delay_next = write_delay_reg;

    mem_wr_en = 1'b0;

    write_id_next = write_id_reg;
    write_addr_next = write_addr_reg;
    write_count_next = write_count_reg;
    write_size_next = write_size_reg;
    write_burst_next = write_burst_reg;

    s_axi_awready_next = 1'b0;
    s_axi_wready_next = 1'b0;
    s_axi_bid_next = s_axi_bid_reg;
    s_axi_bvalid_next = s_axi_bvalid_reg && !s_axi_bready;

    case (write_state_reg)
        WRITE_STATE_IDLE: begin
            s_axi_awready_next = 1'b1;

            if (s_axi_awready && s_axi_awvalid) begin
                write_id_next = s_axi_awid;
                write_addr_next = s_axi_awaddr;
                write_count_next = s_axi_awlen;
                write_size_next = s_axi_awsize < $clog2(STRB_WIDTH) ? s_axi_awsize : $clog2(STRB_WIDTH);
                write_burst_next = s_axi_awburst;
                
                // Smart AXI Delay Calculation
                if (open_row_write[w_bank] == w_row) begin
                    write_delay_next = DDR_tCAS; // Page Hit
                end else begin
                    write_delay_next = DDR_tCAS + DDR_tRCD + DDR_tRP; // Page Miss
                end

                s_axi_awready_next = 1'b0;
                write_state_next = WRITE_STATE_WAIT;
            end else begin
                write_state_next = WRITE_STATE_IDLE;
            end
        end
        WRITE_STATE_WAIT: begin
            if (write_delay_reg > 0) begin
                write_delay_next = write_delay_reg - 1;
                write_state_next = WRITE_STATE_WAIT;
            end else begin
                s_axi_wready_next = 1'b1;
                write_state_next = WRITE_STATE_BURST;
            end
        end
        WRITE_STATE_BURST: begin
            s_axi_wready_next = 1'b1;

            if (s_axi_wready && s_axi_wvalid) begin
                mem_wr_en = 1'b1;
                if (write_burst_reg != 2'b00) begin
                    write_addr_next = write_addr_reg + (1 << write_size_reg);
                end
                write_count_next = write_count_reg - 1;
                if (write_count_reg > 0) begin
                    write_state_next = WRITE_STATE_BURST;
                end else begin
                    s_axi_wready_next = 1'b0;
                    if (s_axi_bready || !s_axi_bvalid) begin
                        s_axi_bid_next = write_id_reg;
                        s_axi_bvalid_next = 1'b1;
                        s_axi_awready_next = 1'b1;
                        write_state_next = WRITE_STATE_IDLE;
                    end else begin
                        write_state_next = WRITE_STATE_RESP;
                    end
                end
            end else begin
                write_state_next = WRITE_STATE_BURST;
            end
        end
        WRITE_STATE_RESP: begin
            if (s_axi_bready || !s_axi_bvalid) begin
                s_axi_bid_next = write_id_reg;
                s_axi_bvalid_next = 1'b1;
                s_axi_awready_next = 1'b1;
                write_state_next = WRITE_STATE_IDLE;
            end else begin
                write_state_next = WRITE_STATE_RESP;
            end
        end
    endcase
end

always @(posedge clk) begin
    write_state_reg <= write_state_next;
    write_delay_reg <= write_delay_next;

    write_id_reg <= write_id_next;
    write_addr_reg <= write_addr_next;
    write_count_reg <= write_count_next;
    write_size_reg <= write_size_next;
    write_burst_reg <= write_burst_next;

    s_axi_awready_reg <= s_axi_awready_next;
    s_axi_wready_reg <= s_axi_wready_next;
    s_axi_bid_reg <= s_axi_bid_next;
    s_axi_bvalid_reg <= s_axi_bvalid_next;

    // --- WRITE LOGGING: HIT/MISS ---
    if (s_axi_awready && s_axi_awvalid) begin
        open_row_write[w_bank] <= w_row;
        if (open_row_write[w_bank] == w_row) begin
            $display("[%0t] [DDR-RAM] WRITE PAGE HIT  | Addr: %0h | Bank: %0d, Row: %0h | Burst: %0d | Delay: %0d cycles", 
                     $time, s_axi_awaddr, w_bank, w_row, s_axi_awlen + 1, DDR_tCAS);
        end else begin
            $display("[%0t] [DDR-RAM] WRITE PAGE MISS | Addr: %0h | Bank: %0d, Row: %0h | Burst: %0d | Delay: %0d cycles", 
                     $time, s_axi_awaddr, w_bank, w_row, s_axi_awlen + 1, DDR_tCAS + DDR_tRCD + DDR_tRP);
        end
    end

    // --- WRITE LOGGING: BURST COMPLETION ---
    if (write_state_reg == WRITE_STATE_BURST && (write_state_next == WRITE_STATE_RESP || write_state_next == WRITE_STATE_IDLE)) begin
        $display("[%0t] [DDR-RAM] WRITE BURST DONE  | ID: %0h", $time, write_id_reg);
    end

    for (i = 0; i < WORD_WIDTH; i = i + 1) begin
        if (mem_wr_en & s_axi_wstrb[i]) begin
            mem[write_addr_valid][WORD_SIZE*i +: WORD_SIZE] <= s_axi_wdata[WORD_SIZE*i +: WORD_SIZE];
        end
    end

    if (rst) begin
        write_state_reg <= WRITE_STATE_IDLE;
        s_axi_awready_reg <= 1'b0;
        s_axi_wready_reg <= 1'b0;
        s_axi_bvalid_reg <= 1'b0;
    end
end

// --- READ LOGIC ---
always @* begin
    read_state_next = READ_STATE_IDLE;
    read_delay_next = read_delay_reg;

    mem_rd_en = 1'b0;

    s_axi_rid_next = s_axi_rid_reg;
    s_axi_rlast_next = s_axi_rlast_reg;
    s_axi_rvalid_next = s_axi_rvalid_reg && !(s_axi_rready || (PIPELINE_OUTPUT && !s_axi_rvalid_pipe_reg));

    read_id_next = read_id_reg;
    read_addr_next = read_addr_reg;
    read_count_next = read_count_reg;
    read_size_next = read_size_reg;
    read_burst_next = read_burst_reg;

    s_axi_arready_next = 1'b0;

    case (read_state_reg)
        READ_STATE_IDLE: begin
            s_axi_arready_next = 1'b1;

            if (s_axi_arready && s_axi_arvalid) begin
                read_id_next = s_axi_arid;
                read_addr_next = s_axi_araddr;
                read_count_next = s_axi_arlen;
                read_size_next = s_axi_arsize < $clog2(STRB_WIDTH) ? s_axi_arsize : $clog2(STRB_WIDTH);
                read_burst_next = s_axi_arburst;

                // Smart AXI Delay Calculation
                if (open_row_read[r_bank] == r_row) begin
                    read_delay_next = DDR_tCAS; // Page Hit
                end else begin
                    read_delay_next = DDR_tCAS + DDR_tRCD + DDR_tRP; // Page Miss
                end

                s_axi_arready_next = 1'b0;
                read_state_next = READ_STATE_WAIT;
            end else begin
                read_state_next = READ_STATE_IDLE;
            end
        end
        READ_STATE_WAIT: begin
            if (read_delay_reg > 0) begin
                read_delay_next = read_delay_reg - 1;
                read_state_next = READ_STATE_WAIT;
            end else begin
                read_state_next = READ_STATE_BURST;
            end
        end
        READ_STATE_BURST: begin
            if (s_axi_rready || (PIPELINE_OUTPUT && !s_axi_rvalid_pipe_reg) || !s_axi_rvalid_reg) begin
                mem_rd_en = 1'b1;
                s_axi_rvalid_next = 1'b1;
                s_axi_rid_next = read_id_reg;
                s_axi_rlast_next = read_count_reg == 0;
                if (read_burst_reg != 2'b00) begin
                    read_addr_next = read_addr_reg + (1 << read_size_reg);
                end
                read_count_next = read_count_reg - 1;
                if (read_count_reg > 0) begin
                    read_state_next = READ_STATE_BURST;
                end else begin
                    s_axi_arready_next = 1'b1;
                    read_state_next = READ_STATE_IDLE;
                end
            end else begin
                read_state_next = READ_STATE_BURST;
            end
        end
    endcase
end

always @(posedge clk) begin
    read_state_reg <= read_state_next;
    read_delay_reg <= read_delay_next;

    read_id_reg <= read_id_next;
    read_addr_reg <= read_addr_next;
    read_count_reg <= read_count_next;
    read_size_reg <= read_size_next;
    read_burst_reg <= read_burst_next;

    s_axi_arready_reg <= s_axi_arready_next;
    s_axi_rid_reg <= s_axi_rid_next;
    s_axi_rlast_reg <= s_axi_rlast_next;
    s_axi_rvalid_reg <= s_axi_rvalid_next;

    // --- READ LOGGING: HIT/MISS ---
    if (s_axi_arready && s_axi_arvalid) begin
        open_row_read[r_bank] <= r_row;
        if (open_row_read[r_bank] == r_row) begin
            $display("[%0t] [DDR-RAM] READ PAGE HIT   | Addr: %0h | Bank: %0d, Row: %0h | Burst: %0d | Delay: %0d cycles", 
                     $time, s_axi_araddr, r_bank, r_row, s_axi_arlen + 1, DDR_tCAS);
        end else begin
            $display("[%0t] [DDR-RAM] READ PAGE MISS  | Addr: %0h | Bank: %0d, Row: %0h | Burst: %0d | Delay: %0d cycles", 
                     $time, s_axi_araddr, r_bank, r_row, s_axi_arlen + 1, DDR_tCAS + DDR_tRCD + DDR_tRP);
        end
    end

    // --- READ LOGGING: BURST COMPLETION ---
    if (read_state_reg == READ_STATE_BURST && read_state_next == READ_STATE_IDLE) begin
        $display("[%0t] [DDR-RAM] READ BURST DONE   | ID: %0h", $time, read_id_reg);
    end

    if (mem_rd_en) begin
        s_axi_rdata_reg <= mem[read_addr_valid];
    end

    if (!s_axi_rvalid_pipe_reg || s_axi_rready) begin
        s_axi_rid_pipe_reg <= s_axi_rid_reg;
        s_axi_rdata_pipe_reg <= s_axi_rdata_reg;
        s_axi_rlast_pipe_reg <= s_axi_rlast_reg;
        s_axi_rvalid_pipe_reg <= s_axi_rvalid_reg;
    end

    if (rst) begin
        read_state_reg <= READ_STATE_IDLE;
        s_axi_arready_reg <= 1'b0;
        s_axi_rvalid_reg <= 1'b0;
        s_axi_rvalid_pipe_reg <= 1'b0;
    end
end

endmodule