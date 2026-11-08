// Gather: out[i] = a[idx[i]], i = gid, gid + T, ... < n  (n a multiple of T). Random idx: uncoalesced, cache-hostile.
.param a, idx, out, n, T
        CONST r0, 0
        MUL   r2, bid, nthr
        ADD   r2, r2, tid
        LDR   r3, r0, n
        LDR   r4, r0, T
        LDR   r5, r0, a
        LDR   r6, r0, idx
        LDR   r7, r0, out
loop:   CMP   r2, r3
        BRzp  fin
        ADD   r9, r6, r2
        LDR   r10, [r9]             // j = idx[i]
        ADD   r10, r5, r10
        LDR   r11, [r10]            // a[j]
        ADD   r9, r7, r2
        STR   r11, [r9]
        ADD   r2, r2, r4
        JMP   loop
fin:    EXIT
