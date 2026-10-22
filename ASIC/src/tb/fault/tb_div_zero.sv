`default_nettype none
`timescale 1ns/1ns

module tb_div_zero;

    // -- Parameters ---------------------------------------------------------------
    localparam DATA_MEM_ADDR_BITS    = 32;
    localparam DATA_MEM_DATA_BITS    = 32;
    localparam PROGRAM_MEM_ADDR_BITS = 32;
    localparam PROGRAM_MEM_DATA_BITS = 32;
    localparam THREADS_PER_BLOCK     = 4;
    localparam NUM_WARPS             = 1;
    localparam SHARED_MEM_SIZE       = 256;
    localparam MAX_MEM_ADDR          = 32'h0000_FFFF; // 65535
    localparam DATA_BITS             = 32;
    localparam CLK_HALF              = 5;

    localparam IMEM_DEPTH = 256;
    localparam DMEM_DEPTH = 256;

    // -- Clock / Reset ------------------------------------------------------------
    reg clk = 0;
    always #CLK_HALF clk = ~clk;

    reg reset;
    reg start;

    // -- Memories -----------------------------------------------------------------
    reg [PROGRAM_MEM_DATA_BITS-1:0] imem [0:IMEM_DEPTH-1];
    reg [DATA_MEM_DATA_BITS-1:0]    dmem [0:DMEM_DEPTH-1];

    wire                              pmem_rv;
    wire [PROGRAM_MEM_ADDR_BITS-1:0]  pmem_ra;
    reg                               pmem_rr;
    reg  [PROGRAM_MEM_DATA_BITS-1:0]  pmem_rd_data;

    wire                               dmem_rv;
    wire [DATA_MEM_ADDR_BITS-1:0]      dmem_ra;
    reg                                dmem_rr;
    reg  [(DATA_MEM_DATA_BITS*4)-1:0]  dmem_rd_data;

    wire                               dmem_wv;
    wire [DATA_MEM_ADDR_BITS-1:0]      dmem_wa;
    wire [(DATA_MEM_DATA_BITS*4)-1:0]  dmem_wd;
    wire [3:0]                         dmem_ws;
    reg                                dmem_wr;

    always @(posedge clk) begin
        // Instruction Mem
        pmem_rr <= pmem_rv;
        pmem_rd_data <= imem[pmem_ra[7:0]];
        
        // Data Mem (Block formatting)
        dmem_rr <= dmem_rv;
        if (dmem_rv) begin
            dmem_rd_data[31:0]   <= dmem[dmem_ra * 4];
            dmem_rd_data[63:32]  <= dmem[dmem_ra * 4 + 1];
            dmem_rd_data[95:64]  <= dmem[dmem_ra * 4 + 2];
            dmem_rd_data[127:96] <= dmem[dmem_ra * 4 + 3];
        end
        dmem_wr <= dmem_wv;
        if (dmem_wv) begin
            if (dmem_ws[0]) dmem[dmem_wa * 4]     <= dmem_wd[31:0];
            if (dmem_ws[1]) dmem[dmem_wa * 4 + 1] <= dmem_wd[63:32];
            if (dmem_ws[2]) dmem[dmem_wa * 4 + 2] <= dmem_wd[95:64];
            if (dmem_ws[3]) dmem[dmem_wa * 4 + 3] <= dmem_wd[127:96];
        end
    end

    // -- DUT (Device Under Test) --------------------------------------------------
    wire done;
    
    // Exception wires
    wire exception_raised;
    wire [$clog2(NUM_WARPS)-1:0] exception_warp_id;
    wire [31:0] exception_pc;
    wire [3:0] exception_cause;

    core #(
        .DATA_MEM_ADDR_BITS    (DATA_MEM_ADDR_BITS),
        .DATA_MEM_DATA_BITS    (DATA_MEM_DATA_BITS),
        .PROGRAM_MEM_ADDR_BITS (PROGRAM_MEM_ADDR_BITS),
        .PROGRAM_MEM_DATA_BITS (PROGRAM_MEM_DATA_BITS),
        .THREADS_PER_BLOCK     (THREADS_PER_BLOCK),
        .NUM_WARPS             (NUM_WARPS),
        .SHARED_MEM_SIZE       (SHARED_MEM_SIZE),
        .MAX_MEM_ADDR          (MAX_MEM_ADDR),
        .DATA_BITS             (DATA_BITS),
        .DEBUG                 (0)
    ) dut (
        .clk                    (clk),
        .reset                  (reset),
        .start                  (start),
        .done                   (done),
        .block_id               (8'd0),
        .thread_count           (THREADS_PER_BLOCK),

        // Exceptions
        .exception_raised       (exception_raised),
        .exception_warp_id      (exception_warp_id),
        .exception_pc           (exception_pc),
        .exception_cause        (exception_cause),

        .program_mem_read_valid   (pmem_rv),
        .program_mem_read_address (pmem_ra),
        .program_mem_read_ready   (pmem_rr),
        .program_mem_read_data    (pmem_rd_data),

        .data_mem_read_valid      (dmem_rv),
        .data_mem_read_address    (dmem_ra),
        .data_mem_read_ready      (dmem_rr),
        .data_mem_read_data       (dmem_rd_data),
        .data_mem_write_valid     (dmem_wv),
        .data_mem_write_address   (dmem_wa),
        .data_mem_write_data      (dmem_wd),
        .data_mem_write_strobe    (dmem_ws),
        .data_mem_write_ready     (dmem_wr)
    );

    // -- ISA Encodings ------------------------------------------------------------
    localparam OP_NOP = 6'd0, OP_ADD = 6'd3, OP_DIV = 6'd6, OP_LDR = 6'd7, 
               OP_CONST = 6'd9, OP_LDSH = 6'd11, OP_EXIT = 6'd15;

    function automatic [31:0] enc_exit(); return {OP_EXIT, 26'b0}; endfunction
    function automatic [31:0] enc_const(input [4:0] rd, input [15:0] imm); return {OP_CONST, rd, 5'b0, imm}; endfunction
    function automatic [31:0] enc_add(input [4:0] rd, input [4:0] rs, input [4:0] rt); return {OP_ADD, rd, rs, rt, 11'b0}; endfunction
    function automatic [31:0] enc_div(input [4:0] rd, input [4:0] rs, input [4:0] rt); return {OP_DIV, rd, rs, rt, 11'b0}; endfunction
    function automatic [31:0] enc_ldr(input [4:0] rd, input [4:0] rs, input [15:0] offset); return {OP_LDR, rd, rs, offset}; endfunction
    function automatic [31:0] enc_ldsh(input [4:0] rd, input [4:0] rs); return {OP_LDSH, rd, rs, 16'b0}; endfunction

    task automatic clear_memories();
        for (int k = 0; k < IMEM_DEPTH; k++) imem[k] = enc_exit();
        for (int k = 0; k < DMEM_DEPTH; k++) dmem[k] = 0;
    endtask

task automatic run_and_check(input string test_name, input [3:0] exp_cause, input [31:0] exp_pc);
        integer cyc = 0;
        
        @(posedge clk); reset = 1; start = 0;
        @(posedge clk); reset = 0;
        @(posedge clk); start = 1; // <-- KEEP START HIGH

        while (!done && cyc < 200) begin
            @(posedge clk);
            cyc++;
        end

        start = 0; // <-- Deassert start only AFTER the core is done
        @(posedge clk); 

        $display("------------------------------------------------------------");
        $display(" %s", test_name);
        
        if (cyc >= 200) begin
            $display("  [FAIL] Timeout! GPU did not assert 'done'. Fault deadlock?");
        end else if (!exception_raised) begin
            $display("  [FAIL] GPU finished without raising an exception.");
        end else begin
            if (exception_cause === exp_cause)
                $display("  [PASS] Cause Code = %0d", exception_cause);
            else
                $display("  [FAIL] Expected Cause %0d, got %0d", exp_cause, exception_cause);
                
            if (exception_pc === exp_pc)
                $display("  [PASS] Fault PC = %0d", exception_pc);
            else
                $display("  [FAIL] Expected Fault PC %0d, got %0d", exp_pc, exception_pc);
                
            $display("  [PASS] GPU halted cleanly (done = 1).");
        end
    endtask
    // -- Tests --------------------------------------------------------------------
    initial begin
        $display("\n============================================================");
        $display(" GPU EXCEPTION HANDLING TESTBENCH");
        $display("============================================================\n");

        // --- TEST 1: Divide by Zero ---
        clear_memories();
        imem[0] = enc_const(1, 10);      // R1 = 10
        imem[1] = enc_const(2, 0);       // R2 = 0
        imem[2] = enc_div(3, 1, 2);      // R3 = 10 / 0  <-- FAULT (PC=2)
        imem[3] = enc_add(4, 1, 1);      // Should never execute
        run_and_check("TEST 1: Divide by Zero", 4'd1, 32'd2);

        // --- TEST 2: Global Memory Fault ---
        // Exceed MAX_MEM_ADDR (65535). Constants are 16-bit sign extended, 
        // so we build 66000 via additions to avoid negative values.
        clear_memories();
        imem[0] = enc_const(1, 32000);   // R1 = 32000
        imem[1] = enc_const(2, 32000);   // R2 = 32000
        imem[2] = enc_add(3, 1, 2);      // R3 = 64000
        imem[3] = enc_const(4, 2000);    // R4 = 2000
        imem[4] = enc_add(5, 3, 4);      // R5 = 66000
        imem[5] = enc_ldr(6, 5, 0);      // Load from 66000 <-- FAULT (PC=5)
        run_and_check("TEST 2: Global Memory Out-of-Bounds (> 65535)", 4'd2, 32'd5);

        // --- TEST 3: Shared Memory Fault ---
        // Exceed SHARED_MEM_SIZE (256).
        clear_memories();
        imem[0] = enc_const(1, 256);     // R1 = 256
        imem[1] = enc_ldsh(2, 1);        // Load Shared from 256 <-- FAULT (PC=1)
        run_and_check("TEST 3: Shared Memory Out-of-Bounds (>= 256)", 4'd2, 32'd1);

        $display("\n============================================================");
        $display(" ALL TESTS COMPLETED");
        $display("============================================================\n");
        $finish;
    end
endmodule