`default_nettype none
// Assertions bound into core (see sva/bind.sv). Pure checkers: no RTL changes.
module core_sva #(parameter NW = 2, AW = 12, TPB = 4) (
    input wire clk, input wire reset,
    input wire valid_issue, input wire if_instruction_valid,
    input wire [$clog2(NW)-1:0] sched_warp_id, input wire [AW-1:0] if_pc, input wire [AW-1:0] if_fetched_pc,
    input wire [TPB-1:0] sched_active_mask,
    input wire [NW-1:0] flush_warp_mask, input wire fp_raw_stall,
    input wire [$clog2(NW)-1:0] id_warp_id, input wire [AW-1:0] id_pc, input wire [TPB-1:0] id_active_mask
);
    // A fresh instruction handed to the pipeline must be for the PC the
    // scheduler is issuing (fetch/issue skew: warp A's instruction issued as B's).
    a_issue_pc_match: assert property (@(posedge clk) disable iff (reset)
        valid_issue |-> (if_instruction_valid && if_fetched_pc == if_pc))
        else $error("SVA core: issuing PC %0h but fetched instruction is for PC %0h", if_pc, if_fetched_pc);

    // No dropped instruction: every issue that is not flushed for its OWN warp
    // must land in the ID latch next cycle (the fetcher already consumed it).
    a_issue_not_dropped: assert property (@(posedge clk) disable iff (reset)
        (valid_issue && !flush_warp_mask[sched_warp_id])
        |=> (id_warp_id == $past(sched_warp_id) && id_pc == $past(if_pc) && id_active_mask == $past(sched_active_mask)))
        else $error("SVA core: issued instruction dropped before ID (warp %0d pc %0h)", $past(sched_warp_id), $past(if_pc));

    // Issued masks are never empty.
    a_issue_mask_nonzero: assert property (@(posedge clk) disable iff (reset)
        valid_issue |-> (sched_active_mask != 0))
        else $error("SVA core: issue with empty active mask");
endmodule
