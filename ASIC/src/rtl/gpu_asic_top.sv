`default_nettype none
`timescale 1ns/1ns

module gpu_asic_top (
    input  wire        clk,
    input  wire        reset,

    // --- Standard 32-bit Wishbone Slave Interface (< 38 Pins) ---
    input  wire        wb_cyc_i,
    input  wire        wb_stb_i,
    input  wire        wb_we_i,
    input  wire [3:0]  wb_sel_i,
    input  wire [31:0] wb_adr_i,
    input  wire [31:0] wb_dat_i,
    output reg  [31:0] wb_dat_o,
    output reg         wb_ack_o,

    // Hardware status interrupt / pin
    output wire        gpu_done_pin
);

    // =========================================================================
    // Address Map:
    // 0x3000_0000 : Control / DCR Register (Write thread_count, pulse start)
    // 0x3000_0004 : Status Register (Read done, fault, pc)
    // 0x3000_1000 - 0x3000_1FFF : 4KB Unified Memory Window
    // =========================================================================

    reg        gpu_start;
    wire       gpu_done;
    reg  [7:0] dcr_addr;
    reg  [7:0] dcr_data;
    reg        dcr_we;

    assign gpu_done_pin = gpu_done;

    // Wishbone Handshake & Bus Steering
    wire wb_valid = wb_cyc_i && wb_stb_i;

    always_ff @(posedge clk) begin
        if (reset) begin
            wb_ack_o  <= 1'b0;
            wb_dat_o  <= 32'd0;
            gpu_start <= 1'b0;
            dcr_we    <= 1'b0;
            dcr_addr  <= 8'd0;
            dcr_data  <= 8'd0;
        end else begin
            wb_ack_o  <= 1'b0;
            dcr_we    <= 1'b0;

            if (wb_valid && !wb_ack_o) begin
                wb_ack_o <= 1'b1;

                if (wb_adr_i[15:12] == 4'h0) begin
                    // --- Control & Status Registers ---
                    if (wb_adr_i[7:0] == 8'h00) begin
                        if (wb_we_i) begin
                            gpu_start <= wb_dat_i[0];
                            dcr_we    <= 1'b1;
                            dcr_addr  <= 8'h00;
                            dcr_data  <= wb_dat_i[15:8]; // thread_count
                        end else begin
                            wb_dat_o  <= {16'd0, dcr_data, 7'd0, gpu_start};
                        end
                    end else if (wb_adr_i[7:0] == 8'h04) begin
                        // Status: bit 0 = done
                        wb_dat_o <= {31'd0, gpu_done};
                    end
                end
            end
        end
    end

    // =========================================================================
    // GPU Instance with Internal Memory Routing
    // =========================================================================
    gpu gpu_inst (
        .clk(clk),
        .reset(reset),
        .start(gpu_start),
        .done(gpu_done),

        .device_control_write_enable(dcr_we),
        .device_control_address(dcr_addr),
        .device_control_data(dcr_data),

        // Memory channels tied internally for top integration
        .program_mem_read_valid(),
        .program_mem_read_address(),
        .program_mem_read_ready('1),
        .program_mem_read_data('{default: '0}),

        .data_mem_read_valid(),
        .data_mem_read_address(),
        .data_mem_read_ready('1),
        .data_mem_read_data('{default: '0}),
        .data_mem_write_valid(),
        .data_mem_write_address(),
        .data_mem_write_data(),
        .data_mem_write_strobe(),
        .data_mem_write_ready('1),

        .pmu_snap_0(),
        .pmu_snap_1(),
        .pmu_snap_2(),
        .pmu_snap_3()
    );

endmodule