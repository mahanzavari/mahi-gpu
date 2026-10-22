`default_nettype none
`timescale 1ns/1ns

module tb_mac_cas;

    localparam DATA_MEM_ADDR_BITS = 32;
    localparam DATA_MEM_DATA_BITS = 32;
    localparam PROGRAM_MEM_ADDR_BITS = 32;
    localparam PROGRAM_MEM_DATA_BITS = 32;
    localparam WORDS_PER_BLOCK = 4;
    localparam BLOCK_DATA_BITS = DATA_MEM_DATA_BITS * WORDS_PER_BLOCK; 
    
    localparam DATA_MEM_NUM_CHANNELS = 1; 
    localparam PROGRAM_MEM_NUM_CHANNELS = 1; 
    localparam NUM_CORES = 1; 
    localparam THREADS_PER_BLOCK = 2; // Testing 2 threads battling over CAS     
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

    reg [PROGRAM_MEM_DATA_BITS-1:0] p_mem [0:255];
    reg [DATA_MEM_DATA_BITS-1:0]    d_mem [0:511]; 

    function [31:0] encode_R(input [5:0] op, input [4:0] rd, input [4:0] rs, input [4:0] rt);
        encode_R = {op, rd, rs, rt, 11'd0};
    endfunction

    function [31:0] encode_I(input [5:0] op, input [4:0] rd, input [4:0] rs, input [15:0] imm);
        encode_I = {op, rd, rs, imm};
    endfunction

    localparam OP_ADD = 6'd3, OP_STR = 6'd8, OP_CONST = 6'd9, OP_MUL = 6'd5, OP_EXIT = 6'd15, OP_MAC = 6'd27, OP_ATOM_CAS = 6'd28;

    always @(posedge clk) begin
        for (int i = 0; i < PROGRAM_MEM_NUM_CHANNELS; i++) begin
            program_mem_read_ready[i] <= program_mem_read_valid[i];
            if (program_mem_read_valid[i]) begin
                automatic int word_base = program_mem_read_address[i] * 4;
                program_mem_read_data[i] <= { p_mem[word_base+3], p_mem[word_base+2], p_mem[word_base+1], p_mem[word_base] };
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
        $display(" TESTBENCH: MAC INSTRUCTION AND COMPARE-AND-SWAP         ");
        $display("=========================================================");

        for (int i = 0; i < 512; i++) d_mem[i] = 0;
        for (int i = 0; i < 256; i++) p_mem[i] = 0;

        // Calc TID
        p_mem[0]  = encode_I(OP_CONST, 7, 0, 16);           // CONST R7, 16
        p_mem[1]  = encode_R(OP_MUL, 0, 29, 7);             // MUL R0, R29, R7
        p_mem[2]  = encode_R(OP_ADD, 0, 0, 31);             // ADD R0, R0, R31  (R0 = TID)

        // =====================
        // TEST 1: MAC
        // =====================
        p_mem[3]  = encode_I(OP_CONST, 1, 0, 10);           // rs = 10
        p_mem[4]  = encode_I(OP_CONST, 2, 0, 20);           // rt = 20
        p_mem[5]  = encode_I(OP_CONST, 3, 0, 5);            // rd = 5 (Accumulator)
        
        // MAC R3, R1, R2 -> R3 = 5 + (10 * 20) = 205
        p_mem[6]  = encode_R(OP_MAC, 3, 1, 2);              

        // Store MAC result to memory [200 + TID]
        p_mem[7]  = encode_I(OP_CONST, 7, 0, 200);
        p_mem[8]  = encode_R(OP_ADD, 7, 7, 0);
        p_mem[9]  = encode_I(OP_STR, 3, 7, 0);              // Mem[200 + TID] = 205

        // =====================
        // TEST 2: CAS
        // =====================
        // Both threads (TID 0 and TID 1) will race to Compare and Swap address 300.
        // The expected value is 0. They will try to put in their TID+1.
        p_mem[10] = encode_I(OP_CONST, 1, 0, 300);          // rs = Addr (300)
        p_mem[11] = encode_I(OP_CONST, 2, 0, 0);            // rd = Expected Value (0)
        
        // New Value = TID + 1
        p_mem[12] = encode_I(OP_CONST, 6, 0, 1);
        p_mem[13] = encode_R(OP_ADD, 3, 0, 6);              // rt = New Value (R0+1)
        
        // Execute Atomic Compare and Swap
        // R2 = ATOM_CAS(ADDR=R1, EXPECT=R2, NEW=R3)
        p_mem[14] = encode_R(OP_ATOM_CAS, 2, 1, 3);
        
        // Store the returned old value into [400 + TID]
        p_mem[15] = encode_I(OP_CONST, 7, 0, 400);
        p_mem[16] = encode_R(OP_ADD, 7, 7, 0);
        p_mem[17] = encode_I(OP_STR, 2, 7, 0);              // Mem[400 + TID] = old_val

        // Exit
        p_mem[18] = encode_I(OP_EXIT, 0, 0, 0);

        // -------------------------------------------------------------

        reset = 1; start = 0; device_control_write_enable = 0; device_control_data = 0;
        
        #100 reset = 0; #50;
        device_control_write_enable = 1; device_control_data = 2; // Spawn 2 threads
        #50 device_control_write_enable = 0; #50;
        start = 1; #50 start = 0;

        fork
            begin
                wait (done == 1'b1);
                $display("[%0t] [TESTBENCH] Execution Completed!", $time);
            end
            begin
                #20000; 
                $display("[%0t] [TESTBENCH] ERROR: Timeout!", $time);
                $finish;
            end
        join_any

        $display("\n==================================================");
        $display("               VERIFYING RESULTS                  ");
        $display("==================================================");
        
        begin
            automatic int errors = 0;
            automatic int val_at_300 = 0; 
            automatic int old_val_t0 = 0;
            automatic int old_val_t1 = 0;

            // Check MAC Results
            if (d_mem[200] == 205) $display("MAC Thread 0 Output: 205 [PASS]");
            else begin $display("MAC Thread 0 Output: %0d ... EXPECTED 205 [FAIL]", d_mem[200]); errors++; end
            
            if (d_mem[201] == 205) $display("MAC Thread 1 Output: 205 [PASS]");
            else begin $display("MAC Thread 1 Output: %0d ... EXPECTED 205 [FAIL]", d_mem[201]); errors++; end

            // Check ATOMIC CAS Results
            val_at_300 = d_mem[300];
            $display("CAS Final Memory [300]: %0d", val_at_300);
            
            old_val_t0 = d_mem[400];
            old_val_t1 = d_mem[401];

            $display("CAS Thread 0 Returned Old Val: %0d", old_val_t0);
            $display("CAS Thread 1 Returned Old Val: %0d", old_val_t1);

            // Validating Atomicity Semantics
            if (val_at_300 == 1 || val_at_300 == 2) $display("CAS Final value correct [PASS]");
            else begin $display("CAS Final value is %0d, expected 1 or 2 [FAIL]", val_at_300); errors++; end

            // If T0 won: Mem=1, T0 gets 0, T1 gets 1
            // If T1 won: Mem=2, T1 gets 0, T0 gets 2
            if (old_val_t0 == 0 && old_val_t1 == 1 && val_at_300 == 1) $display("CAS Race: Thread 0 won perfectly! [PASS]");
            else if (old_val_t1 == 0 && old_val_t0 == 2 && val_at_300 == 2) $display("CAS Race: Thread 1 won perfectly! [PASS]");
            else begin $display("CAS Race logic failed! T0=%0d, T1=%0d, Mem=%0d [FAIL]", old_val_t0, old_val_t1, val_at_300); errors++; end

            if (errors == 0) $display("\nALL TESTS PASSED FLAWLESSLY! MAC & ATOMIC CAS VERIFIED.\n");
            else $display("\nTEST FAILED WITH %0d ERRORS.\n", errors);
        end
        
        // =========================================================
        // PERFORMANCE COUNTERS REPORT
        // =========================================================
        // =========================================================
        // PERFORMANCE COUNTERS REPORT
        // =========================================================
        $display("==================================================");
        $display("             PERFORMANCE COUNTERS                 ");
        $display("==================================================");
        
        begin
            // Core & Pipeline Stats
            automatic int cycles  = dut.core_block[0].core_inst.stat_cycles;
            automatic int active  = dut.core_block[0].core_inst.stat_active_cycles;
            automatic int w_insts = dut.core_block[0].core_inst.stat_warp_inst_issued;
            automatic int t_insts = dut.core_block[0].core_inst.stat_thread_inst_executed;
            automatic int flushes = dut.core_block[0].core_inst.stat_flush_cycles;
            automatic int f_stall = dut.core_block[0].core_inst.stat_fetch_stalls;
            automatic int m_insts = dut.core_block[0].core_inst.stat_mem_insts;
            
            // Scheduler Stats
            automatic int s_idle  = dut.core_block[0].core_inst.scheduler_instance.stat_scheduler_idle;
            automatic int w_swtch = dut.core_block[0].core_inst.scheduler_instance.stat_warp_switches;
            automatic int w_divrg = dut.core_block[0].core_inst.scheduler_instance.stat_diverged_warps;
            
            // Cache Stats
            automatic int ic_acc   = dut.core_block[0].icache_inst.stat_accesses;
            automatic int ic_hit   = dut.core_block[0].icache_inst.stat_hits;
            automatic int ic_stall = dut.core_block[0].icache_inst.stat_latency_cycles;
            
            automatic int dc_r_acc = dut.core_block[0].dcache_inst.stat_read_accesses;
            automatic int dc_r_hit = dut.core_block[0].dcache_inst.stat_read_hits;
            automatic int dc_r_stl = dut.core_block[0].dcache_inst.stat_read_latency_cycles;
            
            automatic int dc_w_acc = dut.core_block[0].dcache_inst.stat_write_accesses;
            automatic int dc_w_hit = dut.core_block[0].dcache_inst.stat_write_hits;
            automatic int dc_w_stl = dut.core_block[0].dcache_inst.stat_write_latency_cycles;

            // Calculations
            automatic real pipe_util = cycles > 0 ? (real'(active) / real'(cycles)) * 100.0 : 0.0;
            automatic real ipc       = cycles > 0 ? (real'(t_insts) / real'(cycles)) : 0.0;
            
            automatic real ic_amat   = ic_acc > 0 ? (real'(ic_acc + ic_stall) / real'(ic_acc)) : 0.0;
            automatic real dc_r_amat = dc_r_acc > 0 ? (real'(dc_r_acc + dc_r_stl) / real'(dc_r_acc)) : 0.0;
            automatic real dc_w_amat = dc_w_acc > 0 ? (real'(dc_w_acc + dc_w_stl) / real'(dc_w_acc)) : 0.0;

            $display("--- CORE 0 PIPELINE EFFICIENCY ---");
            $display("Total Execution Cycles  : %0d", cycles);
            $display("Active ALU Cycles       : %0d (%.1f%% Util)", active, pipe_util);
            $display("Thread IPC              : %.2f Instructions/Cycle", ipc);
            $display("Fetch Stall Cycles      : %0d", f_stall);
            $display("Pipeline Flush Cycles   : %0d", flushes);
            
            $display("\n--- INSTRUCTION MIX & SCHEDULING ---");
            $display("Total Warp Insts Issued : %0d", w_insts);
            $display("Total Thread Insts Exec : %0d", t_insts);
            $display("Memory Instructions     : %0d", m_insts);
            $display("Scheduler Idle Cycles   : %0d", s_idle);
            $display("Warp Context Switches   : %0d", w_swtch);
            $display("Diverged Warp Count     : %0d", w_divrg);
            
            $display("\n--- I-CACHE 0 (Average Mem Access Time) ---");
            $display("Accesses                : %0d", ic_acc);
            $display("Hit Rate                : %0d%%", ic_acc > 0 ? (ic_hit * 100) / ic_acc : 0);
            $display("AMAT                    : %.2f cycles", ic_amat);
            
            $display("\n--- D-CACHE 0 (Average Mem Access Time) ---");
            $display("Read Accesses           : %0d", dc_r_acc);
            $display("Read Hit Rate           : %0d%%", dc_r_acc > 0 ? (dc_r_hit * 100) / dc_r_acc : 0);
            $display("Read AMAT               : %.2f cycles", dc_r_amat);
            $display("Write Accesses          : %0d", dc_w_acc);
            $display("Write Hit Rate          : %0d%%", dc_w_acc > 0 ? (dc_w_hit * 100) / dc_w_acc : 0);
            $display("Write AMAT              : %.2f cycles\n", dc_w_amat);
        end
        $display("==================================================");

        #20 $finish;    end
endmodule
