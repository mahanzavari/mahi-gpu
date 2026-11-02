`default_nettype none
`timescale 1ns/1ns

// 
//  tb_syncthreads.sv  -  Hardware Barrier (__syncthreads()) Test
// 
//
//  PURPOSE
//  -------
//  Proves that the WAITING_BARRIER scheduler state correctly stalls a warp
//  at a SYNC instruction until every active thread in the block has reached
//  the same barrier point, before any thread is allowed to proceed past it.
//
//  TEST PROGRAM  (8 threads per core: Warp 0 = threads 0-3, Warp 1 = threads 4-7)
//  -------------
//  PHASE 1 – Producer Write (all threads, STSH)
//    Each thread writes its local thread-ID into shared_mem[thread_id].
//    Because Warp 0 and Warp 1 are scheduled independently, one warp may
//    finish its write and reach SYNC well before the other.
//
//  PHASE 2 – Barrier (SYNC)
//    All threads execute SYNC.  The scheduler must hold both warps at
//    WAITING_BARRIER until every thread has enrolled, then release them.
//
//  PHASE 3 – Consumer Read (all threads, LDSH)
//    Each thread reads shared_mem[(thread_id + 4) % 8].
//    This is a deliberate cross-warp read: Warp 0 threads (0-3) read slots
//    written by Warp 1 (4-7), and vice-versa.
//    Without a working barrier the consumer reads would return 0 (uninitialised).
//
//  PHASE 4 – Store result to global data memory
//    Each thread stores its read value to d_mem[global_thread_id].
//
//  EXPECTED RESULTS (1 block, 8 threads)
//  --------------------------------------
//   Thread  | Reads shared_mem slot | Expected value stored
//   --------+-----------------------+----------------------
//     0      |  slot 4              |  4
//     1      |  slot 5              |  5
//     2      |  slot 6              |  6
//     3      |  slot 7              |  7
//     4      |  slot 0              |  0
//     5      |  slot 1              |  1
//     6      |  slot 2              |  2
//     7      |  slot 3              |  3
//
//  A FAIL on threads 0-3 (reading 0 instead of 4-7) is the classic symptom
//  of a missing/broken barrier - Warp 0 ran ahead of Warp 1's writes.
//
//  INSTRUCTION ENCODING REFERENCE (decoder.sv)
//  --------------------------------------------
//  CONST  Rd, imm8   : 1001_Rd___imm8      e.g. CONST R1,4  = 0x9104
//  ADD    Rd, Rs, Rt : 0011_Rd_Rs_Rt
//  SUB    Rd, Rs, Rt : 0100_Rd_Rs_Rt
//  CMP       Rs, Rt  : 0010_000_Rs_Rt      (nzp in [11:9] ignored on write)
//  BRnzp  nzp, imm8  : 0001_nzp_x_imm8    nzp: n=4 z=2 p=1  BRnzp=0x1E__
//  STSH      Rs, Rt  : 1100_0000_Rs_Rt     rs=addr, rt=data
//  LDSH   Rd, Rs     : 1011_Rd__Rs_0000    rs=addr
//  SYNC              : 1010_0000_0000_0000 = 0xA000
//  STR       Rs, Rt  : 1000_0000_Rs_Rt     rs=addr, rt=data
//  RET               : 1111_0000_0000_0000 = 0xF000
//  Special: R13=block_id  R14=total_threads  R15=local_thread_id
// =============================================================================

