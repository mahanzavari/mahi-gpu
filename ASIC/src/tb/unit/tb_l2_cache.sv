`default_nettype none
`timescale 1ns/1ns

// Unit test for l2_cache.sv (+ its victim_write_buffer): random partial-strobe
// writes and reads over a block range much larger than the cache, so evictions,
// VWB probe hits and merges all occur. Every read is checked against a golden
// memory; after a flush the backing memory must equal the golden memory.
module tb_l2_cache;
    localparam AW = gpu_pkg::CFG_DMEM_ADDR_BITS, BW = gpu_pkg::AXI_DATA_WIDTH, SEC = gpu_pkg::CFG_L2_SECTORS;
    localparam SB = BW / SEC;
    localparam NBLK = 512;           // >> CFG_L2_CACHE_LINES (64) to force evictions
    reg clk = 0, reset = 1;
    always #5 clk = ~clk;

    reg  [0:0] rv = 0, wv = 0; reg [AW-1:0] ra [1], wa [1]; reg [BW-1:0] wd [1]; reg [SEC-1:0] ws [1];
    wire [0:0] rr, wr_rdy; wire [BW-1:0] rdata [1];
    wire mrv, mwv; wire [AW-1:0] mra, mwa; wire [BW-1:0] mwd; wire [SEC-1:0] mws;
    reg mrr = 0, mwr = 0; reg [BW-1:0] mrd = 0;
    reg flush = 0; wire fdone;

    l2_cache dut (.clk(clk), .reset(reset), .up_read_valid(rv), .up_read_addr(ra), .up_read_ready(rr), .up_read_data(rdata),
        .up_write_valid(wv), .up_write_addr(wa), .up_write_data(wd), .up_write_strobe(ws), .up_write_ready(wr_rdy),
        .mem_read_valid(mrv), .mem_read_addr(mra), .mem_read_ready(mrr), .mem_read_data(mrd),
        .mem_write_valid(mwv), .mem_write_addr(mwa), .mem_write_data(mwd), .mem_write_strobe(mws), .mem_write_ready(mwr),
        .flush_en(flush), .flush_done(fdone),
        .ev_read_acc(), .ev_read_hit(), .ev_read_miss(), .ev_write_acc(), .ev_write_hit(), .ev_write_miss(), .ev_stall(), .ev_evict());

    // backing memory with random latency; golden = what the program has written
    reg [BW-1:0] backing [0:NBLK-1], golden [0:NBLK-1];
    integer lat_r = 0, lat_w = 0, errors = 0, i, n, sec;

    always @(posedge clk) begin
        mrr <= 0; mwr <= 0;
        if (mrv && !mrr) begin
            if (lat_r == 0) begin mrd <= backing[mra]; mrr <= 1; lat_r <= $urandom % 4; end else lat_r <= lat_r - 1;
        end
        if (mwv && !mwr) begin
            if (lat_w == 0) begin
                for (sec = 0; sec < SEC; sec = sec + 1) if (mws[sec]) backing[mwa][sec*SB +: SB] <= mwd[sec*SB +: SB];
                mwr <= 1; lat_w <= $urandom % 4;
            end else lat_w <= lat_w - 1;
        end
    end

    task do_write(input [AW-1:0] a, input [BW-1:0] d, input [SEC-1:0] s);
        begin
            wa[0] = a; wd[0] = d; ws[0] = s; wv = 1;
            @(posedge clk); #1;
            while (!wr_rdy[0]) begin @(posedge clk); #1; end
            wv = 0;
            for (sec = 0; sec < SEC; sec = sec + 1) if (s[sec]) golden[a][sec*SB +: SB] = d[sec*SB +: SB];
            @(posedge clk); #1;
        end
    endtask
    task do_read(input [AW-1:0] a);
        begin
            ra[0] = a; rv = 1;
            @(posedge clk); #1;
            while (!rr[0]) begin @(posedge clk); #1; end
            rv = 0;
            if (rdata[0] !== golden[a]) begin
                errors = errors + 1;
                if (errors < 15) $display("[FAIL] read blk %0d: got %h exp %h", a, rdata[0], golden[a]);
            end
            @(posedge clk); #1;
        end
    endtask

    reg [BW-1:0] rnd; reg [SEC-1:0] st; integer blk, kind;
    initial begin
        ra[0] = 0; wa[0] = 0; wd[0] = 0; ws[0] = 0;
        for (i = 0; i < NBLK; i = i + 1) begin backing[i] = {BW/32{32'(i) ^ 32'hC0DE0000}}; golden[i] = backing[i]; end
        repeat (3) @(posedge clk); #1; reset = 0; repeat (2) @(posedge clk); #1;

        // directed: partial writes to one block at different times must accumulate
        do_write(5, {BW/32{32'h1111_1111}}, 4'b0001);
        do_write(5, {BW/32{32'h2222_2222}}, 4'b1110);
        do_read(5);
        // write then read-back of an untouched block returns the backing contents
        do_read(100);

        // random traffic; skewed toward a hot set to exercise merges, uniform to exercise eviction
        for (n = 0; n < 6000; n = n + 1) begin
            blk = ($urandom % 4 == 0) ? ($urandom % 8) : ($urandom % NBLK);
            kind = $urandom % 3;
            if (kind == 0) do_read(blk);
            else begin
                rnd = {$urandom, $urandom, $urandom, $urandom}; st = $urandom;
                if (st == 0) st = 4'b0100;
                do_write(blk, rnd, st);
            end
        end

        // flush -> backing must match golden
        flush = 1;
        i = 0; while (!fdone && i < 20000) begin @(posedge clk); #1; i = i + 1; end
        if (!fdone) begin errors = errors + 1; $display("[FAIL] flush_done never asserted"); end
        repeat (50) @(posedge clk); #1;
        flush = 0;
        for (i = 0; i < NBLK; i = i + 1) if (backing[i] !== golden[i]) begin
            errors = errors + 1; if (errors < 25) $display("[FAIL] after flush blk %0d: backing %h golden %h", i, backing[i], golden[i]);
        end
        // reads after flush still correct
        for (i = 0; i < 200; i = i + 1) do_read($urandom % NBLK);

        if (errors == 0) $display("tb_l2_cache: ALL PASSED");
        else $fatal(1, "tb_l2_cache: %0d errors", errors);
        $finish;
    end
    initial begin #50000000; $fatal(1, "tb_l2_cache: TIMEOUT"); end
endmodule
