`default_nettype none
`timescale 1ns/1ns

// =============================================================================
// tb_asic_call_ret_branch.sv — ASIC-profile regression test for NZP/CALL/RET
// -----------------------------------------------------------------------------
// Targets the exact bug class found in pc.sv during the ASIC port: the
// sequential nzp/return_stack/stack_ptr updates were deleted, leaving only
// `ifndef SYNTHESIS $display calls behind. This test exercises:
//   1. CMP + conditional branch (N / Z / P) on every thread, so a dead NZP
//      register makes every thread take the same (wrong) branch.
//   2. Two levels of nested CALL/RET per thread, so a dead return-address
//      stack sends RET to a garbage PC instead of unwinding correctly.
// Must be compiled with -DTARGET_ASIC=1 (see ASIC/Makefile `make verify-asic`).
// -----------------------------------------------------------------------------
// KNOWN OPEN FAILURE (not the bug this test was written for):
//   Thread 4 currently reports 0 instead of 211. Root cause is a second,
//   separate data-loss bug in the dcache/L2/victim-write-buffer write path:
//   when two different partial-mask stores (divergent reconvergence groups
//   from the SAME warp) target the same cache block at different times, the
//   first partial write's word is lost by the time the block is evicted to
//   memory. Reproduced with MEM_TRACE defined (`-DMEM_TRACE=1`): the final
//   eviction of the shared block shows strobe=1111 but the first thread's
//   word reads back as 0 instead of its written value. LSU coalescing,
//   dcache write-no-allocate-on-miss, and L2's hit-merge logic all look
//   individually correct by inspection; exact root cause not yet isolated.
//   This is present verbatim in src/rtl too (dcache.sv/l2_cache.sv/
//   victim_write_buffer.sv are byte-identical to the ASIC port here) — it is
//   NOT an ASIC-port regression. Left failing intentionally rather than
//   masked, since it is a real bug the test correctly caught.
// =============================================================================
module tb_asic_call_ret_branch;

    localparam DATA_MEM_ADDR_BITS       = gpu_pkg::CFG_DMEM_ADDR_BITS;
    localparam DATA_MEM_DATA_BITS       = gpu_pkg::CFG_DMEM_DATA_BITS;
    localparam DATA_MEM_NUM_CHANNELS    = gpu_pkg::CFG_DATA_MEM_NUM_CHANNELS;
    localparam PROGRAM_MEM_ADDR_BITS    = gpu_pkg::CFG_PMEM_ADDR_BITS;
    localparam PROGRAM_MEM_DATA_BITS    = gpu_pkg::CFG_PMEM_DATA_BITS;
    localparam PROGRAM_MEM_NUM_CHANNELS = gpu_pkg::CFG_PROGRAM_MEM_NUM_CHANNELS;
    localparam NUM_CORES                = gpu_pkg::CFG_NUM_CORES;
    localparam THREADS_PER_BLOCK        = gpu_pkg::CFG_THREADS_PER_BLOCK;
    localparam NUM_WARPS                = gpu_pkg::CFG_NUM_WARPS;
    localparam TOTAL_THREADS            = THREADS_PER_BLOCK * NUM_WARPS * NUM_CORES;

    reg clk; reg reset; reg start; wire done;
    reg device_control_write_enable; reg [7:0] device_control_data;

    wire [PROGRAM_MEM_NUM_CHANNELS-1:0] program_mem_read_valid;
    wire [PROGRAM_MEM_ADDR_BITS-1:0]    program_mem_read_address [PROGRAM_MEM_NUM_CHANNELS];
    reg  [PROGRAM_MEM_NUM_CHANNELS-1:0] program_mem_read_ready;
    reg  [(PROGRAM_MEM_DATA_BITS*4)-1:0] program_mem_read_data [PROGRAM_MEM_NUM_CHANNELS];

    wire [DATA_MEM_NUM_CHANNELS-1:0] data_mem_read_valid;
    wire [DATA_MEM_ADDR_BITS-1:0]    data_mem_read_address [DATA_MEM_NUM_CHANNELS];
    reg  [DATA_MEM_NUM_CHANNELS-1:0] data_mem_read_ready;
    reg  [(DATA_MEM_DATA_BITS*4)-1:0] data_mem_read_data [DATA_MEM_NUM_CHANNELS];

    wire [DATA_MEM_NUM_CHANNELS-1:0] data_mem_write_valid;
    wire [DATA_MEM_ADDR_BITS-1:0]    data_mem_write_address [DATA_MEM_NUM_CHANNELS];
    wire [(DATA_MEM_DATA_BITS*4)-1:0] data_mem_write_data [DATA_MEM_NUM_CHANNELS];
    wire [3:0]                       data_mem_write_strobe [DATA_MEM_NUM_CHANNELS];
    reg  [DATA_MEM_NUM_CHANNELS-1:0] data_mem_write_ready;

    gpu dut (
        .clk(clk), .reset(reset), .start(start), .done(done),
        .device_control_write_enable(device_control_write_enable),
        .device_control_address(8'h00),
        .device_control_data(device_control_data),

        .program_mem_read_valid(program_mem_read_valid), .program_mem_read_address(program_mem_read_address),
        .program_mem_read_ready(program_mem_read_ready), .program_mem_read_data(program_mem_read_data),

        .data_mem_read_valid(data_mem_read_valid), .data_mem_read_address(data_mem_read_address),
        .data_mem_read_ready(data_mem_read_ready), .data_mem_read_data(data_mem_read_data),

        .data_mem_write_valid(data_mem_write_valid), .data_mem_write_address(data_mem_write_address),
        .data_mem_write_data(data_mem_write_data), .data_mem_write_strobe(data_mem_write_strobe),
        .data_mem_write_ready(data_mem_write_ready),

        .pmu_snap_0(), .pmu_snap_1(), .pmu_snap_2(), .pmu_snap_3()
    );

    reg [PROGRAM_MEM_DATA_BITS-1:0] p_mem [0:1023];
    reg [DATA_MEM_DATA_BITS-1:0]    d_mem [0:1023];

    function [31:0] encode_R(input [5:0] op, input [4:0] rd, input [4:0] rs, input [4:0] rt);
        encode_R = {op, rd, rs, rt, 11'd0};
    endfunction

    function [31:0] encode_I(input [5:0] op, input [4:0] rd, input [4:0] rs, input [15:0] imm);
        encode_I = {op, rd, rs, imm};
    endfunction

    function [31:0] encode_BR(input [2:0] nzp, input [15:0] imm);
        encode_BR = {6'd1, nzp, 2'b00, 5'd0, imm};
    endfunction

    function [31:0] encode_CALL(input [15:0] target);
        encode_CALL = {6'd13, 10'd0, target};
    endfunction

    localparam OP_CMP = 6'd2, OP_ADD = 6'd3, OP_CONST = 6'd9, OP_STR = 6'd8,
               OP_RET_FN = 6'd14, OP_EXIT = 6'd15;

    always @(posedge clk) begin
        for (int i = 0; i < PROGRAM_MEM_NUM_CHANNELS; i++) begin
            program_mem_read_ready[i] <= program_mem_read_valid[i];
            if (program_mem_read_valid[i]) begin
                automatic int word_base = program_mem_read_address[i] * 4;
`ifdef MEM_TRACE
                $display("[%0t] [MEM-MOCK] chan=%0d program_mem_read_address=%0d word_base=%0d",
                         $time, i, program_mem_read_address[i], word_base);
`endif
                program_mem_read_data[i] <= {
                    p_mem[word_base + 3], p_mem[word_base + 2],
                    p_mem[word_base + 1], p_mem[word_base]
                };
            end
        end

        for (int i = 0; i < DATA_MEM_NUM_CHANNELS; i++) begin
            data_mem_read_ready[i] <= data_mem_read_valid[i];
            if (data_mem_read_valid[i]) begin
                automatic int b = data_mem_read_address[i];
                data_mem_read_data[i] <= {d_mem[b*4+3], d_mem[b*4+2], d_mem[b*4+1], d_mem[b*4+0]};
            end

            data_mem_write_ready[i] <= data_mem_write_valid[i];
            if (data_mem_write_valid[i]) begin
                automatic int b = data_mem_write_address[i];
`ifdef MEM_TRACE
                $display("[%0t] [DMEM-WRITE] chan=%0d block=%0d strobe=%b data=%h",
                         $time, i, b, data_mem_write_strobe[i], data_mem_write_data[i]);
`endif
                if (data_mem_write_strobe[i][0]) d_mem[b*4+0] <= data_mem_write_data[i][31:0];
                if (data_mem_write_strobe[i][1]) d_mem[b*4+1] <= data_mem_write_data[i][63:32];
                if (data_mem_write_strobe[i][2]) d_mem[b*4+2] <= data_mem_write_data[i][95:64];
                if (data_mem_write_strobe[i][3]) d_mem[b*4+3] <= data_mem_write_data[i][127:96];
            end
        end
    end

    initial begin
        clk = 0;
        forever #5 clk = ~clk;
    end

    initial begin
        $display("=========================================================");
        $display(" ASIC REGRESSION: NZP branch + nested CALL/RET            ");
        $display(" Profile: NUM_CORES=%0d NUM_WARPS=%0d THREADS_PER_BLOCK=%0d (total=%0d threads)",
                  NUM_CORES, NUM_WARPS, THREADS_PER_BLOCK, TOTAL_THREADS);
        $display("=========================================================");

        for (int i = 0; i < 1024; i++) begin
            d_mem[i] = 0;
            p_mem[i] = 0;
        end

        // --- MAIN ---
        // R1 = tid (R31), R2 = 4 (threshold)
        p_mem[0] = encode_I(OP_CONST, 2, 0, 4);      // CONST R2, 4
        p_mem[1] = encode_R(OP_ADD,   1, 31, 0);     // ADD   R1, R31, R0   (R1 = tid, R0=0)
        p_mem[2] = encode_R(OP_CMP,   0, 1, 2);      // CMP   R1, R2  -> N:(tid<4) Z:(tid==4) P:(tid>4)
        p_mem[3] = encode_BR(3'b100, 10);            // BRn -> PATH_N (10)   tid < 4
        p_mem[4] = encode_BR(3'b010, 14);            // BRz -> PATH_Z (14)   tid == 4
        p_mem[5] = encode_BR(3'b001, 18);            // BRp -> PATH_P (18)   tid > 4
        p_mem[6] = encode_I(OP_EXIT, 0, 0, 0);       // unreachable guard

        // PATH_N (tid < 4): tag = 1
        p_mem[10] = encode_I(OP_CONST, 3, 0, 1);     // CONST R3, 1  (tag)
        p_mem[11] = encode_BR(3'b111, 22);           // always -> JOIN (22)
        p_mem[12] = 0; p_mem[13] = 0;

        // PATH_Z (tid == 4): tag = 2
        p_mem[14] = encode_I(OP_CONST, 3, 0, 2);     // CONST R3, 2
        p_mem[15] = encode_BR(3'b111, 22);
        p_mem[16] = 0; p_mem[17] = 0;

        // PATH_P (tid > 4): tag = 3
        p_mem[18] = encode_I(OP_CONST, 3, 0, 3);     // CONST R3, 3
        p_mem[19] = encode_BR(3'b111, 22);
        p_mem[20] = 0; p_mem[21] = 0;

        // JOIN (22): nested call, then store, then exit.
        // R4 = 0 (accumulator). CALL FUNC_OUTER (30) which adds 10 then calls
        // FUNC_INNER (40) which adds 1, then both RET back here in order.
        p_mem[22] = encode_I(OP_CONST, 4, 0, 0);     // CONST R4, 0
        p_mem[23] = encode_CALL(30);                 // CALL FUNC_OUTER
        // After both RETs unwind correctly, R4 == 11.
        // Result = tag*100 + R4  (expect 111, 211, or 311 depending on tag)
        p_mem[24] = encode_I(OP_CONST, 5, 0, 100);   // CONST R5, 100
        p_mem[25] = encode_R(6'd5, 6, 3, 5);         // MUL R6, R3, R5   (R6 = tag*100)
        p_mem[26] = encode_R(OP_ADD, 7, 6, 4);       // ADD R7, R6, R4   (R7 = tag*100 + R4)
        p_mem[27] = encode_I(OP_STR, 7, 31, 0);      // STR [R31+0], R7  (store result at d_mem[tid])
        p_mem[28] = encode_I(OP_EXIT, 0, 0, 0);      // EXIT
        p_mem[29] = 0;

        // FUNC_OUTER (30): R4 += 10, then nested CALL FUNC_INNER (40), then RET
        p_mem[30] = encode_I(OP_CONST, 8, 0, 10);    // CONST R8, 10
        p_mem[31] = encode_R(OP_ADD, 4, 4, 8);       // ADD R4, R4, R8   (R4 += 10)
        p_mem[32] = encode_CALL(40);                 // CALL FUNC_INNER (nested)
        p_mem[33] = {OP_RET_FN, 26'd0};              // RET_FN -> back to JOIN after CALL at p_mem[23]
        p_mem[34] = 0;

        // FUNC_INNER (40): R4 += 1, then RET
        p_mem[40] = encode_I(OP_CONST, 9, 0, 1);     // CONST R9, 1
        p_mem[41] = encode_R(OP_ADD, 4, 4, 9);       // ADD R4, R4, R9   (R4 += 1)
        p_mem[42] = {OP_RET_FN, 26'd0};              // RET_FN -> back to FUNC_OUTER after CALL at p_mem[32]
        p_mem[43] = 0;

        reset = 1;
        start = 0;
        device_control_write_enable = 0;
        device_control_data = 0;

        #100 reset = 0;
        #50;

        device_control_write_enable = 1;
        device_control_data = TOTAL_THREADS;
        #50 device_control_write_enable = 0;
        #50;

        start = 1;
        #50 start = 0;

        fork
            begin
                wait (done == 1'b1);
                $display("[%0t] [TESTBENCH] Execution Completed!", $time);
            end
            begin
                #20000;
                $display("[%0t] [TESTBENCH] ERROR: Timeout waiting for DONE! (likely a dead CALL/RET or branch bug)", $time);
                $fatal(1, "Timeout");
            end
        join_any
        disable fork;

        #20;

        begin
            int errors = 0;
            for (int tid = 0; tid < TOTAL_THREADS; tid++) begin
                automatic int expected_tag = (tid < 4) ? 1 : (tid == 4) ? 2 : 3;
                automatic int expected_val = expected_tag * 100 + 11;
                if (d_mem[tid] == expected_val) begin
                    $display("Thread %0d -> %0d [PASS]", tid, d_mem[tid]);
                end else begin
                    $display("Thread %0d -> %0d ... EXPECTED %0d [FAIL]", tid, d_mem[tid], expected_val);
                    errors++;
                end
            end
            if (errors == 0) begin
                $display("\nALL %0d THREADS PASSED (NZP branch + nested CALL/RET verified).", TOTAL_THREADS);
            end else begin
                $display("\nTEST FAILED WITH %0d / %0d ERRORS.", errors, TOTAL_THREADS);
                $fatal(1, "Regression failed");
            end
        end

        $finish;
    end
endmodule
