`default_nettype none
`timescale 1ns/1ns

// SHARED MEMORY (Pipeline Ready)
// > Independent 1-cycle latency memory module
module shared_mem #(
     parameter DATA_BITS         = 16,
     parameter ADDR_BITS         = 8,
     parameter SIZE              = 256,
     parameter THREADS_PER_BLOCK = 4
) (
     input wire clk,
     input wire reset,
     
     // Per thread read ports
     input wire [THREADS_PER_BLOCK-1:0] read_valid,
     input wire [ADDR_BITS-1:0]         read_address [THREADS_PER_BLOCK-1:0],
     output reg [THREADS_PER_BLOCK-1:0] read_ready,
     output reg [DATA_BITS-1:0]         read_data [THREADS_PER_BLOCK-1:0],
     
     // Per thread write ports
     input wire [THREADS_PER_BLOCK-1:0] write_valid,
     input wire [DATA_BITS-1:0]         write_data [THREADS_PER_BLOCK-1:0],
     input wire [ADDR_BITS-1:0]         write_address [THREADS_PER_BLOCK-1:0],
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
               // Each thread gets its own port — no arbitration needed
               // Conflicts handled by Programmer (Software)
               for (i = 0; i < THREADS_PER_BLOCK; i = i + 1) begin
                    // Read logic
                    if (read_valid[i]) begin
                         read_data[i]  <= mem[read_address[i]];
                         read_ready[i] <= 1'b1;
                    end else begin
                         read_ready[i] <= 1'b0;
                    end

                    // Write logic
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