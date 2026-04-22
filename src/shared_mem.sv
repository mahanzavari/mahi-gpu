`default_nettype none
`timescale 1ns/1ns
module shared_mem #(
     parameter DATA_BITS         = 16,
     parameter ADDR_BITS         = 8,
     parameter SIZE              = 256,
     parameter THREADS_PER_BLOCK = 4
) (
     input wire clk,
     input wire reset,
     input wire [THREADS_PER_BLOCK-1:0] read_valid,
     input wire [ADDR_BITS-1:0]         read_address [THREADS_PER_BLOCK], // CHANGED to [SIZE] to eliminate reversals
     output reg [THREADS_PER_BLOCK-1:0] read_ready,
     output reg [DATA_BITS-1:0]         read_data [THREADS_PER_BLOCK],
     input wire [THREADS_PER_BLOCK-1:0] write_valid,
     input wire [DATA_BITS-1:0]         write_data [THREADS_PER_BLOCK],
     input wire [ADDR_BITS-1:0]         write_address [THREADS_PER_BLOCK],
     output reg [THREADS_PER_BLOCK-1:0] write_ready
);
     reg [DATA_BITS-1:0] mem [0:SIZE-1];
     integer k, i;
     always @(posedge clk) begin
          if (reset) begin
               read_ready  <= 0;
               write_ready <= 0;
               for (k = 0; k < SIZE; k = k + 1) 
                    mem[k] <= 0;
          end else begin
               for (i = 0; i < THREADS_PER_BLOCK; i = i + 1) begin
                    if (read_valid[i]) begin
                         read_data[i]  <= mem[read_address[i]];
                         read_ready[i] <= 1'b1;
                    end else begin
                         read_ready[i] <= 1'b0;
                    end
                    if (write_valid[i]) begin
                         mem[write_address[i]] <= write_data[i];
                         write_ready[i] <= 1'b1;
                    end else begin
                         write_ready[i] <= 1'b0;
                    end
               end
          end
     end
endmodule