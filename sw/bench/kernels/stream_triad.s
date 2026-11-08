// STREAM triad: a[i] = b[i] + s * c[i]  (FP32 FMA), i = gid, gid + T, ... < n  (n a multiple of T)
.param a, b, c, s, n, T
        CONST r0, 0
        MUL   r2, bid, nthr
        ADD   r2, r2, tid
        LDR   r3, r0, n
        LDR   r4, r0, T
        LDR   r5, r0, a
        LDR   r6, r0, b
        LDR   r7, r0, c
        LDR   r8, r0, s
loop:   CMP   r2, r3
        BRzp  fin
        ADD   r9, r6, r2
        LDR   r10, [r9]
        ADD   r9, r7, r2
        LDR   r11, [r9]
        FMA   r10, r8, r11          // b + s * c
        ADD   r9, r5, r2
        STR   r10, [r9]
        ADD   r2, r2, r4
        JMP   loop
fin:    EXIT
