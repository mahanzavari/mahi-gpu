`default_nettype none
`timescale 1ns/1ns

// Full-chip testbench for gpu_asic_top: everything goes through the Wishbone port.
//   load program (PMEM window) + data (DMEM window) -> start -> poll STATUS.done
//   -> read back the 512-word DMEM window.
// Plusargs: +prog=<hex> +dmem=<hex> +out=<file> [+prog2= +dmem2= +out2=] (second run after a
//   soft reset, to prove stale cache contents do not leak) +threads=<n> +maxcyc=<n> +gap=<n>
//   (idle cycles between Wishbone transactions, default 0).
// Self-checks (always on): window read-back, byte-lane writes, blocked access while running,
// unmapped page, STATUS flags. Prints "TOP_TB_PASS" and exits 0 when all pass.
module tb_asic_top;
    reg clk = 0, reset = 1;
    reg wb_cyc = 0, wb_stb = 0, wb_we = 0; reg [3:0] wb_sel = 4'hF;
    reg [31:0] wb_adr = 0, wb_dati = 0; wire [31:0] wb_dato; wire wb_ack; wire done_pin; wire fault_pin;

    gpu_asic_top dut (.clk(clk), .reset(reset), .wb_cyc_i(wb_cyc), .wb_stb_i(wb_stb), .wb_we_i(wb_we),
        .wb_sel_i(wb_sel), .wb_adr_i(wb_adr), .wb_dat_i(wb_dati), .wb_dat_o(wb_dato), .wb_ack_o(wb_ack),
        .gpu_done_pin(done_pin), .gpu_fault_pin(fault_pin));

    always #5 clk = ~clk;

    integer gap = 0, errors = 0, g;
    reg [31:0] rd;

    task wb_xfer(input we, input [3:0] sel, input [31:0] adr, input [31:0] dat, output [31:0] q);
        integer t;
        begin
            @(posedge clk); #1;
            wb_cyc = 1; wb_stb = 1; wb_we = we; wb_sel = sel; wb_adr = adr; wb_dati = dat;
            t = 0;
            @(posedge clk);
            while (!wb_ack && t < 200) begin @(posedge clk); t = t + 1; end
            if (t >= 200) begin $display("TB_ERROR: wishbone timeout @%08x", adr); errors = errors + 1; end
            q = wb_dato;
            #1 wb_cyc = 0; wb_stb = 0; wb_we = 0;
            for (g = 0; g < gap; g = g + 1) @(posedge clk);
        end
    endtask
    task wb_wr(input [31:0] adr, input [31:0] dat); begin wb_xfer(1, 4'hF, adr, dat, rd); end endtask
    task wb_rd(input [31:0] adr, output [31:0] q); begin wb_xfer(0, 4'hF, adr, 0, q); end endtask

    localparam [31:0] CTRL = 32'h3000_0000, STAT = 32'h3000_0004, FINFO = 32'h3000_0008, PMEM = 32'h3000_1000, DMEM = 32'h3000_1800;
    reg [31:0] prog [0:511], dmem [0:511], img [0:511];
    string pf, df, of; integer nthr, maxcyc, i, cyc, fd, ok;
    reg [31:0] v;

    task expect_eq(input [255:0] what, input [31:0] got, input [31:0] exp);
        begin if (got !== exp) begin $display("TB_FAIL %0s: got %08x exp %08x", what, got, exp); errors = errors + 1; end end
    endtask

    task run_kernel(input string pfile, input string dfile, input string ofile, input check_blocked);
        begin
            for (i = 0; i < 512; i = i + 1) begin prog[i] = 0; dmem[i] = 0; end
            $readmemh(pfile, prog); $readmemh(dfile, dmem);
            for (i = 0; i < 512; i = i + 1) wb_wr(PMEM + 4*i, prog[i]);
            for (i = 0; i < 512; i = i + 1) wb_wr(DMEM + 4*i, dmem[i]);
            for (i = 0; i < 512; i = i + 7) begin                     // spot-check the load before running
                wb_rd(PMEM + 4*i, v); expect_eq("pmem readback", v, prog[i]);
                wb_rd(DMEM + 4*i, v); expect_eq("dmem readback", v, dmem[i]);
            end
            wb_wr(CTRL, (nthr << 8) | 1);
            if (check_blocked) begin                                   // memory is off-limits while running
                wb_rd(DMEM, v);   expect_eq("blocked read", v, 32'hBAD0_BAD0);
                wb_wr(DMEM, 32'hDEAD_BEEF);
                wb_rd(STAT, v);   if (!v[3] && !v[0]) begin $display("TB_FAIL blocked flag not set (stat=%08x)", v); errors = errors + 1; end
                wb_wr(STAT, 32'h8);                                    // W1C host_blocked
            end
            cyc = 0; v = 0;
            while (!v[0] && cyc < maxcyc) begin wb_rd(STAT, v); cyc = cyc + 1; end
            if (!v[0]) begin $display("TB_TIMEOUT after %0d polls", cyc); $finish(2); end
            expect_eq("busy clear when done", v[1], 0);
            expect_eq("gpu_oob", v[2], 0);
            expect_eq("no fault", v[4], 0);
            wb_wr(CTRL, 0);                                            // drop start
            wb_rd(STAT, v);
            fd = $fopen(ofile, "w");
            for (i = 0; i < 512; i = i + 1) begin wb_rd(DMEM + 4*i, v); $fdisplay(fd, "%08x", v); end
            $fclose(fd);
            $display("TB_RUN_DONE polls=%0d", cyc);
        end
    endtask

    initial begin
        if (!$value$plusargs("prog=%s", pf)) begin $display("TB_ERROR: +prog required"); $fatal(1); end
        if (!$value$plusargs("dmem=%s", df)) df = pf;
        if (!$value$plusargs("out=%s", of)) of = "out.hex";
        if (!$value$plusargs("threads=%d", nthr)) nthr = 8;
        if (!$value$plusargs("maxcyc=%d", maxcyc)) maxcyc = 20000;
        if (!$value$plusargs("gap=%d", gap)) gap = 0;

        repeat (10) @(posedge clk); #1 reset = 0;
        repeat (3) @(posedge clk);

        // ---- directed window checks (GPU idle)
        wb_rd(STAT, v);          expect_eq("status after reset", v, 32'h0);
        wb_wr(PMEM + 32'h10, 32'hA1B2C3D4); wb_rd(PMEM + 32'h10, v); expect_eq("pmem rw", v, 32'hA1B2C3D4);
        wb_wr(DMEM + 32'h10, 32'h11223344); wb_rd(DMEM + 32'h10, v); expect_eq("dmem rw", v, 32'h11223344);
        wb_rd(PMEM + 32'h10, v); expect_eq("banks independent", v, 32'hA1B2C3D4);
        wb_xfer(1, 4'b0101, DMEM + 32'h10, 32'hFFFFFFFF, rd);       // byte lanes 0 and 2
        wb_rd(DMEM + 32'h10, v); expect_eq("byte strobes", v, 32'h11FF33FF);
        wb_wr(PMEM + 32'h7FC, 32'h5A5A5A5A); wb_rd(PMEM + 32'h7FC, v); expect_eq("pmem last word", v, 32'h5A5A5A5A);
        wb_wr(DMEM + 32'h7FC, 32'hC3C3C3C3); wb_rd(DMEM + 32'h7FC, v); expect_eq("dmem last word", v, 32'hC3C3C3C3);
        wb_rd(32'h3000_2000, v); expect_eq("unmapped page read", v, 0);
        wb_wr(32'h3000_2000, 32'h1);                                  // acked, ignored
        wb_rd(CTRL, v);          expect_eq("ctrl readback", v, 32'h0);

        // ---- corner cases (GPU idle unless stated)
        // zero byte-enable write leaves the word untouched
        wb_wr(DMEM + 32'h20, 32'hCAFEF00D);
        wb_xfer(1, 4'b0000, DMEM + 32'h20, 32'h0, rd); wb_rd(DMEM + 32'h20, v); expect_eq("sel=0 write ignored", v, 32'hCAFEF00D);
        // master aborts (drops stb after one cycle) a read and a write: no hang, bus usable afterwards
        @(posedge clk); #1 wb_cyc = 1; wb_stb = 1; wb_we = 1; wb_sel = 4'hF; wb_adr = DMEM + 32'h24; wb_dati = 32'h0BADF00D;
        @(posedge clk); #1 wb_cyc = 0; wb_stb = 0; wb_we = 0;
        repeat (6) @(posedge clk);
        @(posedge clk); #1 wb_cyc = 1; wb_stb = 1; wb_we = 0; wb_adr = DMEM + 32'h20;
        @(posedge clk); #1 wb_cyc = 0; wb_stb = 0;
        repeat (6) @(posedge clk);
        wb_rd(DMEM + 32'h20, v); expect_eq("read after aborts", v, 32'hCAFEF00D);
        // STATUS write-1-to-clear
        wb_wr(STAT, 32'hC);  wb_rd(STAT, v); expect_eq("status W1C clears flags", v[3:2], 2'b00);
        // CTRL with start and soft-reset together: soft reset wins, start stays low
        wb_wr(CTRL, 32'h0000_0803); repeat (12) @(posedge clk);
        wb_rd(CTRL, v); expect_eq("soft reset beats start", v[0], 1'b0);
        wb_rd(STAT, v); expect_eq("not busy after soft reset", v[1], 1'b0);
        // a window write issued during the soft-reset window is refused and flagged
        wb_wr(CTRL, 32'h2); wb_wr(DMEM + 32'h28, 32'h12345678);
        wb_rd(STAT, v); expect_eq("write during soft reset flagged", v[3], 1'b1); wb_wr(STAT, 32'h8);
        repeat (12) @(posedge clk);
        wb_rd(DMEM + 32'h28, v); if (v === 32'h12345678) begin $display("TB_FAIL write during soft reset took effect"); errors = errors + 1; end
        // hard reset in the middle of a kernel, then a full reload + run must still be exact
        for (i = 0; i < 512; i = i + 1) prog[i] = 0;
        $readmemh(pf, prog);
        for (i = 0; i < 512; i = i + 1) wb_wr(PMEM + 4*i, prog[i]);
        $readmemh(df, dmem);
        for (i = 0; i < 512; i = i + 1) wb_wr(DMEM + 4*i, dmem[i]);
        wb_wr(CTRL, (nthr << 8) | 1); repeat (300) @(posedge clk);
        #1 reset = 1; repeat (3) @(posedge clk); #1 reset = 0; repeat (3) @(posedge clk);
        wb_rd(STAT, v); expect_eq("status after mid-run reset", v, 32'h0);
        wb_rd(CTRL, v); expect_eq("ctrl after mid-run reset", v, 32'h0);

        run_kernel(pf, df, of, 1);

        if ($value$plusargs("prog2=%s", pf)) begin
            if (!$value$plusargs("dmem2=%s", df)) df = pf;
            if (!$value$plusargs("out2=%s", of)) of = "out2.hex";
            wb_wr(CTRL, 32'h2);                                       // soft reset (clears DCR + caches)
            repeat (12) @(posedge clk);
            run_kernel(pf, df, of, 0);
        end

        // ---- directed fault: DIV by zero at pc 2 -> STATUS[4], FAULT_INFO, fault pin; W1C clears
        wb_wr(CTRL, 32'h2); repeat (12) @(posedge clk);
        for (i = 0; i < 512; i = i + 1) wb_wr(PMEM + 4*i, 32'h0);
        wb_wr(PMEM + 0,  32'h24200005);                               // CONST R1, 5
        wb_wr(PMEM + 4,  32'h24400000);                               // CONST R2, 0
        wb_wr(PMEM + 8,  32'h18611000);                               // DIV R3, R1, R2  (faults)
        wb_wr(PMEM + 12, 32'h2480004d);                               // CONST R4, 77
        wb_wr(PMEM + 16, 32'h209f012c);                               // STR R4, [R31 + 300]
        wb_wr(PMEM + 20, 32'h3c000000);                               // EXIT
        wb_wr(DMEM + 4*300, 32'h0);
        wb_rd(STAT, v); expect_eq("no fault before run", v[4], 1'b0);
        wb_wr(CTRL, (nthr << 8) | 1);
        cyc = 0; v = 0;
        while (!v[0] && cyc < maxcyc) begin wb_rd(STAT, v); cyc = cyc + 1; end
        expect_eq("faulting kernel reaches done", v[0], 1'b1);
        expect_eq("STATUS[4] fault", v[4], 1'b1);
        expect_eq("fault pin", fault_pin, 1'b1);
        wb_rd(FINFO, v); expect_eq("FAULT_INFO cause/pc", {v[31:16], v[3:0]}, {16'd2, 4'd1});
        wb_wr(CTRL, 0);
        wb_rd(DMEM + 4*300, v); expect_eq("post-fault store suppressed", v, 32'h0);
        wb_wr(STAT, 32'h10); wb_rd(STAT, v); expect_eq("fault W1C", v[4], 1'b0);
        expect_eq("fault pin cleared", fault_pin, 1'b0);

        if (errors == 0) begin $display("TOP_TB_PASS"); $finish; end
        else begin $display("TOP_TB_FAILED errors=%0d", errors); $finish(1); end
    end
endmodule
