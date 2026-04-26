`default_nettype none
`timescale 1ns/1ns

module controller #(
    parameter ADDR_BITS = 8,
    parameter DATA_BITS = 16,
    parameter NUM_CONSUMERS = 4,
    parameter NUM_CHANNELS = 1,
    parameter WRITE_ENABLE = 1
) (
    input wire clk,
    input wire reset,
    
    input wire [NUM_CONSUMERS-1:0] consumer_read_valid,
    input wire [ADDR_BITS-1:0] consumer_read_address [NUM_CONSUMERS],
    output logic [NUM_CONSUMERS-1:0] consumer_read_ready,
    output logic [DATA_BITS-1:0] consumer_read_data [NUM_CONSUMERS],
    
    input wire [NUM_CONSUMERS-1:0] consumer_write_valid,
    input wire [ADDR_BITS-1:0] consumer_write_address [NUM_CONSUMERS],
    input wire [DATA_BITS-1:0] consumer_write_data [NUM_CONSUMERS],
    output logic [NUM_CONSUMERS-1:0] consumer_write_ready,
    
    output logic [NUM_CHANNELS-1:0] mem_read_valid,
    output logic [ADDR_BITS-1:0] mem_read_address [NUM_CHANNELS],
    input wire [NUM_CHANNELS-1:0] mem_read_ready,
    input wire [DATA_BITS-1:0] mem_read_data [NUM_CHANNELS],
    
    output logic [NUM_CHANNELS-1:0] mem_write_valid,
    output logic [ADDR_BITS-1:0] mem_write_address [NUM_CHANNELS],
    output logic [DATA_BITS-1:0] mem_write_data [NUM_CHANNELS],
    input wire [NUM_CHANNELS-1:0] mem_write_ready
);

    localparam IDLE = 3'b000, 
               READ_WAITING = 3'b010, 
               WRITE_WAITING = 3'b011,
               READ_RELAYING = 3'b100,
               WRITE_RELAYING = 3'b101;

    logic [2:0] controller_state [NUM_CHANNELS];
    logic [$clog2(NUM_CONSUMERS)-1:0] current_consumer [NUM_CHANNELS]; 
    logic [NUM_CONSUMERS-1:0] channel_serving_consumer; 
    
    // --- Round‑robin pointer per channel ---
    logic [$clog2(NUM_CONSUMERS)-1:0] rr_ptr [NUM_CHANNELS];
    
    // Temporary signals for arbitration
    logic [NUM_CONSUMERS-1:0] next_channel_serving;
    logic consumer_claimed;

    integer i, j, k;

    always @(posedge clk) begin
        if (reset) begin 
            mem_read_valid <= 0;
            mem_write_valid <= 0;
            consumer_read_ready <= 0;
            consumer_write_ready <= 0;
            channel_serving_consumer <= 0;

            for (i = 0; i < NUM_CHANNELS; i = i + 1) begin
                mem_read_address[i] <= 0;
                mem_write_address[i] <= 0;
                mem_write_data[i] <= 0;
                current_consumer[i] <= 0;
                controller_state[i] <= IDLE;
                rr_ptr[i] <= 0;   // initialise round-robin pointers
            end

            for (i = 0; i < NUM_CONSUMERS; i = i + 1) begin
                consumer_read_data[i] <= 0;
            end
            
        end else begin 
            next_channel_serving = channel_serving_consumer;

            for (i = 0; i < NUM_CHANNELS; i = i + 1) begin 
                case (controller_state[i])
                    IDLE: begin
                        consumer_claimed = 1'b0;
                        // Round‑robin scan: start at rr_ptr[i] and check NUM_CONSUMERS slots
                        for (k = 0; k < NUM_CONSUMERS; k = k + 1) begin
                            j = (rr_ptr[i] + k) % NUM_CONSUMERS;
                            if (!consumer_claimed) begin
                                if (consumer_read_valid[j] && !next_channel_serving[j]) begin 
                                    next_channel_serving[j] = 1'b1;
                                    consumer_claimed = 1'b1;
                                    current_consumer[i] <= j;

                                    mem_read_valid[i] <= 1;
                                    mem_read_address[i] <= consumer_read_address[j];
                                    controller_state[i] <= READ_WAITING;
                                    
                                    $display("[%0t] CONTROLLER (%m): Ch %0d accepted READ from Consumer %0d, Addr=%0d", $time, i, j, consumer_read_address[j]);
                                    
                                end else if (WRITE_ENABLE && consumer_write_valid[j] && !next_channel_serving[j]) begin 
                                    next_channel_serving[j] = 1'b1;
                                    consumer_claimed = 1'b1;
                                    current_consumer[i] <= j;

                                    mem_write_valid[i] <= 1;
                                    mem_write_address[i] <= consumer_write_address[j];
                                    mem_write_data[i] <= consumer_write_data[j];
                                    controller_state[i] <= WRITE_WAITING;
                                    
                                    $display("[%0t] CONTROLLER (%m): Ch %0d accepted WRITE from Consumer %0d, Addr=%0d, Data=%0d", $time, i, j, consumer_write_address[j], consumer_write_data[j]);
                                end
                            end
                        end
                    end
                    READ_WAITING: begin
                        if (mem_read_ready[i]) begin 
                            mem_read_valid[i] <= 0;
                            consumer_read_data[current_consumer[i]] <= mem_read_data[i];
                            consumer_read_ready[current_consumer[i]] <= 1;
                            controller_state[i] <= READ_RELAYING;
                            
                            $display("[%0t] CONTROLLER (%m): Ch %0d READ ready from mem. Relaying Data=%0d to Consumer %0d", $time, i, mem_read_data[i], current_consumer[i]);
                        end
                    end
                    WRITE_WAITING: begin 
                        if (mem_write_ready[i]) begin 
                            mem_write_valid[i] <= 0;
                            consumer_write_ready[current_consumer[i]] <= 1;
                            controller_state[i] <= WRITE_RELAYING;
                            
                            $display("[%0t] CONTROLLER (%m): Ch %0d WRITE acknowledged by mem. Notifying Consumer %0d", $time, i, current_consumer[i]);
                        end
                    end
                    READ_RELAYING: begin
                        if (!consumer_read_valid[current_consumer[i]]) begin 
                            next_channel_serving[current_consumer[i]] = 1'b0;
                            consumer_read_ready[current_consumer[i]] <= 0;
                            // Advance round-robin pointer after service completes
                            rr_ptr[i] <= (current_consumer[i] + 1) % NUM_CONSUMERS;
                            controller_state[i] <= IDLE;
                            $display("[%0t] CONTROLLER (%m): Ch %0d READ complete for Consumer %0d. Returning to IDLE.", $time, i, current_consumer[i]);
                        end
                    end
                    WRITE_RELAYING: begin 
                        if (!consumer_write_valid[current_consumer[i]]) begin 
                            next_channel_serving[current_consumer[i]] = 1'b0;
                            consumer_write_ready[current_consumer[i]] <= 0;
                            // Advance round-robin pointer after write completes
                            rr_ptr[i] <= (current_consumer[i] + 1) % NUM_CONSUMERS;
                            controller_state[i] <= IDLE;
                            $display("[%0t] CONTROLLER (%m): Ch %0d WRITE complete for Consumer %0d. Returning to IDLE.", $time, i, current_consumer[i]);
                        end
                    end
                endcase
            end
            
            // Single non-blocking update at the end of the evaluation cycle
            channel_serving_consumer <= next_channel_serving;
        end
    end
endmodule