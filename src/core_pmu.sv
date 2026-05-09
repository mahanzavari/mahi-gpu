`default_nettype none
`timescale 1ns/1ns

module core_pmu (
    input wire clk,
    input wire reset,

    // 1-Bit Event Bus from Core and Caches
    input wire [31:0] events,

    // DCR Configuration (Memory-Mapped Mux Selectors)
    // Determines which of the 32 events routes to the 4 physical counters
    input wire [4:0] cfg_mux_sel_0,
    input wire [4:0] cfg_mux_sel_1,
    input wire [4:0] cfg_mux_sel_2,
    input wire [4:0] cfg_mux_sel_3,

    // DCR Readout (Memory-Mapped Counter Values)
    output reg [31:0] counter_0,
    output reg [31:0] counter_1,
    output reg [31:0] counter_2,
    output reg [31:0] counter_3
);

    // Future enhancement: DMA Engine to automatically stream snapshots
    // of these counters to Global Memory instead of DCR polling.

    always @(posedge clk) begin
        if (reset) begin
            counter_0 <= 0;
            counter_1 <= 0;
            counter_2 <= 0;
            counter_3 <= 0;
        end else begin
            if (events[cfg_mux_sel_0]) counter_0 <= counter_0 + 1;
            if (events[cfg_mux_sel_1]) counter_1 <= counter_1 + 1;
            if (events[cfg_mux_sel_2]) counter_2 <= counter_2 + 1;
            if (events[cfg_mux_sel_3]) counter_3 <= counter_3 + 1;
        end
    end

endmodule