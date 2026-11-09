// 3-point stencil: y[i] = 0.25*x[i-1] + 0.5*x[i] + 0.25*x[i+1] for 1 <= i < n-1, i = 1 + gid, 1 + gid + T, ...
// (FP32). n - 2 must be a multiple of T.
.param x, y, n, T
        CONST r0, 0
        CONST r1, 1
        MUL   r2, bid, nthr
        ADD   r2, r2, tid
        ADD   r2, r2, r1            // i = gid + 1
        LDR   r3, r0, n
        SUB   r3, r3, r1            // n - 1
        LDR   r4, r0, T
        LDR   r5, r0, x
        LDR   r6, r0, y
        LIF   r7, 0.25
        LIF   r8, 0.5
loop:   CMP   r2, r3
        BRzp  fin
        ADD   r9, r5, r2
        LDR   r10, [r9 + -1]
        LDR   r11, [r9]
        LDR   r12, [r9 + 1]
        FMUL  r13, r10, r7
        FMA   r13, r11, r8
        FMA   r13, r12, r7
        ADD   r9, r6, r2
        STR   r13, [r9]
        ADD   r2, r2, r4
        JMP   loop
fin:    EXIT
