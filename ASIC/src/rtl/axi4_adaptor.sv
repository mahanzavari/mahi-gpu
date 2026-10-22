`default_nettype none
`timescale 1ns/1ns

module axi4_adapter #(
    parameter ADDR_BITS = 32,
    parameter DATA_BITS = 128,          // Cache block size (128 bits)
    parameter CUSTOM_STROBE_BITS = 4    // 1 bit per 32-bit word
) (
    input wire clk,
    input wire reset,

    // --- Custom Native Interface (From GPU Cache/Controller) ---
    input  wire                   custom_read_valid,
    input  wire [ADDR_BITS-1:0]   custom_read_addr,  // Block address
    output reg                    custom_read_ready,
    output reg  [DATA_BITS-1:0]   custom_read_data,

    input  wire                   custom_write_valid,
    input  wire [ADDR_BITS-1:0]   custom_write_addr, // Block address
    input  wire [DATA_BITS-1:0]   custom_write_data,
    input  wire [CUSTOM_STROBE_BITS-1:0] custom_write_strobe,
    output reg                    custom_write_ready,

    // --- AXI4 Master Interface ---
    // Address Write (AW) Channel
    output reg  [ADDR_BITS-1:0]   m_axi_awaddr,
    output reg                    m_axi_awvalid,
    input  wire                   m_axi_awready,
    output wire [7:0]             m_axi_awlen,
    output wire [2:0]             m_axi_awsize,
    output wire [1:0]             m_axi_awburst,
    
    // Write Data (W) Channel
    output reg  [DATA_BITS-1:0]   m_axi_wdata,
    output reg  [(DATA_BITS/8)-1:0] m_axi_wstrb,
    output reg                    m_axi_wvalid,
    input  wire                   m_axi_wready,
    output wire                   m_axi_wlast,

    // Write Response (B) Channel
    input  wire [1:0]             m_axi_bresp,
    input  wire                   m_axi_bvalid,
    output reg                    m_axi_bready,

    // Address Read (AR) Channel
    output reg  [ADDR_BITS-1:0]   m_axi_araddr,
    output reg                    m_axi_arvalid,
    input  wire                   m_axi_arready,
    output wire [7:0]             m_axi_arlen,
    output wire [2:0]             m_axi_arsize,
    output wire [1:0]             m_axi_arburst,

    // Read Data (R) Channel
    input  wire [DATA_BITS-1:0]   m_axi_rdata,
    input  wire [1:0]             m_axi_rresp,
    input  wire                   m_axi_rlast,
    input  wire                   m_axi_rvalid,
    output reg                    m_axi_rready
);

    // Constant AXI signals for single-beat transactions
    assign m_axi_awlen   = 8'd0; // 1 beat per burst (0 = 1 beat)
    assign m_axi_arlen   = 8'd0;
    assign m_axi_awburst = 2'b01; // INCR burst type
    assign m_axi_arburst = 2'b01;
    assign m_axi_wlast   = 1'b1;  // Always last in a 1-beat burst
    
    // Size indicates bytes per beat. For 128-bit (16 bytes), size is 3'b100 (log2(16))
    localparam BYTES_PER_BEAT = DATA_BITS / 8;
    assign m_axi_awsize = $clog2(BYTES_PER_BEAT);
    assign m_axi_arsize = $clog2(BYTES_PER_BEAT);

    // The GPU memory controller outputs BLOCK addresses. AXI requires BYTE addresses.
    // We must shift the address left by log2(BYTES_PER_BEAT).
    localparam ADDR_SHIFT = $clog2(BYTES_PER_BEAT);

    // --- Read State Machine ---
    typedef enum logic [1:0] {R_IDLE, R_AR_WAIT, R_READ_WAIT} r_state_t;
    r_state_t r_state;

    always_ff @(posedge clk) begin
        if (reset) begin
            r_state <= R_IDLE;
            m_axi_arvalid <= 0;
            m_axi_rready <= 0;
            custom_read_ready <= 0;
            custom_read_data <= 0;
        end else begin
            custom_read_ready <= 0;
            
            case (r_state)
                R_IDLE: begin
                    if (custom_read_valid && !custom_read_ready) begin
                        m_axi_arvalid <= 1'b1;
                        m_axi_araddr  <= custom_read_addr << ADDR_SHIFT;
                        r_state       <= R_AR_WAIT;
                    end
                end
                R_AR_WAIT: begin
                    if (m_axi_arready && m_axi_arvalid) begin
                        m_axi_arvalid <= 1'b0;
                        m_axi_rready  <= 1'b1;
                        r_state       <= R_READ_WAIT;
                    end
                end
                R_READ_WAIT: begin
                    if (m_axi_rvalid && m_axi_rready) begin
                        m_axi_rready      <= 1'b0;
                        custom_read_data  <= m_axi_rdata;
                        custom_read_ready <= 1'b1; // Handshake back to GPU
                        r_state           <= R_IDLE;
                    end
                end
            endcase
        end
    end

    // --- Write State Machine ---
    typedef enum logic [1:0] {W_IDLE, W_ADDR_DATA_WAIT, W_RESP_WAIT} w_state_t;
    w_state_t w_state;

    always_ff @(posedge clk) begin
        if (reset) begin
            w_state <= W_IDLE;
            m_axi_awvalid <= 0;
            m_axi_wvalid <= 0;
            m_axi_bready <= 0;
            custom_write_ready <= 0;
        end else begin
            custom_write_ready <= 0;

            case (w_state)
                W_IDLE: begin
                    if (custom_write_valid && !custom_write_ready) begin
                        m_axi_awvalid <= 1'b1;
                        m_axi_awaddr  <= custom_write_addr << ADDR_SHIFT;
                        
                        m_axi_wvalid  <= 1'b1;
                        m_axi_wdata   <= custom_write_data;

                        // Translate GPU 4-bit word strobe to AXI 16-bit byte strobe
                        // E.g., strobe[0] (32-bit word 0) -> WSTRB[3:0] (bytes 0,1,2,3)
                        m_axi_wstrb   <= { {4{custom_write_strobe[3]}}, 
                                           {4{custom_write_strobe[2]}}, 
                                           {4{custom_write_strobe[1]}}, 
                                           {4{custom_write_strobe[0]}} };

                        w_state <= W_ADDR_DATA_WAIT;
                    end
                end
                W_ADDR_DATA_WAIT: begin
                    // Clear valids as they are accepted by the slave
                    if (m_axi_awready) m_axi_awvalid <= 1'b0;
                    if (m_axi_wready)  m_axi_wvalid  <= 1'b0;

                    // When both address and data have been accepted
                    if ((!m_axi_awvalid || m_axi_awready) && (!m_axi_wvalid || m_axi_wready)) begin
                        m_axi_bready <= 1'b1;
                        w_state      <= W_RESP_WAIT;
                    end
                end
                W_RESP_WAIT: begin
                    if (m_axi_bvalid && m_axi_bready) begin
                        m_axi_bready       <= 1'b0;
                        custom_write_ready <= 1'b1; // Handshake back to GPU
                        w_state            <= W_IDLE;
                    end
                end
            endcase
        end
    end
endmodule