`default_nettype none
bind victim_write_buffer vwb_sva u_vwb_sva (
    .clk(clk), .reset(reset), .push_valid(push_valid), .push_ready(push_ready),
    .mem_write_valid(mem_write_valid), .mem_write_ready(mem_write_ready));
