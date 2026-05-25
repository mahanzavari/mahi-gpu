`default_nettype none
`timescale 1ns/1ns

module controller #(
    parameter ADDR_BITS = 8,
    parameter DATA_BITS = 16,
    parameter BLOCK_DATA_BITS = 64,
    parameter NUM_CONSUMERS = 4,
    parameter NUM_CHANNELS = 1,
    parameter WRITE_ENABLE = 1
) (
    input wire clk,
    input wire reset,
    
    input wire [NUM_CONSUMERS-1:0] consumer_read_valid,
    input wire [ADDR_BITS-1:0] consumer_read_address [NUM_CONSUMERS],
    output logic [NUM_CONSUMERS-1:0] consumer_read_ready,
    output logic [BLOCK_DATA_BITS-1:0] consumer_read_data [NUM_CONSUMERS],
    
    input wire [NUM_CONSUMERS-1:0] consumer_write_valid,
    input wire [ADDR_BITS-1:0] consumer_write_address [NUM_CONSUMERS],
    input wire [BLOCK_DATA_BITS-1:0] consumer_write_data [NUM_CONSUMERS],
    input wire [3:0] consumer_write_strobe [NUM_CONSUMERS],
    output logic [NUM_CONSUMERS-1:0] consumer_write_ready,
    
    output logic [NUM_CHANNELS-1:0] mem_read_valid,
    output logic [ADDR_BITS-1:0] mem_read_address [NUM_CHANNELS],
    input wire [NUM_CHANNELS-1:0] mem_read_ready,
    input wire [BLOCK_DATA_BITS-1:0] mem_read_data [NUM_CHANNELS],
    
    output logic [NUM_CHANNELS-1:0] mem_write_valid,
    output logic [ADDR_BITS-1:0] mem_write_address [NUM_CHANNELS],
    output logic [BLOCK_DATA_BITS-1:0] mem_write_data [NUM_CHANNELS],
    output logic [3:0] mem_write_strobe [NUM_CHANNELS],
    input wire [NUM_CHANNELS-1:0] mem_write_ready
);

    localparam IDLE = 3'b000, 
               READ_WAITING = 3'b010, 
               WRITE_WAITING = 3'b011,
               READ_RELAYING = 3'b100,
               WRITE_RELAYING = 3'b101;

    //  Ensure width is at least 1-bit when NUM_CONSUMERS is 1 to avoid [-1:0]
    localparam PTR_WIDTH = (NUM_CONSUMERS > 1) ? $clog2(NUM_CONSUMERS) : 1;

    logic [2:0] controller_state [NUM_CHANNELS];
    logic [PTR_WIDTH-1:0] current_consumer [NUM_CHANNELS]; 
    logic [NUM_CONSUMERS-1:0] channel_serving_consumer; 
    
    logic [PTR_WIDTH-1:0] rr_ptr [NUM_CHANNELS];
    
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
                rr_ptr[i] <= 0;  
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
                                    
                                end else if (WRITE_ENABLE && consumer_write_valid[j] && !next_channel_serving[j]) begin 
                                    next_channel_serving[j] = 1'b1;
                                    consumer_claimed = 1'b1;
                                    current_consumer[i] <= j;

                                    mem_write_valid[i] <= 1;
                                    mem_write_address[i] <= consumer_write_address[j];
                                    mem_write_data[i] <= consumer_write_data[j];
                                    mem_write_strobe[i] <= consumer_write_strobe[j];
                                    controller_state[i] <= WRITE_WAITING;
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
                        end
                    end
                    WRITE_WAITING: begin 
                        if (mem_write_ready[i]) begin 
                            mem_write_valid[i] <= 0;
                            consumer_write_ready[current_consumer[i]] <= 1;
                            controller_state[i] <= WRITE_RELAYING;
                        end
                    end
                    READ_RELAYING: begin
                        if (!consumer_read_valid[current_consumer[i]]) begin 
                            next_channel_serving[current_consumer[i]] = 1'b0;
                            consumer_read_ready[current_consumer[i]] <= 0;
                            rr_ptr[i] <= (current_consumer[i] + 1) % NUM_CONSUMERS;
                            controller_state[i] <= IDLE;
                        end
                    end
                    WRITE_RELAYING: begin 
                        if (!consumer_write_valid[current_consumer[i]]) begin 
                            next_channel_serving[current_consumer[i]] = 1'b0;
                            consumer_write_ready[current_consumer[i]] <= 0;
                            rr_ptr[i] <= (current_consumer[i] + 1) % NUM_CONSUMERS;
                            controller_state[i] <= IDLE;
                        end
                    end
                endcase
            end
            
            channel_serving_consumer <= next_channel_serving;
        end
    end
endmodule