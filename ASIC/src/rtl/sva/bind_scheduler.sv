`default_nettype none
bind scheduler sched_sva #(.NW(NUM_WARPS), .DEPTH(STACK_DEPTH), .PW($clog2(STACK_DEPTH+1))) u_sched_sva (
    .clk(clk), .reset(reset), .stack_ptr(stack_ptr));
