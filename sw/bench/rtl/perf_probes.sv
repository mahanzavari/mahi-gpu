// Simulation-only performance counters for the benchmark suite (sw/bench). Attached with `bind`, so the RTL is not
// touched; compiled only into the runtime's perf build (VerilatorBackend(perf=True)). Every probe prints one line
//   PERF <unit> <instance> key=value ...
// from a final block; sw/mahi/runtime.py parses them into LaunchResult.perf.
//
// Probes sample the bound module's signals at the clock edge, i.e. the values the module's own FSMs act on.
`default_nettype none

// ---------------------------------------------------------------------------------------------------------- core
// Issue-slot accounting: every running cycle falls into exactly one bucket (sums to `run`):
//   issue      an instruction issued
//   ifetch     a warp was selected but its instruction was not fetched yet (I$ miss / fetch latency)
//   ll_dep     the ID-stage instruction waits on an FMA/DIV result or the busy divider (fp_raw_stall)
//   raw        a warp was selected but its source register is still in ID/EX (issue scoreboard)
//   serial     a READY warp exists but cannot issue: its serializing instruction (branch, memory, SYNC, FP, ...) is
//              still in ID/EX, or it waits at a join point / flush
//   mem        no READY warp, at least one waits on the LSU
//   ll         no READY warp, none on memory, at least one waits for an FMA/DIV writeback
//   barrier    no READY warp, only barrier waiters (and finished warps)
//   drain      no live warp (all done) while the core still runs
module core_perf #(parameter LANES = 4, parameter WARPS = 4) (
    input wire clk, input wire reset, input wire running,
    input wire valid_issue, input wire found, input wire frontend_stall, input wire fp_raw_stall,
    input wire issue_hazard, input wire [2:0] ws [WARPS],
    input wire [31:0] events,
    input wire [31:0] id_instruction, input wire [WARPS-1:0] flush_warp_mask, input wire [$clog2(WARPS)-1:0] id_warp_id,
    input wire [LANES-1:0] ex_active_mask
);
    localparam S_READY = 1, S_MEM = 2, S_BAR = 3, S_FP = 4, S_DONE = 5, S_FAULT = 6;
    longint run = 0, b_issue = 0, b_ifetch = 0, b_lldep = 0, b_raw = 0, b_serial = 0, b_mem = 0, b_ll = 0, b_bar = 0,
            b_drain = 0, any_mem = 0, ev [32], ready_h [WARPS+1], op_w [64], op_t [64];
    reg [5:0] ex_op;
    initial begin
        for (int i = 0; i < 32; i++) ev[i] = 0;
        for (int i = 0; i <= WARPS; i++) ready_h[i] = 0;
        for (int i = 0; i < 64; i++) begin op_w[i] = 0; op_t[i] = 0; end
    end
    // opcode of the instruction in EX (core.sv loads ex_* under the same condition)
    always @(posedge clk)
        if (reset) ex_op <= 0;
        else if (!(flush_warp_mask[id_warp_id] || fp_raw_stall)) ex_op <= id_instruction[31:26];

    always @(posedge clk) if (!reset) begin
        for (int i = 0; i < 32; i++) if (events[i]) ev[i]++;
        if (|ex_active_mask) begin op_w[ex_op]++; op_t[ex_op] += $countones(ex_active_mask); end
        if (running) begin
            int nr, nm, nf, nb, nl;
            nr = 0; nm = 0; nf = 0; nb = 0; nl = 0;
            for (int w = 0; w < WARPS; w++) begin
                if (ws[w] == S_READY) nr++;
                if (ws[w] == S_MEM) nm++;
                if (ws[w] == S_FP) nf++;
                if (ws[w] == S_BAR) nb++;
                if (ws[w] == S_READY || ws[w] == S_MEM || ws[w] == S_FP || ws[w] == S_BAR) nl++;
            end
            run++; ready_h[nr]++; if (nm > 0) any_mem++;
            if (valid_issue) b_issue++;
            else if (found && fp_raw_stall) b_lldep++;
            else if (found && frontend_stall) b_ifetch++;
            else if (found && issue_hazard) b_raw++;
            else if (nr > 0) b_serial++;
            else if (nm > 0) b_mem++;
            else if (nf > 0) b_ll++;
            else if (nb > 0) b_bar++;
            else b_drain++;
        end
    end
    final begin
        string s;
        s = $sformatf("PERF core %m run=%0d issue=%0d ifetch=%0d ll_dep=%0d raw=%0d serial=%0d mem=%0d ll=%0d barrier=%0d drain=%0d any_mem=%0d",
                      run, b_issue, b_ifetch, b_lldep, b_raw, b_serial, b_mem, b_ll, b_bar, b_drain, any_mem);
        for (int i = 0; i <= WARPS; i++) s = {s, $sformatf(" ready%0d=%0d", i, ready_h[i])};
        for (int i = 3; i < 28; i++) s = {s, $sformatf(" ev%0d=%0d", i, ev[i])};
        for (int i = 0; i < 64; i++) if (op_w[i] != 0) s = {s, $sformatf(" opw%0d=%0d opt%0d=%0d", i, op_w[i], i, op_t[i])};
        $display("%s", s);
    end
endmodule

// ----------------------------------------------------------------------------------------------------------- lsu
// state: IDLE, COALESCE_READ, WAIT_READ, COALESCE_WRITE, WAIT_WRITE, WAIT_SHARED, ATOMIC_READ, ATOMIC_WAIT_READ,
// ATOMIC_WAIT_WRITE. A request = one warp memory instruction; a transaction = one 4-word line access to the D$.
module lsu_perf #(parameter LANES = 4, parameter WARPS = 4) (
    input wire clk, input wire reset, input wire [3:0] st, input wire [LANES-1:0] pending,
    input wire req_valid [WARPS]
);
    longint sc [16], req_rd = 0, req_wr = 0, req_sh = 0, req_at = 0, tx_rd = 0, tx_wr = 0, tx_at = 0, queued = 0;
    reg [3:0] prev = 0;
    initial for (int i = 0; i < 16; i++) sc[i] = 0;
    always @(posedge clk) if (!reset) begin
        sc[st]++;
        for (int w = 0; w < WARPS; w++) if (req_valid[w]) queued++;
        if (prev == 0) begin
            if (st == 1) req_rd++; if (st == 3) req_wr++; if (st == 5) req_sh++; if (st == 6) req_at++;
        end
        if (st == 1 && |pending) tx_rd++;
        if (st == 3 && |pending) tx_wr++;
        if (st == 6 && |pending) tx_at++;
        prev <= st;
    end
    final $display("PERF lsu %m req_rd=%0d req_wr=%0d req_sh=%0d req_at=%0d tx_rd=%0d tx_wr=%0d tx_at=%0d queued=%0d idle=%0d coal_rd=%0d wait_rd=%0d coal_wr=%0d wait_wr=%0d wait_sh=%0d at_rd=%0d at_wait_rd=%0d at_wait_wr=%0d",
                   req_rd, req_wr, req_sh, req_at, tx_rd, tx_wr, tx_at, queued,
                   sc[0], sc[1], sc[2], sc[3], sc[4], sc[5], sc[6], sc[7], sc[8]);
endmodule

// -------------------------------------------------------------------------------------------------------- dcache
// state: IDLE, FETCHING_READ, WAITING_WRITE. Write-through: every write goes down to the L2.
module dcache_perf (
    input wire clk, input wire reset, input wire [1:0] st,
    input wire rv, input wire rr, input wire wv, input wire wr
);
    longint rd = 0, wrc = 0, rd_wait = 0, wr_wait = 0, fills = 0, fill_cyc = 0, wt_cyc = 0;
    reg [1:0] prev = 0;
    always @(posedge clk) if (!reset) begin
        if (rv && rr) rd++; if (wv && wr) wrc++; if (rv && !rr) rd_wait++; if (wv && !wr) wr_wait++;
        if (st == 1 && prev != 1) fills++;
        if (st == 1) fill_cyc++; if (st == 2) wt_cyc++;
        prev <= st;
    end
    final $display("PERF dcache %m reads=%0d writes=%0d read_wait=%0d write_wait=%0d fills=%0d fill_cyc=%0d writethrough_cyc=%0d",
                   rd, wrc, rd_wait, wr_wait, fills, fill_cyc, wt_cyc);
endmodule

// ------------------------------------------------------------------------------------------------------------ L2
// state: IDLE, SERVING, FETCHING, FLUSH_SCAN, FLUSH_WAIT, WAIT_DATA, FLUSH_READ; cont: K_HIT_READ, K_RESPOND, K_PUSH_VICTIM
module l2_perf #(parameter PORTS = 2) (
    input wire clk, input wire reset, input wire [2:0] st, input wire [1:0] cont, input wire hit, input wire is_write,
    input wire [PORTS-1:0] up_rv, input wire [PORTS-1:0] up_rr, input wire [PORTS-1:0] up_wv, input wire [PORTS-1:0] up_wr
);
    longint sc [8], req_rd = 0, req_wr = 0, hit_rd = 0, hit_wr = 0, fills = 0, victims = 0, vwb_hits = 0, vwb_stall = 0,
            port_wait = 0;
    reg [2:0] prev = 0; reg prev_hit = 0;
    initial for (int i = 0; i < 8; i++) sc[i] = 0;
    always @(posedge clk) if (!reset) begin
        sc[st]++;
        for (int p = 0; p < PORTS; p++) begin
            if (up_rv[p] && !up_rr[p]) port_wait++;
            if (up_wv[p] && !up_wr[p]) port_wait++;
        end
        if (st == 1 && prev == 0) begin if (is_write) req_wr++; else req_rd++; end
        if (st == 1 && hit && prev != 1) begin if (is_write) hit_wr++; else hit_rd++; end
        if (prev == 1 && !prev_hit) begin
            if (st == 2) fills++;
            if (st == 5 && cont == 2) victims++;
            if (st == 5 && cont == 1) vwb_hits++;
            if (st == 1) vwb_stall++;
        end
        prev <= st; prev_hit <= hit;
    end
    final $display("PERF l2 %m req_rd=%0d req_wr=%0d hit_rd=%0d hit_wr=%0d fills=%0d victims=%0d vwb_hits=%0d vwb_stall=%0d port_wait=%0d idle=%0d serving=%0d fetching=%0d wait_data=%0d flush=%0d",
                   req_rd, req_wr, hit_rd, hit_wr, fills, victims, vwb_hits, vwb_stall, port_wait,
                   sc[0], sc[1], sc[2], sc[5], sc[3] + sc[4] + sc[6]);
endmodule

// ----------------------------------------------------------------------------------------------- shared memory
module smem_perf #(parameter LANES = 4) (
    input wire clk, input wire reset, input wire [LANES-1:0] rv, input wire [LANES-1:0] wv,
    input wire [LANES-1:0] rr, input wire [LANES-1:0] wr,
    input wire [LANES-1:0] rconf, input wire [LANES-1:0] wconf, input wire [LANES-1:0] rawconf
);
    longint busy = 0, conflict = 0, served = 0, requested = 0;
    always @(posedge clk) if (!reset) begin
        if (|rv || |wv) busy++;
        if (|rconf || |wconf || |rawconf) conflict++;
        served += $countones(rr) + $countones(wr);
        requested += $countones(rv) + $countones(wv);
    end
    final $display("PERF smem %m busy=%0d conflict=%0d lane_served=%0d lane_requested=%0d", busy, conflict, served, requested);
endmodule

// --------------------------------------------------------------------------------------------------------- divider
module div_perf (input wire clk, input wire reset, input wire busy);
    longint b = 0;
    always @(posedge clk) if (!reset && busy) b++;
    final $display("PERF div %m busy=%0d", b);
endmodule

// ------------------------------------------------------------------------------------------ external memory (gpu)
// Line traffic at the gpu ports (the testbench "DRAM"): one beat = one 4-word line. Handshake = valid && ready.
module ext_perf #(parameter DCH = 4, parameter PCH = 1) (
    input wire clk, input wire reset, input wire start, input wire done,
    input wire [DCH-1:0] rv, input wire [DCH-1:0] rr, input wire [DCH-1:0] wv, input wire [DCH-1:0] wr,
    input wire [PCH-1:0] pv, input wire [PCH-1:0] pr
);
    longint rd = 0, wrc = 0, rd_wait = 0, wr_wait = 0, prd = 0, after_done = 0;
    reg [DCH-1:0] prv = 0, pwv = 0; reg [PCH-1:0] ppv = 0; reg seen_start = 0;
    always @(posedge clk) if (!reset) begin
        if (start) seen_start <= 1;
        for (int c = 0; c < DCH; c++) begin
            if (rv[c] && rr[c] && !prv[c]) rd++;
            if (wv[c] && wr[c] && !pwv[c]) begin wrc++; if (done) after_done++; end
            if (rv[c] && !rr[c]) rd_wait++;
            if (wv[c] && !wr[c]) wr_wait++;
        end
        for (int c = 0; c < PCH; c++) if (pv[c] && pr[c] && !ppv[c]) prd++;
        prv <= rv & rr; pwv <= wv & wr; ppv <= pv & pr;
    end
    final $display("PERF ext %m line_reads=%0d line_writes=%0d read_wait=%0d write_wait=%0d prog_reads=%0d writes_after_done=%0d",
                   rd, wrc, rd_wait, wr_wait, prd, after_done);
endmodule

bind core core_perf #(.LANES(THREADS_PER_BLOCK), .WARPS(NUM_WARPS)) u_core_perf (
    .clk(clk), .reset(reset), .running(core_running), .valid_issue(valid_issue), .found(found_var_comb),
    .frontend_stall(frontend_stall), .fp_raw_stall(fp_raw_stall), .issue_hazard(issue_hazard),
    .ws(scheduler_instance.warp_state), .events(event_bus), .id_instruction(id_instruction),
    .flush_warp_mask(flush_warp_mask), .id_warp_id(id_warp_id), .ex_active_mask(ex_active_mask));
bind lsu lsu_perf #(.LANES(THREADS_PER_BLOCK), .WARPS(NUM_WARPS)) u_lsu_perf (
    .clk(clk), .reset(reset), .st(state), .pending(pending_threads), .req_valid(req_valid));
bind dcache dcache_perf u_dcache_perf (
    .clk(clk), .reset(reset), .st(state), .rv(core_read_valid), .rr(core_read_ready),
    .wv(core_write_valid), .wr(core_write_ready));
bind l2_cache l2_perf #(.PORTS(NUM_PORTS)) u_l2_perf (
    .clk(clk), .reset(reset), .st(state), .cont(cont), .hit(hit), .is_write(req_is_write),
    .up_rv(up_read_valid), .up_rr(up_read_ready), .up_wv(up_write_valid), .up_wr(up_write_ready));
bind shared_mem smem_perf #(.LANES(THREADS_PER_BLOCK)) u_smem_perf (
    .clk(clk), .reset(reset), .rv(read_valid), .wv(write_valid), .rr(read_ready), .wr(write_ready),
    .rconf(r_bank_conflict), .wconf(w_bank_conflict), .rawconf(raw_conflict));
bind divider div_perf u_div_perf (.clk(clk), .reset(reset), .busy(busy));
bind gpu ext_perf #(.DCH(DATA_MEM_NUM_CHANNELS), .PCH(PROGRAM_MEM_NUM_CHANNELS)) u_ext_perf (
    .clk(clk), .reset(reset), .start(start), .done(done),
    .rv(data_mem_read_valid), .rr(data_mem_read_ready), .wv(data_mem_write_valid), .wr(data_mem_write_ready),
    .pv(program_mem_read_valid), .pr(program_mem_read_ready));
