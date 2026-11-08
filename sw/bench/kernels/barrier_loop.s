// Barrier cost: iters rounds of (one ADD, SYNC). out[gid] = iters.
.param out, iters
        CONST r0, 0
        CONST r1, 1
        MUL   r2, bid, nthr
        ADD   r2, r2, tid
        LDR   r7, r0, iters
        CONST r10, 0
loop:   CMP   r7, r0
        BRz   fin
        ADD   r10, r10, r1
        SYNC
        SUB   r7, r7, r1
        JMP   loop
fin:    LDR   r12, r0, out
        ADD   r12, r12, r2
        STR   r10, [r12]
        EXIT
