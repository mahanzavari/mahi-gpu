`default_nettype none
bind divider div_sva #(.LANES(LANES), .DATA_BITS(DATA_BITS)) u_div_sva (
    .clk(clk), .reset(reset), .start(start), .busy(busy), .done(done), .ack(ack));
