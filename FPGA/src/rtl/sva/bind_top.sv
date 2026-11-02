`default_nettype none
bind gpu_mem_subsys memsub_sva u_memsub_sva (
    .clk(clk), .reset(reset), .h_en(h_en), .h_bank(h_bank),
    .p_csb0(p_csb0), .p_csb1(p_csb1), .d_csb0(d_csb0), .d_csb1(d_csb1),
    .p_state(p_state), .d_state(d_state),
    .pm_rv(pm_rv), .pm_rr(pm_rr), .dm_rv(dm_rv), .dm_rr(dm_rr), .dm_wv(dm_wv), .dm_wr(dm_wr));
bind gpu_asic_top top_sva u_top_sva (
    .clk(clk), .reset(reset), .wb_ack_o(wb_ack_o), .h_state(h_state), .run_active(run_active),
    .mem_busy(mem_busy), .rst_cnt(rst_cnt));
