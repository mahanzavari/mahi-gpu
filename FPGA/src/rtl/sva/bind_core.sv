`default_nettype none
bind core core_sva #(.NW(NUM_WARPS), .AW(PROGRAM_MEM_ADDR_BITS), .TPB(THREADS_PER_BLOCK)) u_core_sva (
    .clk(clk), .reset(reset), .valid_issue(valid_issue), .if_instruction_valid(if_instruction_valid),
    .sched_warp_id(sched_warp_id), .if_pc(if_pc), .if_fetched_pc(if_fetched_pc),
    .sched_active_mask(sched_active_mask), .flush_warp_mask(flush_warp_mask), .fp_raw_stall(fp_raw_stall),
    .id_warp_id(id_warp_id), .id_pc(id_pc), .id_active_mask(id_active_mask));
