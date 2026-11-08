// out[C, R] = in[R, C]^T, one thread per element (threads = R * C, C = 1 << logC): coalesced reads, strided writes.
.param src, dst, R, C, logC
        CONST r0, 0
        CONST r1, 1
        MUL   r2, bid, nthr
        ADD   r2, r2, tid
        LDR   r3, r0, logC
        LDR   r4, r0, C
        LDR   r5, r0, R
        SHR   r6, r2, r3            // r
        SUB   r7, r4, r1
        AND   r7, r2, r7            // c
        LDR   r8, r0, src
        ADD   r8, r8, r2
        LDR   r9, [r8]
        MUL   r10, r7, r5
        ADD   r10, r10, r6          // c * R + r
        LDR   r8, r0, dst
        ADD   r8, r8, r10
        STR   r9, [r8]
        EXIT
