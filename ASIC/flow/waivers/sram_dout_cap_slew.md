# Waiver: SRAM `dout1` output cap and slew (mini profile, `place_1029_1604`)

**What is waived.** The `dout1[*]` read-port output pins of the three `sky130_sram_2kbyte_1rw1r_32x512_8` macros exceed the macro liberty's
`max_capacitance` (0.02756 pF) after detailed routing: 36 pins at TT, 39 at SS (`checks.rpt`, "max capacitance"). At the slow corner
the same pins carry an output slew above the library's 0.5 ns `max_transition`, up to 6.0 ns (`mem_inst.dmem.macro/dout1[17]`);
128 pins of the whole design are above 2 ns at max_ss, most of them on these nets.

**Why it is acceptable here (not a claim of silicon margin):**
- Timing is met with these slews included: worst setup +3.274 ns (max_ss), worst hold +0.271 ns (max_ff), all 9 corners, with the
  OpenRAM-characterised TT/SS/FF libraries (`flow/openram/libs/`).
- The nets are read-only data outputs into registers on a 40 ns clock; only the access-time path sees the slow edge.
- The slew beyond 27.6 fF is a linear extrapolation of the OpenRAM table (2.05 ns at 27.6 fF), so the 6 ns figure is pessimistic and is outside the library's characterised range.

**Cause (measured).** Pin plus buffer load is about 6 fF; the routed wire is 33-63 fF. The post-global-route repair buffered these nets
but works from the global-route estimate; the detailed router then detours (net `mem_inst.d_dout1[10]` extends about 90 um west of its loads).
Nothing in the flow repairs after detailed routing.

**Not tried / to close it for real:** an explicit buffer at each `dout1` pin in the SRAM wrapper, a macro placement halo
(`PL_MACRO_HALO`, key not yet verified for this LibreLane), or a repair step after detailed routing. Re-run the checks after any of them.

Related, separate waiver for the macro-internal Magic DRC boxes: `openram_2kb_macro_drc_rules.txt` (`make signoff-drc`).
Also known: the 60 SRAM address pins with a 0.04 ns `max_transition` in the OpenRAM liberty always violate (a model artifact).
