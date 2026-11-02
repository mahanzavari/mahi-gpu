`default_nettype none
`timescale 1ns/1ns

// =============================================================================
// HAZARD TESTBENCH
//
// Tests every hazard class the pipeline can encounter:
//
//  TEST 1  — ALU→ALU RAW (forwarding, no stall)
//  TEST 2  — Load-use RAW on rs (1-cycle stall inserted)
//  TEST 3  — Load-use RAW on rt (1-cycle stall inserted)
//  TEST 4  — Load then independent instruction then use (forwarding, no stall)
//  TEST 5  — Store after load to same address (ordering)
//  TEST 6  — Branch hazard (flush, correct PC after taken branch)
//  TEST 7  — Multi-warp: warp switch hides load latency (no stall needed)
//  TEST 8  — WAW: two writes to the same register; last write wins
//  TEST 9  — Shared-memory load-use (shared load then immediate use)
//  TEST 10 — CONST then immediate ALU use (CONST is forwarded, no stall)
//
// How to simulate
// ---------------
//   iverilog -g2012 -DSIMULATION \
//     -o hazard_tb \
//     hazard_tb.sv core.sv alu.sv decoder.sv fetcher.sv lsu.sv \
//     pc.sv registers.sv scheduler.sv shared_mem.sv
//   vvp hazard_tb
//
// The testbench instantiates stub memories so it is self-contained.
// Each test prints PASS or FAIL and a final summary is printed at the end.
// =============================================================================

module tb_hazard;

// -- Parameters ---------------------------------------------------------------
localparam DATA_MEM_ADDR_BITS    = 32;
localparam DATA_MEM_DATA_BITS    = 32;
localparam PROGRAM_MEM_ADDR_BITS = 32;
localparam PROGRAM_MEM_DATA_BITS = 32;
localparam THREADS_PER_BLOCK     = 4;
localparam NUM_WARPS             = 1;   // single-warp: forces hazards to surface
localparam SHARED_MEM_SIZE       = 256;
localparam DATA_BITS             = 32;
localparam CLK_HALF              = 5;   // 10 ns period

localparam IMEM_DEPTH = 256;
localparam DMEM_DEPTH = 256;

// -- Clock / reset ------------------------------------------------------------
reg clk = 0;
always #CLK_HALF clk = ~clk;

reg reset;
reg start;

// -- Instruction memory (program ROM) -----------------------------------------
reg [PROGRAM_MEM_DATA_BITS-1:0] imem [0:IMEM_DEPTH-1];

wire                              pmem_rv;
wire [PROGRAM_MEM_ADDR_BITS-1:0] pmem_ra;
reg                               pmem_rr;
reg  [PROGRAM_MEM_DATA_BITS-1:0] pmem_rd_data;

// One-cycle latency model
always @(posedge clk) begin
    pmem_rr      <= pmem_rv;
    pmem_rd_data <= imem[pmem_ra[7:0]];
end

// -- Data memory (read/write) --------------------------------------------------
reg [DATA_MEM_DATA_BITS-1:0] dmem [0:DMEM_DEPTH-1];

wire                               dmem_rv;
wire [DATA_MEM_ADDR_BITS-1:0]      dmem_ra;
reg                                dmem_rr;
reg  [(DATA_MEM_DATA_BITS*4)-1:0]  dmem_rd_data;

wire                               dmem_wv;
wire [DATA_MEM_ADDR_BITS-1:0]      dmem_wa;
wire [(DATA_MEM_DATA_BITS*4)-1:0]  dmem_wd;
wire [3:0]                         dmem_ws;
reg                                dmem_wr;

// One-cycle latency, block-level read/write
// One-cycle latency, block-level read/write
always @(posedge clk) begin
    dmem_rr <= dmem_rv;
    if (dmem_rv) begin
        // Multiply Block address by 4 to get word indices
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

// -- DUT ----------------------------------------------------------------------
wire done;