module tb_syncthreads;

    // -------------------------------------------------------------------------
    // Parameters  (keep TPB=4, NUM_WARPS=2 so we have 2 warps that interleave)
    // -------------------------------------------------------------------------
    localparam DATA_MEM_ADDR_BITS        = 8;
    localparam DATA_MEM_DATA_BITS        = 16;
    localparam DATA_MEM_NUM_CHANNELS     = 8;   // NUM_CORES * THREADS_PER_BLOCK
    localparam PROGRAM_MEM_ADDR_BITS     = 8;
    localparam PROGRAM_MEM_DATA_BITS     = 16;
    localparam PROGRAM_MEM_NUM_CHANNELS  = 1;
    localparam NUM_CORES                 = 1;
    localparam THREADS_PER_BLOCK         = 4;   // 4 threads/warp
    localparam NUM_WARPS                 = 2;   // 2 warps => 8 threads per core

    // -------------------------------------------------------------------------
    // DUT ports
    // -------------------------------------------------------------------------
    reg  clk, reset, start;
    wire done;
    reg  device_control_write_enable;
    reg  [7:0] device_control_data;

    wire [PROGRAM_MEM_NUM_CHANNELS-1:0]              program_mem_read_valid;
    wire [PROGRAM_MEM_ADDR_BITS-1:0]                 program_mem_read_address [PROGRAM_MEM_NUM_CHANNELS];
    reg  [PROGRAM_MEM_NUM_CHANNELS-1:0]              program_mem_read_ready;
    reg  [PROGRAM_MEM_DATA_BITS-1:0]                 program_mem_read_data    [PROGRAM_MEM_NUM_CHANNELS];

    wire [DATA_MEM_NUM_CHANNELS-1:0]                 data_mem_read_valid;
    wire [DATA_MEM_ADDR_BITS-1:0]                    data_mem_read_address    [DATA_MEM_NUM_CHANNELS];
    reg  [DATA_MEM_NUM_CHANNELS-1:0]                 data_mem_read_ready;
    reg  [DATA_MEM_DATA_BITS-1:0]                    data_mem_read_data       [DATA_MEM_NUM_CHANNELS];

    wire [DATA_MEM_NUM_CHANNELS-1:0]                 data_mem_write_valid;
    wire [DATA_MEM_ADDR_BITS-1:0]                    data_mem_write_address   [DATA_MEM_NUM_CHANNELS];
    wire [DATA_MEM_DATA_BITS-1:0]                    data_mem_write_data      [DATA_MEM_NUM_CHANNELS];
    reg  [DATA_MEM_NUM_CHANNELS-1:0]                 data_mem_write_ready;

    // -------------------------------------------------------------------------
    // DUT
    // -------------------------------------------------------------------------
    gpu #(
        .DATA_MEM_ADDR_BITS         (DATA_MEM_ADDR_BITS),
        .DATA_MEM_DATA_BITS         (DATA_MEM_DATA_BITS),
        .DATA_MEM_NUM_CHANNELS      (DATA_MEM_NUM_CHANNELS),
        .PROGRAM_MEM_ADDR_BITS      (PROGRAM_MEM_ADDR_BITS),
        .PROGRAM_MEM_DATA_BITS      (PROGRAM_MEM_DATA_BITS),
        .PROGRAM_MEM_NUM_CHANNELS   (PROGRAM_MEM_NUM_CHANNELS),
        .NUM_CORES                  (NUM_CORES),
        .THREADS_PER_BLOCK          (THREADS_PER_BLOCK),
        .NUM_WARPS                  (NUM_WARPS)
    ) dut (
        .clk                        (clk),
        .reset                      (reset),
        .start                      (start),
        .done                       (done),
        .device_control_write_enable(device_control_write_enable),
        .device_control_data        (device_control_data),
        .program_mem_read_valid     (program_mem_read_valid),
        .program_mem_read_address   (program_mem_read_address),
        .program_mem_read_ready     (program_mem_read_ready),
        .program_mem_read_data      (program_mem_read_data),
        .data_mem_read_valid        (data_mem_read_valid),
        .data_mem_read_address      (data_mem_read_address),
        .data_mem_read_ready        (data_mem_read_ready),
        .data_mem_read_data         (data_mem_read_data),
        .data_mem_write_valid       (data_mem_write_valid),
        .data_mem_write_address     (data_mem_write_address),
        .data_mem_write_data        (data_mem_write_data),
        .data_mem_write_ready       (data_mem_write_ready)
    );

    // -------------------------------------------------------------------------
    // Memory models
    // -------------------------------------------------------------------------
    reg [PROGRAM_MEM_DATA_BITS-1:0] p_mem [0:255];
    reg [DATA_MEM_DATA_BITS-1:0]    d_mem [0:255];

    // Program memory: 1-cycle latency
    always @(posedge clk) begin
        for (int i = 0; i < PROGRAM_MEM_NUM_CHANNELS; i++) begin
            program_mem_read_ready[i] <= program_mem_read_valid[i];
            if (program_mem_read_valid[i])
                program_mem_read_data[i] <= p_mem[program_mem_read_address[i]];
        end
    end

    // Data memory: 3-cycle read latency to stress-test latency hiding alongside the barrier
    reg [2:0] dmem_read_delay [DATA_MEM_NUM_CHANNELS];
    reg [DATA_MEM_ADDR_BITS-1:0] latched_read_addr [DATA_MEM_NUM_CHANNELS];

    always @(posedge clk) begin
        for (int i = 0; i < DATA_MEM_NUM_CHANNELS; i++) begin
            dmem_read_delay[i] <= {dmem_read_delay[i][1:0], data_mem_read_valid[i]};
            if (data_mem_read_valid[i] && !dmem_read_delay[i][0])
                latched_read_addr[i] <= data_mem_read_address[i];
            data_mem_read_ready[i] <= dmem_read_delay[i][2];
            if (dmem_read_delay[i][2])
                data_mem_read_data[i] <= d_mem[latched_read_addr[i]];
            // Writes are single-cycle
            data_mem_write_ready[i] <= data_mem_write_valid[i];
            if (data_mem_write_valid[i])
                d_mem[data_mem_write_address[i]] <= data_mem_write_data[i];
        end
    end

    // -------------------------------------------------------------------------
    // Clock
    // -------------------------------------------------------------------------
    initial clk = 0;
    always  #5 clk = ~clk;

    // -------------------------------------------------------------------------
    // Test program
    // -------------------------------------------------------------------------
    // Register aliases (for readability of the assembly comments below)
    //   R1  = scratch / constant
    //   R2  = consumer read address  (thread_id + 4) % 8
    //   R3  = value read from shared memory
    //   R4  = global thread ID  (block_id * total_threads_per_block + local_tid)
    //   R13 = block_id  (hardwired)
    //   R15 = local thread_id  (hardwired, 0-7)
    //
    // Program layout (addresses in decimal / hex):
    //
    //   PC  0  : CONST R1, 4          ; R1 = THREADS_PER_BLOCK
    //   PC  1  : STSH  R15, R15       ; shared_mem[local_tid] = local_tid
    //   PC  2  : SYNC                 ; *** BARRIER - wait for all 8 threads ***
    //   PC  3  : ADD   R2, R15, R1    ; R2 = local_tid + 4
    //   PC  4  : CONST R1, 8          ; R1 = 8 (total threads per warp-group)
    //   PC  5  : (no MOD instr-use branch-based modulo below)
    //            CMP   R2, R1         ; is (tid+4) >= 8 ?
    //   PC  6  : BRp   9              ; if R2 > R1, subtract 8  (BRp = 0001_001_0_imm8)
    //   PC  7  : LDSH  R3, R2         ; R3 = shared_mem[R2]  (R2 < 8, no wrap needed)
    //   PC  8  : BRnzp 10             ; skip subtract path
    //   PC  9  : SUB   R2, R2, R1     ; R2 = R2 - 8  (wrap around)
    //            -- fall through --
    //   PC 10  : LDSH  R3, R2         ; R3 = shared_mem[R2 after wrap]
    //   PC 11  : CONST R1, 8          ; R1 = threads per core
    //   PC 12  : MUL   R4, R13, R1    ; R4 = block_id * 8
    //   PC 13  : ADD   R4, R4, R15    ; R4 = global thread ID
    //   PC 14  : STR   R4, R3         ; d_mem[global_tid] = R3
    //   PC 15  : RET
    //
    // NOTE ON BRp ENCODING:
    //   BRnzp opcode = 4'b0001, nzp field = instruction[11:9]
    //   "p" (positive)  => nzp = 3'b001 => instruction[11:9] = 001
    //   "nzp" (always)  => nzp = 3'b111 => instruction[11:9] = 111
    //   Format: 0001_nzp_x_imm8   where x is instruction[8] (don't care, set 0)
    //
    //   BRp  target9  : {4'b0001, 3'b001, 1'b0, 8'd9}  = 16'h1209
    //   BRnzp target10: {4'b0001, 3'b111, 1'b0, 8'd10} = 16'h1E0A
    //
    // STSH Rs, Rt: opcode=1100, [11:8]=0000, [7:4]=Rs, [3:0]=Rt
    //   STSH R15, R15: 1100_0000_1111_1111 = 0xC0FF
    //
    // LDSH Rd, Rs:  opcode=1011, [11:8]=Rd, [7:4]=Rs, [3:0]=0000
    //   LDSH R3, R2:  1011_0011_0010_0000 = 0xB320
    //
    // ADD Rd, Rs, Rt: opcode=0011
    //   ADD R2, R15, R1: 0011_0010_1111_0001 = 0x32F1
    //   ADD R4, R4, R15: 0011_0100_0100_1111 = 0x344F
    //
    // SUB Rd, Rs, Rt:
    //   SUB R2, R2, R1: 0100_0010_0010_0001 = 0x4221
    //
    // CMP Rs, Rt (nzp field ignored on input, nzp=[11:9] set to 000 for CMP)
    //   CMP R2, R1: 0010_0000_0010_0001 = 0x2021
    //
    // MUL Rd, Rs, Rt:
    //   MUL R4, R13, R1: 0101_0100_1101_0001 = 0x54D1
    //
    // STR Rs, Rt (rs=addr, rt=data): opcode=1000, [11:8]=0000
    //   STR R4, R3: 1000_0000_0100_0011 = 0x8043
    //
    // CONST Rd, imm8: opcode=1001
    //   CONST R1, 4: 1001_0001_0000_0100 = 0x9104
    //   CONST R1, 8: 1001_0001_0000_1000 = 0x9108
    //
    // SYNC: 0xA000   RET: 0xF000
    // -------------------------------------------------------------------------

    // -------------------------------------------------------------------------
    // Main test
    // -------------------------------------------------------------------------
    integer pass_count, fail_count;

    initial begin
        $display("====================================================");
        $display("   __syncthreads() HARDWARE BARRIER TEST            ");
        $display("====================================================");
        $display("  %0d threads, %0d warps, %0d threads/warp",
                 NUM_WARPS * THREADS_PER_BLOCK, NUM_WARPS, THREADS_PER_BLOCK);
        $display("  Test: cross-warp producer-consumer via shared mem");
        $display("====================================================");

        // ---- Memory initialisation ----
        for (int i = 0; i < 256; i++) begin
            d_mem[i] = 16'hDEAD; // poison - any un-written slot stays 0xDEAD
            p_mem[i] = 16'h0000; // NOP
        end
        for (int i = 0; i < DATA_MEM_NUM_CHANNELS; i++) begin
            dmem_read_delay[i] = 0;
            latched_read_addr[i] = 0;
        end

        // ---- Load program ----
        //                           opcode  rd    rs    rt / imm8
        p_mem[ 0] = 16'h9104; // CONST R1, 4
        p_mem[ 1] = 16'hC0FF; // STSH  R15, R15       ; shared_mem[tid] = tid
        p_mem[ 2] = 16'hA000; // SYNC                 ; *** ALL THREADS MUST ARRIVE ***
        p_mem[ 3] = 16'h32F1; // ADD   R2, R15, R1    ; R2 = tid + 4
        p_mem[ 4] = 16'h9108; // CONST R1, 8          ; R1 = 8
        p_mem[ 5] = 16'h2021; // CMP   R2, R1         ; is (tid+4) >= 8?
        p_mem[ 6] = 16'h1209; // BRp   9              ; if positive, go subtract
        p_mem[ 7] = 16'hB320; // LDSH  R3, R2         ; R3 = shared_mem[R2]  (no wrap)
        p_mem[ 8] = 16'h1E0A; // BRnzp 10             ; skip subtract path
        p_mem[ 9] = 16'h4221; // SUB   R2, R2, R1     ; R2 = R2 - 8  (wrap)
        p_mem[10] = 16'hB320; // LDSH  R3, R2         ; R3 = shared_mem[R2 after wrap]
        p_mem[11] = 16'h9108; // CONST R1, 8          ; R1 = threads-per-core
        p_mem[12] = 16'h54D1; // MUL   R4, R13, R1    ; R4 = block_id * 8
        p_mem[13] = 16'h344F; // ADD   R4, R4, R15    ; R4 = global thread ID
        p_mem[14] = 16'h8043; // STR   R4, R3         ; d_mem[global_tid] = R3
        p_mem[15] = 16'hF000; // RET

        // ---- Reset sequence ----
        reset = 1; start = 0;
        device_control_write_enable = 0;
        device_control_data = 0;
        #100 reset = 0;
        #50;

        // ---- Program DCR: 8 threads (1 block) ----
        device_control_write_enable = 1;
        device_control_data = 8'd8;   // 8 threads total
        #10 device_control_write_enable = 0;
        #40;

        // ---- Pulse start ----
        start = 1;
        #10 start = 0;

        // ---- Wait for completion or timeout ----
        fork
            begin
                wait (done === 1'b1);
                $display("[%0t] Kernel completed.", $time);
            end
            begin
                #50000;
                $display("[%0t] ERROR: Timeout - done never asserted!", $time);
                $display("  Possible cause: barrier deadlock (not all threads enrolled).");
                $finish;
            end
        join_any

        // ---- Result verification ----
        $display("");
        $display("====================================================");
        $display("  RESULT VERIFICATION");
        $display("====================================================");
        $display("  Each thread reads shared_mem[(tid + 4) %% 8].");
        $display("  Warp 0 (tids 0-3) reads slots written by Warp 1.");
        $display("  Warp 1 (tids 4-7) reads slots written by Warp 0.");
        $display("  A value of 0 instead of the expected slot index");
        $display("  indicates the barrier did NOT hold Warp 0 long");
        $display("  enough to let Warp 1 complete its writes.");
        $display("----------------------------------------------------");

        pass_count = 0;
        fail_count = 0;

        begin : verify
            // Block 0 only (single block, 8 threads, global IDs 0-7)
            // Thread i stores d_mem[i] = shared_mem[(i+4)%8] = (i+4)%8
            int expected_val;
            for (int tid = 0; tid < 8; tid++) begin
                expected_val = (tid + 4) % 8;
                if (d_mem[tid] === expected_val) begin
                    $display("  Thread %0d  d_mem[%0d] = %0d  (expected %0d)  [PASS]",
                             tid, tid, d_mem[tid], expected_val);
                    pass_count = pass_count + 1;
                end else begin
                    $display("  Thread %0d  d_mem[%0d] = %0d  (expected %0d)  [FAIL] *** BARRIER BUG ***",
                             tid, tid, d_mem[tid], expected_val);
                    fail_count = fail_count + 1;
                end
            end
        end

        // ---- Shared memory sanity check ----
        // After the kernel all 8 shared memory slots should hold their writer's tid.
        // We can't read the DUT's shared_mem directly from the TB, so we verify
        // indirectly via the cross-warp reads above.

        $display("----------------------------------------------------");
        $display("  Barrier timing diagnostic:");
        $display("  If Warp 0 (tids 0-3) failed: barrier stalled too early");
        $display("     (Warp 0 ran past SYNC before Warp 1 wrote its slots).");
        $display("  If Warp 1 (tids 4-7) failed: barrier stalled too early");
        $display("     (Warp 1 ran past SYNC before Warp 0 wrote its slots).");
        $display("====================================================");
        $display("  SUMMARY: %0d PASSED, %0d FAILED out of 8 threads",
                 pass_count, fail_count);
        if (fail_count == 0)
            $display("   -- ALL TESTS PASSED - __syncthreads() is CORRECT --  ");
        else
            $display("   FAILURES DETECTED - check scheduler barrier logic ");
        $display("====================================================");

        #20 $finish;
    end

endmodule