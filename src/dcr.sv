// --- Begin: src/dcr.sv ---
`default_nettype none
`timescale 1ns/1ns

module dcr (
    input wire clk,
    input wire reset,

    input wire device_control_write_enable,
    input wire [7:0] device_control_address, 
    input wire [7:0] device_control_data,
    
    output wire [7:0] thread_count,
    
    // --- PMU Global Controls ---
    output reg pmu_reset,
    output reg pmu_snapshot,
    output reg [4:0] pmu_cfg_0,
    output reg [4:0] pmu_cfg_1,
    output reg [4:0] pmu_cfg_2,
    output reg [4:0] pmu_cfg_3
);
    reg [7:0] device_control_register;
    assign thread_count = device_control_register[7:0];

    always @(posedge clk) begin
        if (reset) begin
            device_control_register <= 8'b0;
            pmu_reset <= 0;
            pmu_snapshot <= 0;
            pmu_cfg_0 <= 5'd0;
            pmu_cfg_1 <= 5'd0;
            pmu_cfg_2 <= 5'd0;
            pmu_cfg_3 <= 5'd0;
        end else begin
            // Pulses default to 0
            pmu_reset <= 0;
            pmu_snapshot <= 0;

            if (device_control_write_enable) begin 
                if (device_control_address == 8'h00) begin
                    device_control_register <= device_control_data;
                end else if (device_control_address == 8'h01) begin
                    pmu_reset <= 1'b1;
                end else if (device_control_address == 8'h02) begin
                    pmu_snapshot <= 1'b1;
                end else if (device_control_address == 8'h10) begin
                    pmu_cfg_0 <= device_control_data[4:0];
                end else if (device_control_address == 8'h11) begin
                    pmu_cfg_1 <= device_control_data[4:0];
                end else if (device_control_address == 8'h12) begin
                    pmu_cfg_2 <= device_control_data[4:0];
                end else if (device_control_address == 8'h13) begin
                    pmu_cfg_3 <= device_control_data[4:0];
                end
            end
        end
    end
endmodule
// --- End: src/dcr.sv ---