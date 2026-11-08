// Histogram: hist[data[i]] += 1 with ATOM_ADD, i = gid, gid + T, ... < n (n a multiple of T; data[i] < bins).
.param data, hist, n, T
        CONST r0, 0
        CONST r1, 1
        MUL   r2, bid, nthr
        ADD   r2, r2, tid
        LDR   r3, r0, n
        LDR   r4, r0, T
        LDR   r5, r0, data
        LDR   r6, r0, hist
loop:   CMP   r2, r3
        BRzp  fin
        ADD   r8, r5, r2
        LDR   r9, [r8]
        ADD   r9, r9, r6
        ATOM_ADD r10, r9, r1
        ADD   r2, r2, r4
        JMP   loop
fin:    EXIT
