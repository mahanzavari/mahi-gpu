// Write bandwidth: a[i] = v, i = gid, gid + T, ... < n  (n a multiple of T)
.param a, v, n, T
        CONST r0, 0
        MUL   r2, bid, nthr
        ADD   r2, r2, tid
        LDR   r3, r0, n
        LDR   r4, r0, T
        LDR   r5, r0, a
        LDR   r6, r0, v
loop:   CMP   r2, r3
        BRzp  fin
        ADD   r9, r5, r2
        STR   r6, [r9]
        ADD   r2, r2, r4
        JMP   loop
fin:    EXIT
