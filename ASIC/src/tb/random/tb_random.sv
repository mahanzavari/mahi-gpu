`default_nettype none
`timescale 1ns/1ns

// Random-program runner. Plusargs:
//   +prog=<hex>  program words (one 32-bit hex word per line)
//   +dmem=<hex>  initial data memory words (from address 0)
//   +out=<file>  final data memory dump (1024 words)
//   +lat=<n>     max random extra latency (cycles) on every memory access (default 0)
//   +seed=<n>    seed for the latency generator
//   +threads=<n> thread count written to the DCR (default 8)
//   +maxcyc=<n>  hang watchdog (default 400000 cycles)
// Exits 0 after dumping; a hang prints "TB_TIMEOUT" and exits nonzero.
module tb_random;
    localparam DAW = gpu_pkg::CFG_DMEM_ADDR_BITS, DDW = gpu_pkg::CFG_DMEM_DATA_BITS, DCH = gpu_pkg::CFG_DATA_MEM_NUM_CHANNELS;
    localparam PAW = gpu_pkg::CFG_PMEM_ADDR_BITS, PDW = gpu_pkg::CFG_PMEM_DATA_BITS, PCH = gpu_pkg::CFG_PROGRAM_MEM_NUM_CHANNELS;

    reg clk = 0, reset = 1, start = 0; wire done;
    reg dcr_we = 0; reg [7:0] dcr_data = 0;
    wire [PCH-1:0] pm_rv; wire [PAW-1:0] pm_ra [PCH]; reg [PCH-1:0] pm_rr = 0; reg [PDW*4-1:0] pm_rd [PCH];
    wire [DCH-1:0] dm_rv, dm_wv; wire [DAW-1:0] dm_ra [DCH], dm_wa [DCH];
    reg [DCH-1:0] dm_rr = 0, dm_wr = 0; reg [DDW*4-1:0] dm_rd [DCH]; wire [DDW*4-1:0] dm_wd [DCH]; wire [3:0] dm_ws [DCH];

    gpu dut (.clk(clk), .reset(reset), .start(start), .done(done),
        .device_control_write_enable(dcr_we), .device_control_address(8'h00), .device_control_data(dcr_data),
        .program_mem_read_valid(pm_rv), .program_mem_read_address(pm_ra), .program_mem_read_ready(pm_rr), .program_mem_read_data(pm_rd),
        .data_mem_read_valid(dm_rv), .data_mem_read_address(dm_ra), .data_mem_read_ready(dm_rr), .data_mem_read_data(dm_rd),
        .data_mem_write_valid(dm_wv), .data_mem_write_address(dm_wa), .data_mem_write_data(dm_wd),
        .data_mem_write_strobe(dm_ws), .data_mem_write_ready(dm_wr),
        .pmu_snap_0(), .pmu_snap_1(), .pmu_snap_2(), .pmu_snap_3());

    reg [31:0] p_mem [0:4095];
    reg [31:0] d_mem [0:1023];

    // ---- xorshift32 for latency
    reg [31:0] rng = 32'h1234567;
    integer lat_max = 0;
    function [31:0] xs(input [31:0] x); begin x = x ^ (x << 13); x = x ^ (x >> 17); x = x ^ (x << 5); xs = x; end endfunction
    task rnd_lat(output integer l); begin rng = xs(rng); l = (lat_max == 0) ? 0 : (rng[15:0] % (lat_max + 1)); end endtask

    // ---- memory mock: one in-flight request per channel, completion after a random delay
    reg [PCH-1:0] p_pend = 0; integer p_cnt [PCH];
    reg [DCH-1:0] r_pend = 0, w_pend = 0; integer r_cnt [DCH], w_cnt [DCH];
    integer i, k, lt, wb;

    always @(posedge clk) begin
        for (i = 0; i < PCH; i = i + 1) begin
            if (!pm_rv[i]) begin pm_rr[i] <= 0; p_pend[i] <= 0; end
            else if (!pm_rr[i] && !p_pend[i]) begin p_pend[i] <= 1; rnd_lat(lt); p_cnt[i] <= lt; end
            else if (p_pend[i]) begin
                if (p_cnt[i] == 0) begin
                    wb = pm_ra[i] * 4;
                    pm_rd[i] <= {p_mem[wb+3], p_mem[wb+2], p_mem[wb+1], p_mem[wb]};
                    pm_rr[i] <= 1; p_pend[i] <= 0;
                end else p_cnt[i] <= p_cnt[i] - 1;
            end
        end
        for (i = 0; i < DCH; i = i + 1) begin
            if (!dm_rv[i]) begin dm_rr[i] <= 0; r_pend[i] <= 0; end
            else if (!dm_rr[i] && !r_pend[i]) begin r_pend[i] <= 1; rnd_lat(lt); r_cnt[i] <= lt; end
            else if (r_pend[i]) begin
                if (r_cnt[i] == 0) begin
                    wb = dm_ra[i] * 4;
                    dm_rd[i] <= {d_mem[wb+3], d_mem[wb+2], d_mem[wb+1], d_mem[wb]};
                    dm_rr[i] <= 1; r_pend[i] <= 0;
                end else r_cnt[i] <= r_cnt[i] - 1;
            end
            if (!dm_wv[i]) begin dm_wr[i] <= 0; w_pend[i] <= 0; end
            else if (!dm_wr[i] && !w_pend[i]) begin w_pend[i] <= 1; rnd_lat(lt); w_cnt[i] <= lt; end
            else if (w_pend[i]) begin
                if (w_cnt[i] == 0) begin
                    wb = dm_wa[i] * 4;
                    for (k = 0; k < 4; k = k + 1) if (dm_ws[i][k]) d_mem[wb+k] <= dm_wd[i][k*32 +: 32];
                    dm_wr[i] <= 1; w_pend[i] <= 0;
                end else w_cnt[i] <= w_cnt[i] - 1;
            end
        end
    end

    always #5 clk = ~clk;

    string prog_f, dmem_f, out_f; integer nthr, maxcyc, cyc, fd, seed_arg;
    initial begin
        for (i = 0; i < 4096; i = i + 1) p_mem[i] = 0;
        for (i = 0; i < 1024; i = i + 1) d_mem[i] = 0;
        if (!$value$plusargs("prog=%s", prog_f)) begin $display("TB_ERROR: +prog required"); $fatal(1); end
        $readmemh(prog_f, p_mem);
        if ($value$plusargs("dmem=%s", dmem_f)) $readmemh(dmem_f, d_mem);
        if (!$value$plusargs("out=%s", out_f)) out_f = "out.hex";
        if (!$value$plusargs("lat=%d", lat_max)) lat_max = 0;
        if ($value$plusargs("seed=%d", seed_arg)) rng = seed_arg * 32'h9E3779B1 + 1;
        if (!$value$plusargs("threads=%d", nthr)) nthr = 8;
        if (!$value$plusargs("maxcyc=%d", maxcyc)) maxcyc = 400000;

        repeat (10) @(posedge clk); #1 reset = 0;
        repeat (5) @(posedge clk); #1 dcr_we = 1; dcr_data = nthr[7:0];
        @(posedge clk); #1 dcr_we = 0;
        repeat (3) @(posedge clk); #1 start = 1;
        repeat (5) @(posedge clk); #1 start = 0;

        cyc = 0;
        while (!done && cyc < maxcyc) begin @(posedge clk); cyc = cyc + 1; end
        if (!done) begin $display("TB_TIMEOUT after %0d cycles", cyc); $finish(2); end
        repeat (200) @(posedge clk);            // let the final flush/writebacks land

        fd = $fopen(out_f, "w");
        for (i = 0; i < 1024; i = i + 1) $fdisplay(fd, "%08x", d_mem[i]);
        $fclose(fd);
        $display("TB_DONE cycles=%0d", cyc);
        $finish;
    end
endmodule
