`default_nettype none
bind lsu lsu_sva #(.WPB(WORDS_PER_BLOCK)) u_lsu_sva (
    .clk(clk), .reset(reset), .mem_write_valid(mem_write_valid), .mem_write_strobe(mem_write_strobe),
    .mem_read_valid(mem_read_valid));
