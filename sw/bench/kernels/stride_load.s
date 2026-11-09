// Coalescing: out[gid] = sum_k a[((k*T + gid) * S) & (F - 1)]  (int). The lanes of a warp are S words apart, so a
// warp load touches min(lanes, ceil(lanes * S / 4)) lines. F (a power of two) bounds the footprint.
.param a, out, S, T, F, iters
        CONST r0, 0
        CONST r1, 1
        MUL   r2, bid, nthr
        ADD   r2, r2, tid           // gid
        LDR   r3, r0, S
        LDR   r4, r0, T
        LDR   r5, r0, F
        SUB   r5, r5, r1            // F - 1
        LDR   r6, r0, a
        LDR   r7, r0, iters
        MUL   r8, r2, r3            // gid * S
        MUL   r9, r4, r3            // T * S
        CONST r10, 0
loop:   CMP   r7, r0
        BRz   fin
        AND   r12, r8, r5
        ADD   r12, r12, r6
        LDR   r13, [r12]
        ADD   r10, r10, r13
        ADD   r8, r8, r9
        SUB   r7, r7, r1
        JMP   loop
fin:    LDR   r12, r0, out
        ADD   r12, r12, r2
        STR   r10, [r12]
        EXIT