core #(
    .DATA_MEM_ADDR_BITS    (DATA_MEM_ADDR_BITS),
    .DATA_MEM_DATA_BITS    (DATA_MEM_DATA_BITS),
    .PROGRAM_MEM_ADDR_BITS (PROGRAM_MEM_ADDR_BITS),
    .PROGRAM_MEM_DATA_BITS (PROGRAM_MEM_DATA_BITS),
    .THREADS_PER_BLOCK     (THREADS_PER_BLOCK),
    .NUM_WARPS             (NUM_WARPS),
    .SHARED_MEM_SIZE       (SHARED_MEM_SIZE),
    .DATA_BITS             (DATA_BITS),
    .DEBUG                 (0)
) dut (
    .clk                    (clk),
    .reset                  (reset),
    .start                  (start),
    .done                   (done),
    .block_id               (8'd0),
    .thread_count           (THREADS_PER_BLOCK),

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

// -- Scoreboard / helpers ------------------------------------------------------
integer pass_count = 0;
integer fail_count = 0;
integer test_num   = 0;

// Access the register file of thread 0, warp 0 via hierarchical reference.
// Adjust the path if your hierarchy differs.
`define REG(r) dut.threads[0].reg_inst.registers[0][r]

task automatic check(input string name, input [31:0] got, input [31:0] exp);
    test_num++;
    if (got === exp) begin
        $display("  [PASS] Test %0d: %s  got=0x%08x", test_num, name, got);
        pass_count++;
    end else begin
        $display("  [FAIL] Test %0d: %s  got=0x%08x  expected=0x%08x", test_num, name, got, exp);
        fail_count++;
    end
endtask

// Reset then start the core with a given instruction memory image.
// Waits for done or timeout.
task automatic run_kernel(input int timeout_cycles);
    integer cyc;
    @(posedge clk); #1;
    reset = 1;
    start = 0;
    @(posedge clk); #1;
    @(posedge clk); #1;
    reset = 0;
    @(posedge clk); #1;
    start = 1;
    cyc = 0;
    while (!done && cyc < timeout_cycles) begin
        @(posedge clk); #1;
        cyc++;
    end
    if (cyc >= timeout_cycles)
        $display("  [TIMEOUT] kernel did not complete in %0d cycles", timeout_cycles);
    start = 0;
    @(posedge clk); #1;
endtask

// -- ISA encoding helpers ------------------------------------------------------
// Instruction format: [31:26]=opcode [25:21]=rd [20:16]=rs [15:11]=rt [10:0]=imm/other
localparam OP_NOP   = 6'd0,
           OP_BRnzp = 6'd1,
           OP_CMP   = 6'd2,
           OP_ADD   = 6'd3,
           OP_SUB   = 6'd4,
           OP_MUL   = 6'd5,
           OP_DIV   = 6'd6,
           OP_LDR   = 6'd7,
           OP_STR   = 6'd8,
           OP_CONST = 6'd9,
           OP_SYNC  = 6'd10,
           OP_LDSH  = 6'd11,
           OP_STSH  = 6'd12,
           OP_EXIT  = 6'd15;

// Register aliases
localparam R0=0, R1=1, R2=2, R3=3, R4=4, R5=5;
localparam R_BLOCK=29, R_WSIZE=30, R_THREAD=31;

function automatic [31:0] enc_nop();
    return {OP_NOP, 26'b0};
endfunction
function automatic [31:0] enc_exit();
    return {OP_EXIT, 26'b0};
endfunction
function automatic [31:0] enc_const(input [4:0] rd, input [15:0] imm);
    return {OP_CONST, rd, 5'b0, imm};
endfunction
function automatic [31:0] enc_add(input [4:0] rd, input [4:0] rs, input [4:0] rt);
    return {OP_ADD, rd, rs, rt, 11'b0};
endfunction
function automatic [31:0] enc_sub(input [4:0] rd, input [4:0] rs, input [4:0] rt);
    return {OP_SUB, rd, rs, rt, 11'b0};
endfunction
function automatic [31:0] enc_mul(input [4:0] rd, input [4:0] rs, input [4:0] rt);
    return {OP_MUL, rd, rs, rt, 11'b0};
endfunction
function automatic [31:0] enc_ldr(input [4:0] rd, input [4:0] rs, input [15:0] offset);
    // LDR rd, [rs + offset]
    return {OP_LDR, rd, rs, offset};
endfunction
function automatic [31:0] enc_str(input [4:0] rs_addr, input [4:0] rd_data, input [15:0] offset);
    // STR [rs_addr + offset], rd_data  (decoder routes rd field as data source)
    return {OP_STR, rd_data, rs_addr, offset};
endfunction
function automatic [31:0] enc_cmp(input [4:0] rs, input [4:0] rt);
    return {OP_CMP, 5'b0, rs, rt, 11'b0};
endfunction
function automatic [31:0] enc_br(input [2:0] nzp, input [15:0] target);
    return {OP_BRnzp, nzp, 7'b0, target};
endfunction
function automatic [31:0] enc_ldsh(input [4:0] rd, input [4:0] rs);
    return {OP_LDSH, rd, rs, 16'b0};
endfunction
function automatic [31:0] enc_stsh(input [4:0] rs_addr, input [4:0] rd_data);
    return {OP_STSH, rd_data, rs_addr, 16'b0};
endfunction
function automatic [31:0] enc_atom_add(input [4:0] rd, input [4:0] rs, input [4:0] rt);
    return {6'd16, rd, rs, rt, 11'd0};
endfunction

// -- Zero all memories --------------------------------------------------------
task automatic clear_memories();
    integer k;
    for (k = 0; k < IMEM_DEPTH; k++) imem[k] = enc_nop();
    for (k = 0; k < DMEM_DEPTH; k++) dmem[k] = 0;
endtask

// =============================================================================
// TESTS
// =============================================================================
initial begin
    $dumpfile("tb_hazard.vcd");
    $dumpvars(0, tb_hazard);

    $display("\n============================================================");
    $display(" GPU Pipeline Hazard Testbench");
    $display("============================================================\n");

    // -------------------------------------------------------------------------
    // TEST 1: ALU→ALU RAW — forwarding should handle this with zero stalls.
    //   CONST R1, 5
    //   CONST R2, 3
    //   ADD   R3, R1, R2   ; R3 = 8  (forwarded from CONST writeback)
    //   ADD   R4, R3, R1   ; R4 = 13 (forwarded from ADD writeback)
    //   EXIT
    // -------------------------------------------------------------------------
    $display("[TEST 1] ALU->ALU RAW forwarding (no stall expected)");
    clear_memories();
    imem[0] = enc_const(R1, 16'd5);
    imem[1] = enc_const(R2, 16'd3);
    imem[2] = enc_add(R3, R1, R2);
    imem[3] = enc_add(R4, R3, R1);
    imem[4] = enc_exit();
    for (int p = 5; p < IMEM_DEPTH; p++) imem[p] = enc_exit();
    run_kernel(200);
    check("T1: R3 = R1+R2 = 8",  `REG(R3), 32'd8);
    check("T1: R4 = R3+R1 = 13", `REG(R4), 32'd13);

    // -------------------------------------------------------------------------
    // TEST 2: Load-use RAW on rs — one stall bubble must be inserted.
    //   CONST R0, 10        ; memory base address
    //   store 42 to dmem[10] directly (via dmem array, bypassing pipeline)
    //   LDR  R1, R0, 0      ; R1 = mem[10] = 42
    //   ADD  R2, R1, R1     ; R2 = R1 + R1 = 84  �? R1 depends on LDR above
    //   EXIT
    // -------------------------------------------------------------------------
    $display("\n[TEST 2] Load-use RAW on rs (1 stall expected)");
    clear_memories();
    dmem[10] = 32'd42;
    imem[0] = enc_const(R0, 16'd10);
    imem[1] = enc_ldr(R1, R0, 16'd0);
    imem[2] = enc_add(R2, R1, R1);     // R1 not yet written — hazard fires
    imem[3] = enc_exit();
    for (int p = 4; p < IMEM_DEPTH; p++) imem[p] = enc_exit();
    run_kernel(300);
    check("T2: R1 = mem[10] = 42", `REG(R1), 32'd42);
    check("T2: R2 = 84",           `REG(R2), 32'd84);

    // -------------------------------------------------------------------------
    // TEST 3: Load-use RAW on rt — stall must also fire for the rt port.
    //   dmem[20] = 7
    //   CONST R0, 20
    //   LDR  R1, R0, 0    ; R1 = 7
    //   MUL  R2, R3, R1   ; R2 = 0 * 7 = 0 (R3=0 by reset, R1 forwarded via stall)
    //   EXIT
    // -------------------------------------------------------------------------
    $display("\n[TEST 3] Load-use RAW on rt (1 stall expected)");
    clear_memories();
    dmem[20] = 32'd7;
    imem[0] = enc_const(R0, 16'd20);
    imem[1] = enc_ldr(R1, R0, 16'd0);
    imem[2] = enc_mul(R2, R3, R1);     // rt=R1 is the hazard source
    imem[3] = enc_exit();
    for (int p = 4; p < IMEM_DEPTH; p++) imem[p] = enc_exit();
    run_kernel(300);
    check("T3: R1 = 7",   `REG(R1), 32'd7);
    check("T3: R2 = 0",   `REG(R2), 32'd0);  // R3 == 0 after reset

    // -------------------------------------------------------------------------
    // TEST 4: Load → independent instruction → use (no stall, forwarding).
    //   dmem[30] = 100
    //   CONST R0, 30
    //   LDR  R1, R0, 0       ; R1 = 100
    //   CONST R5, 1          ; independent — gives load time to complete
    //   ADD  R2, R1, R5      ; R2 = 101 — forwarded, no stall needed
    //   EXIT
    // -------------------------------------------------------------------------
    $display("\n[TEST 4] Load + independent gap + use (forwarding, no stall)");
    clear_memories();
    dmem[30] = 32'd100;
    imem[0] = enc_const(R0, 16'd30);
    imem[1] = enc_ldr(R1, R0, 16'd0);
    imem[2] = enc_const(R5, 16'd1);    // one independent instruction gap
    imem[3] = enc_add(R2, R1, R5);
    imem[4] = enc_exit();
    for (int p = 5; p < IMEM_DEPTH; p++) imem[p] = enc_exit();
    run_kernel(300);
    check("T4: R1 = 100", `REG(R1), 32'd100);
    check("T4: R2 = 101", `REG(R2), 32'd101);

    // -------------------------------------------------------------------------
    // TEST 5: Store after load to the same address — ordering check.
    //   dmem[40] = 55
    //   CONST R0, 40
    //   LDR  R1, R0, 0     ; R1 = 55
    //   CONST R2, 99
    //   STR  R0, R2, 0     ; dmem[40] = 99
    //   LDR  R3, R0, 0     ; R3 = 99  (reads back the store)
    //   EXIT
    // -------------------------------------------------------------------------
    $display("\n[TEST 5] Store after load (ordering / memory consistency)");
    clear_memories();
    dmem[40] = 32'd55;
    imem[0] = enc_const(R0, 16'd40);
    imem[1] = enc_ldr(R1, R0, 16'd0);
    imem[2] = enc_const(R2, 16'd99);
    imem[3] = enc_str(R0, R2, 16'd0);
    imem[4] = enc_ldr(R3, R0, 16'd0);
    imem[5] = enc_exit();
    for (int p = 6; p < IMEM_DEPTH; p++) imem[p] = enc_exit();
    run_kernel(400);
    check("T5: R1 = 55",   `REG(R1), 32'd55);
    check("T5: R3 = 99",   `REG(R3), 32'd99);

    // -------------------------------------------------------------------------
    // TEST 6: Branch hazard — pipeline must flush and land at correct PC.
    //   CONST R1, 10
    //   CONST R2, 10
    //   CMP   R1, R2        ; sets NZP = 010 (equal)
    //   BRnzp 010, 8        ; branch if equal → jump to addr 7
    //   CONST R3, 0xDEAD    ; should be flushed (never executed)
    //   CONST R3, 0xDEAD
    //   CONST R3, 0xDEAD
    //   CONST R4, 0xBEEF    ; branch target — should execute
    //   EXIT
    // -------------------------------------------------------------------------
    $display("\n[TEST 6] Branch hazard (flush + correct PC)");
    clear_memories();
    imem[0] = enc_const(R1, 16'd10);
    imem[1] = enc_const(R2, 16'd10);
    imem[2] = enc_cmp(R1, R2);
    imem[3] = enc_br(3'b010, 16'd7);  // branch to addr 7 when equal (NZP bit 1)
    imem[4] = enc_const(R3, 16'hDEAD); // must NOT execute
    imem[5] = enc_const(R3, 16'hDEAD);
    imem[6] = enc_const(R3, 16'hDEAD);
    imem[7] = enc_const(R4, 16'hBEEF); // branch target
    imem[8] = enc_exit();
    for (int p = 9; p < IMEM_DEPTH; p++) imem[p] = enc_exit();
    run_kernel(400);
    check("T6: R3 != 0xDEAD (branch flushed)", `REG(R3), 32'd0);
    check("T6: R4 = 0xBEEF (branch target)",   `REG(R4), 32'hFFFFBEEF);

    // -------------------------------------------------------------------------
    // TEST 7: Multi-warp latency hiding.
    //   With NUM_WARPS > 1 this would interleave warps. With NUM_WARPS=1 the
    //   stall still fires but we verify the result is correct regardless.
    //   The test specifically checks that the value written into R2 is the
    //   freshly loaded one, not a stale pre-load value of 0.
    //
    //   dmem[50] = 77
    //   CONST R0, 50
    //   LDR  R1, R0, 0    ; R1 = 77
    //   ADD  R2, R1, R1   ; R2 = 154 (stall in single-warp mode)
    //   EXIT
    // -------------------------------------------------------------------------
    $display("\n[TEST 7] Load-use correctness (result not stale zero)");
    clear_memories();
    dmem[50] = 32'd77;
    imem[0] = enc_const(R0, 16'd50);
    imem[1] = enc_ldr(R1, R0, 16'd0);
    imem[2] = enc_add(R2, R1, R1);
    imem[3] = enc_exit();
    for (int p = 4; p < IMEM_DEPTH; p++) imem[p] = enc_exit();
    run_kernel(300);
    check("T7: R2 = 154 (not stale 0)", `REG(R2), 32'd154);

    // -------------------------------------------------------------------------
    // TEST 8: WAW — two writes to R1; second write must win.
    //   CONST R1, 11
    //   CONST R1, 22       ; overwrites — R1 should end up as 22
    //   EXIT
    // -------------------------------------------------------------------------
    $display("\n[TEST 8] WAW - second write wins");
    clear_memories();
    imem[0] = enc_const(R1, 16'd11);
    imem[1] = enc_const(R1, 16'd22);
    imem[2] = enc_exit();
    for (int p = 3; p < IMEM_DEPTH; p++) imem[p] = enc_exit();
    run_kernel(200);
    check("T8: R1 = 22 (last write wins)", `REG(R1), 32'd22);

    // -------------------------------------------------------------------------
    // TEST 9: Shared-memory load-use.
    //   Pre-load shared mem address 0 with value 33 via direct array access.
    //   CONST R0, 0
    //   LDSH  R1, R0       ; R1 = shared[0] = 33
    //   ADD   R2, R1, R1   ; R2 = 66 — must stall until LDSH completes
    //   EXIT
    // -------------------------------------------------------------------------
    $display("\n[TEST 9] Shared-memory load-use hazard");
    clear_memories();
    // Pre-initialize shared memory by writing through the data path before run.
    // We do this by placing STSH at the start and pre-seeding with CONST.
    // Simpler: write directly to the shared_mem array after reset using $deposit
    // or a pre-run STSH sequence.
    imem[0] = enc_const(R0, 16'd0);     // address 0
    imem[1] = enc_const(R2, 16'd33);    // value to store
    imem[2] = enc_stsh(R0, R2);         // shared[0] = 33
    imem[3] = enc_ldsh(R1, R0);         // R1 = shared[0]
    imem[4] = enc_add(R3, R1, R1);      // R3 = 66
    imem[5] = enc_exit();
    for (int p = 6; p < IMEM_DEPTH; p++) imem[p] = enc_exit();
    run_kernel(400);
    check("T9: R1 = 33", `REG(R1), 32'd33);
    check("T9: R3 = 66", `REG(R3), 32'd66);

    // -------------------------------------------------------------------------
    // TEST 10: CONST → immediate ALU use (CONST writeback forwarded, no stall).
    //   CONST R1, 200
    //   SUB   R2, R1, R1   ; R2 = 0 — forwarded from CONST
    //   ADD   R3, R2, R1   ; R3 = 200 — forwarded from CONST and from SUB
    //   EXIT
    // -------------------------------------------------------------------------
    $display("\n[TEST 10] CONST->ALU forwarding chain (no stall)");
    clear_memories();
    imem[0] = enc_const(R1, 16'd200);
    imem[1] = enc_sub(R2, R1, R1);
    imem[2] = enc_add(R3, R2, R1);
    imem[3] = enc_exit();
    for (int p = 4; p < IMEM_DEPTH; p++) imem[p] = enc_exit();
    run_kernel(200);
    check("T10: R2 = 0",   `REG(R2), 32'd0);
    check("T10: R3 = 200", `REG(R3), 32'd200);

    $display("\n[TEST] Intra-Warp Atomic Add Conflict");
    clear_memories();
    dmem[100] = 32'd0; // Initialize sum to 0

    imem[0] = enc_const(1, 16'd100);     // R1 = 100 (Address)
    imem[1] = enc_const(2, 16'd1);       // R2 = 1 (Amount to add)
    imem[2] = enc_atom_add(3, 1, 2);     // ATOM_ADD R3, [R1], R2  <-- Removed the 0 offset
    imem[3] = enc_exit();

    run_kernel(400);
    if (dmem[100] === 32'd4)
        $display("  [PASS] Atomic Sum Correct! Expected 4, got %0d", dmem[100]);
    else
        $display("  [FAIL] Atomic Sum Failed. Expected 4, got %0d", dmem[100]);

    // -------------------------------------------------------------------------
    // Summary
    // -------------------------------------------------------------------------
    $display("\n============================================================");
    $display(" Results: %0d / %0d tests passed", pass_count, pass_count + fail_count);
    if (fail_count == 0)
        $display(" ALL PASS");
    else
        $display(" %0d FAILED", fail_count);
    $display("============================================================\n");

    $finish;
end

// -- Timeout watchdog ---------------------------------------------------------
initial begin
    #500_000;
    $display("[WATCHDOG] Simulation exceeded 500000 ns — forcing exit.");
    $finish;
end

endmodule