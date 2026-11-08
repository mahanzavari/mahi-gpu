// SIMD efficiency: lanes with (tid & mask) == 0 run a `work`-iteration loop, the others skip it and wait at the join
// point. mask = 0: no divergence; 1: half the lanes work; 3: one lane in four. out[gid] = gid (+ work if it worked).
.param out, mask, work
        CONST r0, 0
        CONST r1, 1
        MUL   r2, bid, nthr
        ADD   r2, r2, tid
        MOV   r9, r2
        LDR   r3, r0, mask
        AND   r3, tid, r3
        CMP   r3, r0
        BRnp  join
        LDR   r4, r0, work
wl:     ADD   r9, r9, r1
        SUB   r4, r4, r1
        CMP   r4, r0
        BRnp  wl                    // the exit falls through to the join point (reconvergence)
join:   LDR   r5, r0, out
        ADD   r5, r5, r2
        STR   r9, [r5]
        EXIT
