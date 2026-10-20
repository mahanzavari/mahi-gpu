`default_nettype none
bind fetcher fetcher_sva u_fetcher_sva (
    .clk(clk), .reset(reset), .flush(flush), .mem_read_valid(mem_read_valid),
    .instruction_valid(instruction_valid), .consume(consume));
