`default_nettype none
`timescale 1ns/1ns

module core_pmu (
    input wire clk,
    input wire reset,

    input wire [31:0] events,

    input wire [4:0] cfg_mux_sel_0,
    input wire [4:0] cfg_mux_sel_1,
    input wire [4:0] cfg_mux_sel_2,
    input wire [4:0] cfg_mux_sel_3,

    output reg [31:0] counter_0,
    output reg [31:0] counter_1,
    output reg [31:0] counter_2,
    output reg [31:0] counter_3,

    // --- PMU Software Control ---
    input wire pmu_reset,     // Clears counters to 0
    input wire pmu_snapshot,  // Latches counters into shadow registers
    output reg [31:0] snapshot_0,
    output reg [31:0] snapshot_1,
    output reg [31:0] snapshot_2,
    output reg [31:0] snapshot_3
);

    always @(posedge clk) begin
        if (reset || pmu_reset) begin
            counter_0 <= 0; counter_1 <= 0;
            counter_2 <= 0; counter_3 <= 0;
        end else begin
            if (events[cfg_mux_sel_0]) counter_0 <= counter_0 + 1;
            if (events[cfg_mux_sel_1]) counter_1 <= counter_1 + 1;
            if (events[cfg_mux_sel_2]) counter_2 <= counter_2 + 1;
            if (events[cfg_mux_sel_3]) counter_3 <= counter_3 + 1;
        end

        if (reset) begin
            snapshot_0 <= 0; snapshot_1 <= 0;
            snapshot_2 <= 0; snapshot_3 <= 0;
        end else if (pmu_snapshot) begin
            snapshot_0 <= counter_0; snapshot_1 <= counter_1;
            snapshot_2 <= counter_2; snapshot_3 <= counter_3;
        end
    end

endmodule