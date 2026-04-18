`default_nettype none
`timescale 1ns/1ns

module tb_gpu_phase4;

    localparam DATA_MEM_ADDR_BITS = 8;
    localparam DATA_MEM_DATA_BITS = 16;
    localparam DATA_MEM_NUM_CHANNELS = 4;
    localparam PROGRAM_MEM_ADDR_BITS = 8;
    localparam PROGRAM_MEM_DATA_BITS = 16;
    localparam PROGRAM_MEM_NUM_CHANNELS = 1;
    localparam NUM_CORES = 2;
    localparam THREADS_PER_BLOCK = 4;

    logic clk;
    logic reset;
    logic start;
    logic done;

    logic device_control_write_enable;
    logic [7:0] device_control_data;

    logic [PROGRAM_MEM_NUM_CHANNELS-1:0] program_mem_read_valid;
    logic [PROGRAM_MEM_ADDR_BITS-1:0] program_mem_read_address [PROGRAM_MEM_NUM_CHANNELS];
    logic [PROGRAM_MEM_NUM_CHANNELS-1:0] program_mem_read_ready;
    logic [PROGRAM_MEM_DATA_BITS-1:0] program_mem_read_data [PROGRAM_MEM_NUM_CHANNELS];

    logic [DATA_MEM_NUM_CHANNELS-1:0] data_mem_read_valid;
    logic [DATA_MEM_ADDR_BITS-1:0] data_mem_read_address [DATA_MEM_NUM_CHANNELS];
    logic [DATA_MEM_NUM_CHANNELS-1:0] data_mem_read_ready;
    logic [DATA_MEM_DATA_BITS-1:0] data_mem_read_data [DATA_MEM_NUM_CHANNELS];
    logic [DATA_MEM_NUM_CHANNELS-1:0] data_mem_write_valid;
    logic [DATA_MEM_ADDR_BITS-1:0] data_mem_write_address [DATA_MEM_NUM_CHANNELS];
    logic [DATA_MEM_DATA_BITS-1:0] data_mem_write_data [DATA_MEM_NUM_CHANNELS];
    logic [DATA_MEM_NUM_CHANNELS-1:0] data_mem_write_ready;

    logic [15:0] prog_mem [0:255];
    logic [15:0] data_mem [0:255];

    always #5 clk = ~clk;

    gpu #(
        .DATA_MEM_ADDR_BITS(DATA_MEM_ADDR_BITS),
        .DATA_MEM_DATA_BITS(DATA_MEM_DATA_BITS),
        .DATA_MEM_NUM_CHANNELS(DATA_MEM_NUM_CHANNELS),
        .PROGRAM_MEM_ADDR_BITS(PROGRAM_MEM_ADDR_BITS),
        .PROGRAM_MEM_DATA_BITS(PROGRAM_MEM_DATA_BITS),
        .PROGRAM_MEM_NUM_CHANNELS(PROGRAM_MEM_NUM_CHANNELS),
        .NUM_CORES(NUM_CORES),
        .THREADS_PER_BLOCK(THREADS_PER_BLOCK)
    ) dut (.*);

    // Program memory (zero wait)
    assign program_mem_read_ready = program_mem_read_valid;
    assign program_mem_read_data[0] = prog_mem[program_mem_read_address[0]];

    // Data memory model with latency
    // Data memory model with configurable latency
localparam MEM_LATENCY = 3;
logic read_req_pending [DATA_MEM_NUM_CHANNELS];
logic write_req_pending [DATA_MEM_NUM_CHANNELS];
logic [7:0] read_addr_pending [DATA_MEM_NUM_CHANNELS];
logic [7:0] write_addr_pending [DATA_MEM_NUM_CHANNELS];
logic [15:0] write_data_pending [DATA_MEM_NUM_CHANNELS];
int latency_counter [DATA_MEM_NUM_CHANNELS];

// Initialize all arrays
initial begin
    for (int i = 0; i < DATA_MEM_NUM_CHANNELS; i++) begin
        read_req_pending[i] = 0;
        write_req_pending[i] = 0;
        latency_counter[i] = 0;
    end
end

