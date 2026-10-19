`default_nettype none
`timescale 1ns/1ns

module tb_shader_math;

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
    localparam NUM_WARPS = 1;                

    reg clk; reg reset; reg start; wire done;
    reg device_control_write_enable; reg [7:0] device_control_data;

    wire [PROGRAM_MEM_NUM_CHANNELS-1:0] program_mem_read_valid;
    wire [PROGRAM_MEM_ADDR_BITS-1:0] program_mem_read_address [PROGRAM_MEM_NUM_CHANNELS];
    reg [PROGRAM_MEM_NUM_CHANNELS-1:0] program_mem_read_ready;
    reg [(PROGRAM_MEM_DATA_BITS*4)-1:0] program_mem_read_data [PROGRAM_MEM_NUM_CHANNELS];

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

    // Memory Arrays (Expanded to hold all test operation outputs)
    reg [PROGRAM_MEM_DATA_BITS-1:0] p_mem [0:255];
    reg [DATA_MEM_DATA_BITS-1:0]    d_mem [0:511]; 

    function [31:0] encode_R(input [5:0] op, input [4:0] rd, input [4:0] rs, input [4:0] rt);
        encode_R = {op, rd, rs, rt, 11'd0};
    endfunction

    function [31:0] encode_I(input [5:0] op, input [4:0] rd, input [4:0] rs, input [15:0] imm);
        encode_I = {op, rd, rs, imm};
    endfunction

    localparam OP_ADD = 6'd3, OP_LDR = 6'd7, OP_STR = 6'd8, OP_CONST = 6'd9, OP_MUL = 6'd5, OP_EXIT = 6'd15,
               OP_AND = 6'd17, OP_OR = 6'd18, OP_XOR = 6'd19, OP_SHL = 6'd20, OP_SHR = 6'd21,
               OP_MOD = 6'd22, OP_MIN = 6'd23, OP_MAX = 6'd24, OP_ABS = 6'd25, OP_NEG = 6'd26;

    always @(posedge clk) begin
        for (int i = 0; i < PROGRAM_MEM_NUM_CHANNELS; i++) begin
            program_mem_read_ready[i] <= program_mem_read_valid[i];
            if (program_mem_read_valid[i]) begin
                int word_base = program_mem_read_address[i] * 4;
                program_mem_read_data[i] <= { p_mem[word_base+3], p_mem[word_base+2], p_mem[word_base+1], p_mem[word_base] };
            end
        end
        for (int i = 0; i < DATA_MEM_NUM_CHANNELS; i++) begin
            data_mem_read_ready[i] <= data_mem_read_valid[i];
            if (data_mem_read_valid[i]) begin
                int b = data_mem_read_address[i];
                data_mem_read_data[i] <= {d_mem[b*4+3], d_mem[b*4+2], d_mem[b*4+1], d_mem[b*4+0]};
            end
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
        $display(" PHASE 6: SHADER MATH OPCODES TEST                       ");
        $display("=========================================================");

        for (int i = 0; i < 512; i++) d_mem[i] = 0;
        for (int i = 0; i < 256; i++) p_mem[i] = 0;

        // Input Vector A (Base 0)
        d_mem[0] = 15;           d_mem[1] = -15;          d_mem[2] = 32'hFFFF0000; d_mem[3] = 32'h0000FFFF;
        d_mem[4] = 32'hAAAA5555; d_mem[5] = 100;          d_mem[6] = -100;         d_mem[7] = 0;
        d_mem[8] = 1;            d_mem[9] = -1;           d_mem[10]= 1024;         d_mem[11]= -1024;
        d_mem[12]= 50;           d_mem[13]= 7;            d_mem[14]= -7;           d_mem[15]= 32'h80000000;

        // Input Vector B (Base 16)
        d_mem[16]= 4;            d_mem[17]= 4;            d_mem[18]= 32'h00FF00FF; d_mem[19]= 32'hFF00FF00;
        d_mem[20]= 32'h5555AAAA; d_mem[21]= 33;           d_mem[22]= 33;           d_mem[23]= 10;
        d_mem[24]= 1;            d_mem[25]= 1;            d_mem[26]= 3;            d_mem[27]= 3;
        d_mem[28]= 50;           d_mem[29]= 16;           d_mem[30]= 2;            d_mem[31]= 1;

        // --- GPU ASSEMBLY KERNEL ---

        // Calc Global TID: R0 = R29(BlockID) * 8 + R31(ThreadID)
        p_mem[0]  = encode_I(OP_CONST, 7, 0, 8);            // CONST R7, 8
        p_mem[1]  = encode_R(OP_MUL, 0, 29, 7);             // MUL R0, R29, R7
        p_mem[2]  = encode_R(OP_ADD, 0, 0, 31);             // ADD R0, R0, R31
        
        // Load Input A (R2 = d_mem[0 + TID])
        p_mem[3]  = encode_I(OP_CONST, 1, 0, 0);            // CONST R1, 0
        p_mem[4]  = encode_R(OP_ADD, 1, 1, 0);              // ADD R1, R1, R0
        p_mem[5]  = encode_I(OP_LDR, 2, 1, 0);              // LDR R2, [R1+0]
        
        // Load Input B (R3 = d_mem[16 + TID])
        p_mem[6]  = encode_I(OP_CONST, 1, 0, 16);           // CONST R1, 16
        p_mem[7]  = encode_R(OP_ADD, 1, 1, 0);              // ADD R1, R1, R0
        p_mem[8]  = encode_I(OP_LDR, 3, 1, 0);              // LDR R3, [R1+0]

        // 1. Bitwise AND -> Base 32
        p_mem[9]  = encode_R(OP_AND, 4, 2, 3);
        p_mem[10] = encode_I(OP_CONST, 5, 0, 32);
        p_mem[11] = encode_R(OP_ADD, 5, 5, 0);
        p_mem[12] = encode_I(OP_STR, 4, 5, 0);

        // 2. Bitwise OR -> Base 48
        p_mem[13] = encode_R(OP_OR, 4, 2, 3);
        p_mem[14] = encode_I(OP_CONST, 5, 0, 48);
        p_mem[15] = encode_R(OP_ADD, 5, 5, 0);
        p_mem[16] = encode_I(OP_STR, 4, 5, 0);

        // 3. Bitwise XOR -> Base 64
        p_mem[17] = encode_R(OP_XOR, 4, 2, 3);
        p_mem[18] = encode_I(OP_CONST, 5, 0, 64);
        p_mem[19] = encode_R(OP_ADD, 5, 5, 0);
        p_mem[20] = encode_I(OP_STR, 4, 5, 0);

        // 4. Shift Left -> Base 80
        p_mem[21] = encode_R(OP_SHL, 4, 2, 3);
        p_mem[22] = encode_I(OP_CONST, 5, 0, 80);
        p_mem[23] = encode_R(OP_ADD, 5, 5, 0);
        p_mem[24] = encode_I(OP_STR, 4, 5, 0);

        // 5. Shift Right (Logical) -> Base 96
        p_mem[25] = encode_R(OP_SHR, 4, 2, 3);
        p_mem[26] = encode_I(OP_CONST, 5, 0, 96);
        p_mem[27] = encode_R(OP_ADD, 5, 5, 0);
        p_mem[28] = encode_I(OP_STR, 4, 5, 0);

        // 6. Modulo (Unsigned) -> Base 112
        p_mem[29] = encode_R(OP_MOD, 4, 2, 3);
        p_mem[30] = encode_I(OP_CONST, 5, 0, 112);
        p_mem[31] = encode_R(OP_ADD, 5, 5, 0);
        p_mem[32] = encode_I(OP_STR, 4, 5, 0);

        // 7. Minimum (Signed) -> Base 128
        p_mem[33] = encode_R(OP_MIN, 4, 2, 3);
        p_mem[34] = encode_I(OP_CONST, 5, 0, 128);
        p_mem[35] = encode_R(OP_ADD, 5, 5, 0);
        p_mem[36] = encode_I(OP_STR, 4, 5, 0);

        // 8. Maximum (Signed) -> Base 144
        p_mem[37] = encode_R(OP_MAX, 4, 2, 3);
        p_mem[38] = encode_I(OP_CONST, 5, 0, 144);
        p_mem[39] = encode_R(OP_ADD, 5, 5, 0);
        p_mem[40] = encode_I(OP_STR, 4, 5, 0);

        // 9. Absolute (Signed, Rt ignored) -> Base 160
        p_mem[41] = encode_R(OP_ABS, 4, 2, 0);
        p_mem[42] = encode_I(OP_CONST, 5, 0, 160);
        p_mem[43] = encode_R(OP_ADD, 5, 5, 0);
        p_mem[44] = encode_I(OP_STR, 4, 5, 0);

        // 10. Negate (2s Complement, Rt ignored) -> Base 176
        p_mem[45] = encode_R(OP_NEG, 4, 2, 0);
        p_mem[46] = encode_I(OP_CONST, 5, 0, 176);
        p_mem[47] = encode_R(OP_ADD, 5, 5, 0);
        p_mem[48] = encode_I(OP_STR, 4, 5, 0);

        // 11. EXIT
        p_mem[49] = encode_I(OP_EXIT, 0, 0, 0);

        // -------------------------------------------------------------

        reset = 1; start = 0; device_control_write_enable = 0; device_control_data = 0;
        
        #100 reset = 0; #50;
        device_control_write_enable = 1; device_control_data = 16; // Spawn 16 threads
        #50 device_control_write_enable = 0; #50;
        start = 1; #50 start = 0;

        fork
            begin
                wait (done == 1'b1);
                $display("[%0t] [TESTBENCH] Execution Completed!", $time);
            end
            begin
                #50000; 
                $display("[%0t] [TESTBENCH] ERROR: Timeout waiting for DONE!", $time);
                $finish;
            end
        join_any

        $display("==================================================");
        $display("       VERIFYING SHADER OPCODES RESULTS           ");
        $display("==================================================");
        
        begin
            int errors = 0;
            for (int i = 0; i < 16; i++) begin
                int A = d_mem[i];
                int B = d_mem[16 + i];

                // Calculate Verilog Truth
                int exp_and = A & B;
                int exp_or  = A | B;
                int exp_xor = A ^ B;
                int exp_shl = A << B;
                int exp_shr = $unsigned(A) >> $unsigned(B); // Logical Shift Right
                int exp_mod = $unsigned(A) % $unsigned(B);  // Hardware ALU uses Unsigned Mod
                int exp_min = ($signed(A) < $signed(B)) ? A : B;
                int exp_max = ($signed(A) > $signed(B)) ? A : B;
                int exp_abs = ($signed(A) < 0) ? -$signed(A) : A;
                int exp_neg = -$signed(A);

                // Fetch GPU Results
                int res_and = d_mem[32 + i];
                int res_or  = d_mem[48 + i];
                int res_xor = d_mem[64 + i];
                int res_shl = d_mem[80 + i];
                int res_shr = d_mem[96 + i];
                int res_mod = d_mem[112 + i];
                int res_min = d_mem[128 + i];
                int res_max = d_mem[144 + i];
                int res_abs = d_mem[160 + i];
                int res_neg = d_mem[176 + i];

                // Check everything
                if (res_and != exp_and) begin $display("TID %02d | AND Failed: expected %x, got %x", i, exp_and, res_and); errors++; end
                if (res_or  != exp_or)  begin $display("TID %02d |  OR Failed: expected %x, got %x", i, exp_or, res_or); errors++; end
                if (res_xor != exp_xor) begin $display("TID %02d | XOR Failed: expected %x, got %x", i, exp_xor, res_xor); errors++; end
                if (res_shl != exp_shl) begin $display("TID %02d | SHL Failed: expected %x, got %x", i, exp_shl, res_shl); errors++; end
                if (res_shr != exp_shr) begin $display("TID %02d | SHR Failed: expected %x, got %x", i, exp_shr, res_shr); errors++; end
                if (res_mod != exp_mod) begin $display("TID %02d | MOD Failed: expected %d, got %d", i, exp_mod, res_mod); errors++; end
                if (res_min != exp_min) begin $display("TID %02d | MIN Failed: expected %d, got %d", i, exp_min, res_min); errors++; end
                if (res_max != exp_max) begin $display("TID %02d | MAX Failed: expected %d, got %d", i, exp_max, res_max); errors++; end
                if (res_abs != exp_abs) begin $display("TID %02d | ABS Failed: expected %d, got %d", i, exp_abs, res_abs); errors++; end
                if (res_neg != exp_neg) begin $display("TID %02d | NEG Failed: expected %d, got %d", i, exp_neg, res_neg); errors++; end
            end

            if (errors == 0) $display("\nALL 160 SHADER MATH TESTS PASSED FLAWLESSLY! \n");
            else $display("\nTEST FAILED WITH %0d ERRORS.\n", errors);
        end
        #20 $finish;
    end
endmodule