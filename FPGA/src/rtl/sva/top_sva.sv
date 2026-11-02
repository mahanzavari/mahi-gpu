`default_nettype none
// Checkers for the chip top (gpu_asic_top) and its memory subsystem. Bound, no RTL edits.

module memsub_sva (
    input wire clk, input wire reset,
    input wire h_en, input wire h_bank,
    input wire p_csb0, input wire p_csb1, input wire d_csb0, input wire d_csb1,
    input wire [2:0] p_state, input wire [2:0] d_state,
    input wire pm_rv, input wire pm_rr, input wire dm_rv, input wire dm_rr, input wire dm_wv, input wire dm_wr
);
    localparam S_IDLE = 3'd0;
    // The host only ever runs while both GPU FSMs are idle (the top refuses it otherwise).
    a_host_gpu_idle: assert property (@(posedge clk) disable iff (reset) h_en |-> (p_state == S_IDLE && d_state == S_IDLE))
        else $error("SVA memsub: host request while a GPU transaction is in flight");
    // A host access to one bank never selects the other bank's ports.
    a_host_pmem_only: assert property (@(posedge clk) disable iff (reset) (h_en && !h_bank) |-> (d_csb0 && d_csb1))
        else $error("SVA memsub: host PMEM access drove DMEM ports");
    a_host_dmem_only: assert property (@(posedge clk) disable iff (reset) (h_en && h_bank) |-> (p_csb0 && p_csb1))
        else $error("SVA memsub: host DMEM access drove PMEM ports");
    // The GPU never writes program memory (port 0 of PMEM is host-only).
    a_pmem_gpu_ro: assert property (@(posedge clk) disable iff (reset) !h_en |-> p_csb0)
        else $error("SVA memsub: PMEM port 0 written by the GPU side");
    // Ready is held until valid drops, then released the next cycle; read and write ready never overlap.
    a_pm_rr_drop: assert property (@(posedge clk) disable iff (reset) (pm_rr && !pm_rv) |=> !pm_rr)
        else $error("SVA memsub: pm_rr stuck after valid dropped");
    a_dm_rr_drop: assert property (@(posedge clk) disable iff (reset) (dm_rr && !dm_rv) |=> !dm_rr)
        else $error("SVA memsub: dm_rr stuck after valid dropped");
    a_dm_wr_drop: assert property (@(posedge clk) disable iff (reset) (dm_wr && !dm_wv) |=> !dm_wr)
        else $error("SVA memsub: dm_wr stuck after valid dropped");
    a_dm_excl: assert property (@(posedge clk) disable iff (reset) !(dm_rr && dm_wr))
        else $error("SVA memsub: dm read-ready and write-ready together");
    // Ready only while its request is still valid or just dropped (never spontaneous).
    a_pm_rr_cause: assert property (@(posedge clk) disable iff (reset) $rose(pm_rr) |-> $past(pm_rv))
        else $error("SVA memsub: pm_rr without a request");
    a_dm_rr_cause: assert property (@(posedge clk) disable iff (reset) $rose(dm_rr) |-> $past(dm_rv))
        else $error("SVA memsub: dm_rr without a request");
    a_dm_wr_cause: assert property (@(posedge clk) disable iff (reset) $rose(dm_wr) |-> $past(dm_wv))
        else $error("SVA memsub: dm_wr without a request");
endmodule

module top_sva (
    input wire clk, input wire reset,
    input wire wb_ack_o, input wire [1:0] h_state, input wire run_active, input wire mem_busy,
    input wire [3:0] rst_cnt
);
    localparam H_ISSUE = 2'd1;
    a_ack_pulse: assert property (@(posedge clk) disable iff (reset) wb_ack_o |=> !wb_ack_o)
        else $error("SVA top: wb_ack_o held for two cycles");
    // The host never reaches the SRAM ports while the GPU runs, is in a memory transaction, or is in soft reset.
    a_host_exclusive: assert property (@(posedge clk) disable iff (reset) (h_state == H_ISSUE) |-> !(run_active || mem_busy || rst_cnt != 0))
        else $error("SVA top: host memory access while GPU active");
endmodule
