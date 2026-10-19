`default_nettype none
`timescale 1ns/1ns

module shared_mem #(
    parameter DATA_BITS         = 32,
    parameter ADDR_BITS         = 32,
    parameter SIZE              = 256,
    parameter THREADS_PER_BLOCK = 4,
    parameter N_BANKS           = 4
) (
    input  wire clk,
    input  wire reset,

    input  wire [THREADS_PER_BLOCK-1:0] read_valid,
    input  wire [ADDR_BITS-1:0]         read_address  [THREADS_PER_BLOCK],
    output reg  [THREADS_PER_BLOCK-1:0] read_ready,
    output reg  [DATA_BITS-1:0]         read_data     [THREADS_PER_BLOCK],

    input  wire [THREADS_PER_BLOCK-1:0] write_valid,
    input  wire [DATA_BITS-1:0]         write_data    [THREADS_PER_BLOCK],
    input  wire [ADDR_BITS-1:0]         write_address [THREADS_PER_BLOCK],
    output reg  [THREADS_PER_BLOCK-1:0] write_ready
);

    localparam BANK_DEPTH = SIZE / N_BANKS;
    localparam BANK_BITS  = $clog2(N_BANKS);      
    localparam OFF_BITS   = $clog2(BANK_DEPTH);   

    reg [DATA_BITS-1:0] mem [N_BANKS][0:BANK_DEPTH-1];

    logic [BANK_BITS-1:0] r_bank   [THREADS_PER_BLOCK];
    logic [OFF_BITS-1:0]  r_offset [THREADS_PER_BLOCK];
    logic [BANK_BITS-1:0] w_bank   [THREADS_PER_BLOCK];
    logic [OFF_BITS-1:0]  w_offset [THREADS_PER_BLOCK];

    always_comb begin
        for (int i = 0; i < THREADS_PER_BLOCK; i++) begin
            r_bank[i]   = read_address[i][BANK_BITS-1:0];
            r_offset[i] = read_address[i][BANK_BITS +: OFF_BITS];
            w_bank[i]   = write_address[i][BANK_BITS-1:0];
            w_offset[i] = write_address[i][BANK_BITS +: OFF_BITS];
        end
    end

    logic [THREADS_PER_BLOCK-1:0] w_bank_conflict; 
    logic [THREADS_PER_BLOCK-1:0] r_bank_conflict;  
    logic [THREADS_PER_BLOCK-1:0] raw_conflict;     
    logic [THREADS_PER_BLOCK-1:0] r_broadcast;      

    always_comb begin
        w_bank_conflict = '0;
        r_bank_conflict = '0;
        raw_conflict    = '0;
        r_broadcast     = '0;

        for (int i = 0; i < THREADS_PER_BLOCK; i++) begin
            for (int j = 0; j < i; j++) begin   
                if (write_valid[i] && write_valid[j] && w_bank[i] == w_bank[j]) begin
                    w_bank_conflict[i] = 1'b1;
                end

                if (read_valid[i] && read_valid[j] && r_bank[i] == r_bank[j] && read_address[i] != read_address[j]) begin
                    r_bank_conflict[i] = 1'b1;
                end

                if (read_valid[i] && read_valid[j] && read_address[i] == read_address[j]) begin
                    r_broadcast[i] = 1'b1;
                end

                if (read_valid[i]  && write_valid[j] && r_bank[i] == w_bank[j] && r_offset[i] == w_offset[j]) begin
                    raw_conflict[i] = 1'b1;
                end
            end
        end
    end

    integer k, b;

    always_ff @(posedge clk) begin
        if (reset) begin
            read_ready  <= '0;
            write_ready <= '0;
            for (b = 0; b < N_BANKS; b++) begin
                for (k = 0; k < BANK_DEPTH; k++) mem[b][k] <= '0;
            end
        end else begin

            read_ready  <= '0;
            write_ready <= '0;

            for (int i = 0; i < THREADS_PER_BLOCK; i++) begin
                
                // WRITE Dispatch
                if (write_valid[i] && !w_bank_conflict[i]) begin
                    mem[w_bank[i]][w_offset[i]] <= write_data[i];
                    write_ready[i] <= 1'b1;
                end

                // READ Dispatch: Standard
                if (read_valid[i] && !r_bank_conflict[i] && !raw_conflict[i] && !r_broadcast[i]) begin
                    read_data[i]  <= mem[r_bank[i]][r_offset[i]];
                    read_ready[i] <= 1'b1;
                end

                // READ Dispatch: Multi-cast Broadcast Piggyback
                if (read_valid[i] && r_broadcast[i] && !raw_conflict[i]) begin
                    for (int j = 0; j < i; j++) begin
                        if (read_valid[j] && read_address[j] == read_address[i]) begin
                            read_data[i]  <= mem[r_bank[j]][r_offset[j]]; 
                            read_ready[i] <= 1'b1;
                        end
                    end
                end

            end
        end
    end

endmodule