// out[C, R] = in[R, C]^T through shared memory: block b (16 threads) moves the 4x4 tile (b >> logCT, b & (CT-1)),
// CT = C / 4 = 1 << logCT; thread (ty, tx) = (tid >> 2, tid & 3) reads in[4tr+ty, 4tc+tx] (coalesced), and after
// the barrier writes out[4tc+ty, 4tr+tx] = sh[4tx + ty] (coalesced). threads = R * C.
.param src, dst, R, C, logCT
        CONST r0, 0
        CONST r1, 1
        CONST r20, 2
        CONST r21, 3
        LDR   r3, r0, logCT
        LDR   r4, r0, C
        LDR   r5, r0, R
        SHR   r6, bid, r3           // tr
        SHL   r7, r1, r3
        SUB   r7, r7, r1
        AND   r7, bid, r7           // tc
        SHR   r8, tid, r20          // ty
        AND   r9, tid, r21          // tx
        SHL   r10, r6, r20
        ADD   r10, r10, r8
        MUL   r10, r10, r4
        SHL   r11, r7, r20
        ADD   r11, r11, r9
        ADD   r10, r10, r11
        LDR   r11, r0, src
        ADD   r10, r10, r11
        LDR   r12, [r10]
        STSH  r12, tid
        SYNC
        SHL   r13, r9, r20
        ADD   r13, r13, r8
        LDSH  r12, r13
        SHL   r10, r7, r20
        ADD   r10, r10, r8          // out row 4tc + ty
        MUL   r10, r10, r5
        SHL   r11, r6, r20
        ADD   r11, r11, r9          // out col 4tr + tx
        ADD   r10, r10, r11
        LDR   r11, r0, dst
        ADD   r10, r10, r11
        STR   r12, [r10]
        EXIT
