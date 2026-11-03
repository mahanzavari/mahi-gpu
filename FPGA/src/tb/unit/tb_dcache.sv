`default_nettype none
`timescale 1ns/1ns

// Unit test for dcache.sv (L1, write-through): random block reads and
// partial-strobe writes against a golden memory. Write-through means the
// backing memory must equal the golden memory after every write, and cached
// reads must reflect all earlier writes (hit-merge must not lose words).
module tb_dcache;
    localparam AW = gpu_pkg::CFG_DMEM_ADDR_BITS, BW = gpu_pkg::AXI_DATA_WIDTH;
    localparam NBLK = 128, W = BW/4;
    reg clk = 0, reset = 1; always #5 clk = ~clk;
    reg rv = 0, wv = 0; reg [AW-1:0] ra = 0, wa = 0; reg [BW-1:0] wd = 0; reg [3:0] ws = 0;
    wire rr, wrdy; wire [BW-1:0] rdata;
    wire mrv, mwv; wire [AW-1:0] mra, mwa; wire [BW-1:0] mwd; wire [3:0] mws;
    reg mrr = 0, mwr = 0; reg [BW-1:0] mrd = 0; reg flush = 0; wire fdone;

    dcache dut (.clk(clk), .reset(reset), .core_read_valid(rv), .core_read_block_addr(ra), .core_read_ready(rr), .core_read_block_data(rdata),
        .core_write_valid(wv), .core_write_block_addr(wa), .core_write_block_data(wd), .core_write_strobe(ws), .core_write_ready(wrdy),
        .mem_read_valid(mrv), .mem_read_block_addr(mra), .mem_read_ready(mrr), .mem_read_block_data(mrd),
        .mem_write_valid(mwv), .mem_write_block_addr(mwa), .mem_write_block_data(mwd), .mem_write_strobe(mws), .mem_write_ready(mwr),
        .flush_en(flush), .flush_done(fdone),
        .ev_read_acc(), .ev_read_hit(), .ev_read_stall(), .ev_write_acc(), .ev_write_hit(), .ev_write_stall());

    reg [BW-1:0] backing [0:NBLK-1], golden [0:NBLK-1];
    integer errors = 0, i, n, k, lat_r = 0, lat_w = 0;

    always @(posedge clk) begin
        mrr <= 0; mwr <= 0;
        if (mrv && !mrr) begin
            if (lat_r == 0) begin mrd <= backing[mra]; mrr <= 1; lat_r <= $urandom % 3; end else lat_r <= lat_r - 1;
        end
        if (mwv && !mwr) begin
            if (lat_w == 0) begin
                for (k = 0; k < 4; k = k + 1) if (mws[k]) backing[mwa][k*W +: W] <= mwd[k*W +: W];
                mwr <= 1; lat_w <= $urandom % 3;
            end else lat_w <= lat_w - 1;
        end
    end

    task do_write(input [AW-1:0] a, input [BW-1:0] d, input [3:0] s);
        begin
            wa = a; wd = d; ws = s; wv = 1; @(posedge clk); #1;
            while (!wrdy) begin @(posedge clk); #1; end
            wv = 0;
            for (k = 0; k < 4; k = k + 1) if (s[k]) golden[a][k*W +: W] = d[k*W +: W];
            @(posedge clk); #1;
            if (backing[a] !== golden[a]) begin errors = errors + 1;
                if (errors < 15) $display("[FAIL] write-through blk %0d: backing %h golden %h", a, backing[a], golden[a]); end
        end
    endtask
    task do_read(input [AW-1:0] a);
        begin
            ra = a; rv = 1; @(posedge clk); #1;
            while (!rr) begin @(posedge clk); #1; end
            rv = 0;
            if (rdata !== golden[a]) begin errors = errors + 1;
                if (errors < 15) $display("[FAIL] read blk %0d: got %h exp %h", a, rdata, golden[a]); end
            @(posedge clk); #1;
        end
    endtask

    reg [BW-1:0] rnd; reg [3:0] st; integer blk;
    initial begin
        for (i = 0; i < NBLK; i = i + 1) begin backing[i] = {4{32'(i) ^ 32'hD00D0000}}; golden[i] = backing[i]; end
        repeat (3) @(posedge clk); #1; reset = 0; repeat (2) @(posedge clk); #1;

        // read allocates; later partial writes hit and must merge, not clobber
        do_read(3);
        do_write(3, {4{32'hAAAA_0001}}, 4'b0010);
        do_read(3);
        do_write(3, {4{32'hBBBB_0002}}, 4'b1001);
        do_read(3);
        // write miss (no allocate) followed by read must see the write
        do_write(40, {4{32'hCCCC_0003}}, 4'b0100);
        do_read(40);

        for (n = 0; n < 8000; n = n + 1) begin
            blk = ($urandom % 3 == 0) ? ($urandom % 6) : ($urandom % NBLK);   // 16 lines: thrash with 128 blocks
            if ($urandom % 2) do_read(blk);
            else begin
                rnd = {$urandom, $urandom, $urandom, $urandom}; st = $urandom; if (st == 0) st = 4'b0001;
                do_write(blk, rnd, st);
            end
        end
        // flush invalidates; reads still correct afterwards
        flush = 1; @(posedge clk); #1; flush = 0; repeat (3) @(posedge clk);
        for (i = 0; i < NBLK; i = i + 1) do_read(i);

        if (errors == 0) $display("tb_dcache: ALL PASSED");
        else $fatal(1, "tb_dcache: %0d errors", errors);
        $finish;
    end
    initial begin #50000000; $fatal(1, "tb_dcache: TIMEOUT"); end
endmodule
