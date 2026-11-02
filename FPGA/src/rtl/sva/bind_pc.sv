`default_nettype none
bind pc pc_sva #(.NW(NUM_WARPS), .DEPTH(STACK_DEPTH), .SPW($clog2(STACK_DEPTH))) u_pc_sva (
    .clk(clk), .reset(reset), .enable(enable), .warp_id(warp_id), .call(decoded_call), .ret(decoded_ret_fn),
    .nzp_we(decoded_nzp_write_enable), .alu_flags(alu_out[2:0]), .stack_ptr(stack_ptr), .nzp(nzp));
