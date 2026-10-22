`default_nettype none
// Checkers for pc, scheduler, lsu, fetcher and victim_write_buffer.

module pc_sva #(parameter NW = 2, DEPTH = 8, SPW = 3) (
    input wire clk, input wire reset, input wire enable,
    input wire [$clog2(NW)-1:0] warp_id,
    input wire call, input wire ret, input wire nzp_we, input wire [2:0] alu_flags,
    input wire [SPW-1:0] stack_ptr [NW],
    input wire [2:0] nzp [NW]
);
    genvar w;
    generate for (w = 0; w < NW; w++) begin : g
        // A warp's return-stack pointer moves only on its own CALL (+1) / RET (-1).
        a_sp_call: assert property (@(posedge clk) disable iff (reset)
            (enable && warp_id == w && call && !ret) |=> (stack_ptr[w] == SPW'($past(stack_ptr[w]) + 1)))
            else $error("SVA pc: CALL did not push (warp %0d)", w);
        a_sp_ret: assert property (@(posedge clk) disable iff (reset)
            (enable && warp_id == w && ret && !call) |=> (stack_ptr[w] == SPW'($past(stack_ptr[w]) - 1)))
            else $error("SVA pc: RET did not pop (warp %0d)", w);
        a_sp_stable: assert property (@(posedge clk) disable iff (reset)
            !(enable && warp_id == w && (call || ret)) |=> $stable(stack_ptr[w]))
            else $error("SVA pc: stack_ptr changed without CALL/RET (warp %0d)", w);
        // CMP must latch the ALU flag bits into this warp's NZP.
        a_nzp_update: assert property (@(posedge clk) disable iff (reset)
            (enable && warp_id == w && nzp_we) |=> (nzp[w] == $past(alu_flags)))
            else $error("SVA pc: NZP not updated by CMP (warp %0d)", w);
        // NZP only changes when a flag-writing instruction executes for this warp.
        a_nzp_stable: assert property (@(posedge clk) disable iff (reset)
            !(enable && warp_id == w && nzp_we) |=> $stable(nzp[w]))
            else $error("SVA pc: NZP changed without CMP (warp %0d)", w);
    end endgenerate
endmodule

module sched_sva #(parameter NW = 2, DEPTH = 4, PW = 3) (
    input wire clk, input wire reset, input wire [PW-1:0] stack_ptr [NW]
);
    genvar w;
    generate for (w = 0; w < NW; w++) begin : g
        // The divergence stack silently wraps/overflows past DEPTH.
        a_depth: assert property (@(posedge clk) disable iff (reset) stack_ptr[w] <= DEPTH)
            else $error("SVA scheduler: divergence stack overflow (warp %0d, ptr=%0d > %0d)", w, stack_ptr[w], DEPTH);
    end endgenerate
endmodule

module lsu_sva #(parameter WPB = 4) (
    input wire clk, input wire reset, input wire mem_write_valid, input wire [WPB-1:0] mem_write_strobe,
    input wire mem_read_valid
);
    a_wr_strobe: assert property (@(posedge clk) disable iff (reset) mem_write_valid |-> (mem_write_strobe != 0))
        else $error("SVA lsu: memory write with empty strobe");
    a_rd_wr_excl: assert property (@(posedge clk) disable iff (reset) !(mem_read_valid && mem_write_valid))
        else $error("SVA lsu: simultaneous read and write request");
endmodule

module fetcher_sva (
    input wire clk, input wire reset, input wire flush,
    input wire mem_read_valid, input wire instruction_valid, input wire consume
);
    // A fetch is never in flight while a completed instruction is being held.
    a_no_overlap: assert property (@(posedge clk) disable iff (reset || flush) !(mem_read_valid && instruction_valid))
        else $error("SVA fetcher: fetch outstanding while instruction held");
endmodule

module vwb_sva (
    input wire clk, input wire reset, input wire push_valid, input wire push_ready,
    input wire mem_write_valid, input wire mem_write_ready
);
    a_no_drop: assert property (@(posedge clk) disable iff (reset) push_valid |-> push_ready)
        else $error("SVA vwb: push while full (writeback lost)");
    // A drain request is held until it is accepted.
    a_hold: assert property (@(posedge clk) disable iff (reset) (mem_write_valid && !mem_write_ready) |=> mem_write_valid)
        else $error("SVA vwb: mem_write_valid dropped before ready");
endmodule