always_ff @(posedge clk) begin
    for (int i = 0; i < DATA_MEM_NUM_CHANNELS; i++) begin
        // Default deassert ready
        data_mem_read_ready[i] <= 1'b0;
        data_mem_write_ready[i] <= 1'b0;

        // Read request capture
        if (data_mem_read_valid[i] && !read_req_pending[i]) begin
            read_req_pending[i] <= 1'b1;
            read_addr_pending[i] <= data_mem_read_address[i];
            latency_counter[i] <= MEM_LATENCY;
            $display("[%0t] MEM: Ch %0d read req addr=%h", $time, i, data_mem_read_address[i]);
        end

        // Write request capture
        if (data_mem_write_valid[i] && !write_req_pending[i]) begin
            write_req_pending[i] <= 1'b1;
            write_addr_pending[i] <= data_mem_write_address[i];
            write_data_pending[i] <= data_mem_write_data[i];
            latency_counter[i] <= MEM_LATENCY;
            $display("[%0t] MEM: Ch %0d write req addr=%h data=%h", $time, i, data_mem_write_address[i], data_mem_write_data[i]);
        end

        // Handle pending read
        if (read_req_pending[i]) begin
            if (latency_counter[i] == 0) begin
                data_mem_read_ready[i] <= 1'b1;
                data_mem_read_data[i] <= data_mem[read_addr_pending[i]];
                read_req_pending[i] <= 1'b0;
                $display("[%0t] MEM: Ch %0d read ready data=%h", $time, i, data_mem[read_addr_pending[i]]);
            end else begin
                latency_counter[i] <= latency_counter[i] - 1;
            end
        end

        // Handle pending write
        if (write_req_pending[i]) begin
            if (latency_counter[i] == 0) begin
                data_mem[write_addr_pending[i]] <= write_data_pending[i];
                data_mem_write_ready[i] <= 1'b1;
                write_req_pending[i] <= 1'b0;
                $display("[%0t] MEM: Ch %0d write ready", $time, i);
            end else begin
                latency_counter[i] <= latency_counter[i] - 1;
            end
        end
    end
end
    initial begin
        for (int i = 0; i < DATA_MEM_NUM_CHANNELS; i++) begin
            read_req_pending[i] = 1'b0;
            write_req_pending[i] = 1'b0;
            latency_counter[i] = 0;
        end
    end

    initial begin
        clk = 0; reset = 1; start = 0;
        device_control_write_enable = 0;

        // Load program (same as before)
        prog_mem[0] = 16'h9105; // CONST R1, #5
        prog_mem[1] = 16'h9210; // CONST R2, #16
        prog_mem[2] = 16'h8021; // STR   R2, R1
        prog_mem[3] = 16'h7320; // LDR   R3, R2
        prog_mem[4] = 16'h9403; // CONST R4, #3
        prog_mem[5] = 16'h3543; // ADD   R5, R3, R4
        prog_mem[6] = 16'h9620; // CONST R6, #32
        prog_mem[7] = 16'h8065; // STR   R6, R5
        prog_mem[8] = 16'h7760; // LDR   R7, R6
        prog_mem[9] = 16'hF000; // RET
        for (int i = 10; i < 256; i++) prog_mem[i] = 16'h0000;

        repeat (5) @(posedge clk);
        reset = 0;
        @(posedge clk);

        device_control_write_enable = 1;
        device_control_data = 8'd4;
        @(posedge clk);
        device_control_write_enable = 0;

        $display("[%0t] Starting Phase 4 GPU test", $time);
        start = 1;
        @(posedge clk);
        start = 0;

        wait (done == 1);
        $display("[%0t] GPU done asserted", $time);

        repeat (20) @(posedge clk); // drain pipeline

        $display("Data memory[0x10] = %0d (expected 5)", data_mem[16]);
        $display("Data memory[0x20] = %0d (expected 8)", data_mem[32]);

        if (data_mem[16] == 5 && data_mem[32] == 8)
            $display("Phase 4 test PASSED");
        else
            $error("Phase 4 test FAILED");

        $finish;
    end

    initial begin
        #1000000; // 10,000 ns timeout
        $error("Timeout: simulation did not finish");
        $finish;
    end

endmodule