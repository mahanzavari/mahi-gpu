// Atomic throughput under contention: iters times, ATOM_ADD hist[(gid + k*T) & (bins - 1)] += 1.
// bins = 1: every lane of every warp hits one word; bins >= lanes: no two lanes of a warp share a word.
.param hist, bins, T, iters
        CONST r0, 0
        CONST r1, 1
        MUL   r2, bid, nthr
        ADD   r2, r2, tid
        LDR   r3, r0, bins
        SUB   r3, r3, r1            // bins - 1
        LDR   r4, r0, T
        LDR   r5, r0, hist
        LDR   r7, r0, iters
loop:   CMP   r7, r0
        BRz   fin
        AND   r8, r2, r3
        ADD   r8, r8, r5
        ATOM_ADD r9, r8, r1
        ADD   r2, r2, r4
        SUB   r7, r7, r1
        JMP   loop
fin:    EXIT
