`default_nettype none
`timescale 1ns/1ns

module tb_matmul;

    localparam DATA_MEM_ADDR_BITS = 32;
    localparam DATA_MEM_DATA_BITS = 32;
    localparam PROGRAM_MEM_ADDR_BITS = 32;
    localparam PROGRAM_MEM_DATA_BITS = 32;
    
    localparam WORDS_PER_BLOCK = 4;
    localparam BLOCK_DATA_BITS = DATA_MEM_DATA_BITS * WORDS_PER_BLOCK; 
    
    localparam DATA_MEM_NUM_CHANNELS = 2; // 2 Cores
    localparam PROGRAM_MEM_NUM_CHANNELS = 2; 
    localparam NUM_CORES = 2; 
    localparam THREADS_PER_BLOCK = 8;        
    localparam NUM_WARPS = 2;                

    reg clk; reg reset; reg start; wire done;
    reg device_control_write_enable; reg [7:0] device_control_data;

    wire [PROGRAM_MEM_NUM_CHANNELS-1:0] program_mem_read_valid;
    wire [PROGRAM_MEM_ADDR_BITS-1:0] program_mem_read_address [PROGRAM_MEM_NUM_CHANNELS];
    reg [PROGRAM_MEM_NUM_CHANNELS-1:0] program_mem_read_ready;
    reg [PROGRAM_MEM_DATA_BITS-1:0] program_mem_read_data [PROGRAM_MEM_NUM_CHANNELS];

    wire [DATA_MEM_NUM_CHANNELS-1:0] data_mem_read_valid;
    wire [DATA_MEM_ADDR_BITS-1:0] data_mem_read_address [DATA_MEM_NUM_CHANNELS];
    reg [DATA_MEM_NUM_CHANNELS-1:0] data_mem_read_ready;
    reg [BLOCK_DATA_BITS-1:0] data_mem_read_data [DATA_MEM_NUM_CHANNELS];
    
    wire [DATA_MEM_NUM_CHANNELS-1:0] data_mem_write_valid;
    wire [DATA_MEM_ADDR_BITS-1:0] data_mem_write_address [DATA_MEM_NUM_CHANNELS];
    wire [BLOCK_DATA_BITS-1:0] data_mem_write_data [DATA_MEM_NUM_CHANNELS];
    wire [3:0] data_mem_write_strobe [DATA_MEM_NUM_CHANNELS];
    reg [DATA_MEM_NUM_CHANNELS-1:0] data_mem_write_ready;

    gpu #(
        .DATA_MEM_ADDR_BITS(DATA_MEM_ADDR_BITS), .DATA_MEM_DATA_BITS(DATA_MEM_DATA_BITS),
        .DATA_MEM_NUM_CHANNELS(DATA_MEM_NUM_CHANNELS), .PROGRAM_MEM_ADDR_BITS(PROGRAM_MEM_ADDR_BITS),
        .PROGRAM_MEM_DATA_BITS(PROGRAM_MEM_DATA_BITS), .PROGRAM_MEM_NUM_CHANNELS(PROGRAM_MEM_NUM_CHANNELS),
        .NUM_CORES(NUM_CORES), .THREADS_PER_BLOCK(THREADS_PER_BLOCK), .NUM_WARPS(NUM_WARPS)
    ) dut (
        .clk(clk), .reset(reset), .start(start), .done(done),
        .device_control_write_enable(device_control_write_enable),
        .device_control_data(device_control_data),
        
        .program_mem_read_valid(program_mem_read_valid), .program_mem_read_address(program_mem_read_address),
        .program_mem_read_ready(program_mem_read_ready), .program_mem_read_data(program_mem_read_data),
        
        .data_mem_read_valid(data_mem_read_valid), .data_mem_read_address(data_mem_read_address),
        .data_mem_read_ready(data_mem_read_ready), .data_mem_read_data(data_mem_read_data),
        
        .data_mem_write_valid(data_mem_write_valid), .data_mem_write_address(data_mem_write_address),
        .data_mem_write_data(data_mem_write_data), .data_mem_write_strobe(data_mem_write_strobe), .data_mem_write_ready(data_mem_write_ready)
    );

    reg [PROGRAM_MEM_DATA_BITS-1:0] p_mem [0:255];
    reg [DATA_MEM_DATA_BITS-1:0]    d_mem [0:255]; 

    function [31:0] encode_R(input [5:0] op, input [4:0] rd, input [4:0] rs, input [4:0] rt);
        encode_R = {op, rd, rs, rt, 11'd0};
    endfunction

    function [31:0] encode_I(input [5:0] op, input [4:0] rd, input [4:0] rs, input [15:0] imm);
        encode_I = {op, rd, rs, imm};
    endfunction

    function [31:0] encode_BR(input [2:0] nzp, input [15:0] imm);
        encode_BR = {6'd1, nzp, 2'b00, 5'd0, imm}; 
    endfunction

    localparam OP_BRNZP = 6'd1, OP_CMP = 6'd2, OP_ADD = 6'd3, OP_SUB = 6'd4,
               OP_MUL = 6'd5, OP_DIV = 6'd6, OP_LDR = 6'd7, OP_STR = 6'd8,
               OP_CONST = 6'd9, OP_CALL = 6'd13, OP_RET_FN = 6'd14, OP_EXIT = 6'd15;

    always @(posedge clk) begin
        for (int i = 0; i < PROGRAM_MEM_NUM_CHANNELS; i++) begin
            program_mem_read_ready[i] <= program_mem_read_valid[i];
            if (program_mem_read_valid[i]) program_mem_read_data[i] <= p_mem[program_mem_read_address[i]];
        end
        
        for (int i = 0; i < DATA_MEM_NUM_CHANNELS; i++) begin
            // FIX: PACK 128-BIT BLOCK (4 x 32-bit words)
            data_mem_read_ready[i] <= data_mem_read_valid[i];
            if (data_mem_read_valid[i]) begin
                int b = data_mem_read_address[i];
                data_mem_read_data[i] <= {d_mem[b*4+3], d_mem[b*4+2], d_mem[b*4+1], d_mem[b*4+0]};
            end
            
            // FIX: UNPACK AND STROBE 128-BIT WRITE
            data_mem_write_ready[i] <= data_mem_write_valid[i];
            if (data_mem_write_valid[i]) begin
                int b = data_mem_write_address[i];
                if (data_mem_write_strobe[i][0]) d_mem[b*4+0] <= data_mem_write_data[i][31:0];
                if (data_mem_write_strobe[i][1]) d_mem[b*4+1] <= data_mem_write_data[i][63:32];
                if (data_mem_write_strobe[i][2]) d_mem[b*4+2] <= data_mem_write_data[i][95:64];
                if (data_mem_write_strobe[i][3]) d_mem[b*4+3] <= data_mem_write_data[i][127:96];
            end
        end
    end

    initial begin
        clk = 0; forever #5 clk = ~clk; 
    end

    initial begin
        $display("=========================================================");
        $display(" PHASE 5: MATMUL (32-BIT RISC ARCHITECTURE)              ");
        $display("=========================================================");

        for (int i = 0; i < 256; i++) begin
            d_mem[i] = 0;
            p_mem[i] = 0;
        end

        d_mem[0] = 1; d_mem[6] = 1; d_mem[12] = 1; d_mem[18] = 1; d_mem[24] = 1;
        for (int i = 0; i < 25; i++) d_mem[25 + i] = i; 

        // Calc Global TID: R0 = R29(BlockID) * 16 + R31(ThreadID)
        p_mem[0]  = encode_I(OP_CONST, 7, 0, 16);           // CONST R7, 16
        p_mem[1]  = encode_R(OP_MUL, 0, 29, 7);             // MUL R0, R29, R7
        p_mem[2]  = encode_R(OP_ADD, 0, 0, 31);             // ADD R0, R0, R31
        
        // Bounds check: if (R0 < 25) branch to MAIN_BODY(7), else EXIT
        p_mem[3]  = encode_I(OP_CONST, 1, 0, 25);           // CONST R1, 25
        p_mem[4]  = encode_R(OP_CMP, 0, 0, 1);              // CMP R0, R1
        p_mem[5]  = encode_BR(3'b100, 7);                   // BRn 07
        p_mem[6]  = encode_I(OP_EXIT, 0, 0, 0);             // EXIT
        
        // MAIN_BODY: Row = R0 / 5
        p_mem[7]  = encode_I(OP_CONST, 4, 0, 5);            // CONST R4, 5
        p_mem[8]  = encode_R(OP_DIV, 2, 0, 4);              // DIV R2, R0, R4
        
        // Col = R0 - Row * 5
        p_mem[9]  = encode_R(OP_MUL, 3, 2, 4);              // MUL R3, R2, R4
        p_mem[10] = encode_R(OP_SUB, 3, 0, 3);              // SUB R3, R0, R3

        // Function Call: R5 = DotProduct(Row, Col)
        p_mem[11] = encode_I(OP_CALL, 0, 0, 16);            // CALL 16

        // Store Result: C[R0] = R5
        p_mem[12] = encode_I(OP_CONST, 7, 0, 50);           // CONST R7, 50
        p_mem[13] = encode_R(OP_ADD, 7, 7, 0);              // ADD R7, R7, R0
        p_mem[14] = encode_I(OP_STR, 5, 7, 0);              // STR [R7+0], R5 (Rs=Base, Rd=Data, Imm=Offset)
        p_mem[15] = encode_I(OP_EXIT, 0, 0, 0);             // EXIT

        // --- SUBROUTINE: DOT_PROD (PC = 16) ---
        p_mem[16] = encode_I(OP_CONST, 5, 0, 0);            // CONST R5, 0
        p_mem[17] = encode_I(OP_CONST, 6, 0, 0);            // CONST R6, 0

        // LOOP_START (PC = 18)
        p_mem[18] = encode_R(OP_CMP, 0, 6, 4);              // CMP R6, R4
        p_mem[19] = encode_BR(3'b100, 21);                  // BRn 21
        p_mem[20] = encode_I(OP_RET_FN, 0, 0, 0);           // RET_FN

        // LOOP_BODY (PC = 21) -> A_addr = Base_A(0) + Row * 5 + k
        p_mem[21] = encode_R(OP_MUL, 8, 2, 4);              // MUL R8, R2, R4
        p_mem[22] = encode_R(OP_ADD, 8, 8, 6);              // ADD R8, R8, R6
        
        // B_addr = Base_B(25) + k * 5 + Col
        p_mem[23] = encode_I(OP_CONST, 7, 0, 25);           // CONST R7, 25
        p_mem[24] = encode_R(OP_MUL, 9, 6, 4);              // MUL R9, R6, R4
        p_mem[25] = encode_R(OP_ADD, 9, 9, 7);              // ADD R9, R9, R7
        p_mem[26] = encode_R(OP_ADD, 9, 9, 3);              // ADD R9, R9, R3

        // Load Values
        p_mem[27] = encode_I(OP_LDR, 8, 8, 0);              // LDR R8, [R8+0]
        p_mem[28] = encode_I(OP_LDR, 9, 9, 0);              // LDR R9, [R9+0]

        // Result += A_val * B_val
        p_mem[29] = encode_R(OP_MUL, 10, 8, 9);             // MUL R10, R8, R9
        p_mem[30] = encode_R(OP_ADD, 5, 5, 10);             // ADD R5, R5, R10

        // k++
        p_mem[31] = encode_I(OP_CONST, 7, 0, 1);            // CONST R7, 1
        p_mem[32] = encode_R(OP_ADD, 6, 6, 7);              // ADD R6, R6, R7
        p_mem[33] = encode_BR(3'b111, 18);                  // BRnzp 18

        reset = 1; start = 0; device_control_write_enable = 0; device_control_data = 0;
        
        #100 reset = 0; #50;
        device_control_write_enable = 1; device_control_data = 32; 
        #50 device_control_write_enable = 0; #50;
        start = 1; #50 start = 0;

        fork
            begin
                wait (done == 1'b1);
                $display("[%0t] [TESTBENCH] Execution Completed!", $time);
            end
            begin
                #100000; 
                $display("[%0t] [TESTBENCH] ERROR: Timeout waiting for DONE! You likely have a divergence deadlock.", $time);
                $finish;
            end
        join_any

        $display("==================================================");
        $display("   VERIFYING 5x5 MATRIX MULTIPLICATION RESULTS    ");
        $display("==================================================");
        
        begin
            int errors = 0;
            for (int i = 0; i < 25; i++) begin
                int expected_val = i;
                if (d_mem[50 + i] == expected_val) $display("Matrix C Element %02d (Computed by Thread %02d): %02d [PASS]", i, i, d_mem[50+i]);
                else begin
                    $display("Matrix C Element %02d (Computed by Thread %02d): %02d ... EXPECTED %02d [FAIL]", i, i, d_mem[50+i], expected_val);
                    errors++;
                end
            end
            for (int i = 25; i < 32; i++) begin
                if (d_mem[50 + i] == 0) $display("Diverged Thread %02d Memory Space Untouched [PASS]", i);
                else begin
                    $display("Diverged Thread %02d Unexpectedly modified memory to %0d [FAIL]", i, d_mem[50+i]);
                    errors++;
                end
            end
            if (errors == 0) $display("\nMATMUL DIVERGENCE AND CALL/RET STACK TESTS PASSED!");
            else $display("\nTEST FAILED WITH %0d ERRORS.", errors);
        end
        #20 $finish;
    end
endmodule