// C[M, N] = A[M, K] @ B[K, N] with shared-memory tiles: block b computes the 4x4 tile (b >> logNT, b & (NT-1)) of C,
// NT = N / 4 = 1 << logNT. The block (16 threads, nthr = 16) stages A[4 rows, K] and B[K, 4 cols] in shared memory
// (8K words), then thread (ty, tx) = (tid >> 2, tid & 3) runs its dot product from shared memory. Same FMA order as
// gemm_naive, so C is bit-identical. Launch threads = M * N.
.param A, B, C, K, N, logNT
        CONST r0, 0
        CONST r1, 1
        CONST r20, 2
        CONST r21, 3
        LDR   r3, r0, logNT
        LDR   r6, r0, N
        LDR   r7, r0, K
        SHR   r4, bid, r3           // tile row
        SHL   r5, r1, r3
        SUB   r5, r5, r1
        AND   r5, bid, r5           // tile col
        SHL   r22, r7, r20          // 4K
        // stage A rows 4*tr .. 4*tr+3 (contiguous: 4K words from &A[4*tr, 0])
        LDR   r8, r0, A
        MUL   r9, r4, r22
        ADD   r8, r8, r9
        MOV   r10, tid
sa:     CMP   r10, r22
        BRzp  sad
        ADD   r11, r8, r10
        LDR   r12, [r11]
        STSH  r12, r10
        ADD   r10, r10, nthr
        JMP   sa
sad:    // stage B[k, 4*tc + c] at sh[4K + 4k + c], idx = 4k + c
        LDR   r8, r0, B
        SHL   r9, r5, r20
        ADD   r8, r8, r9            // &B[0, 4*tc]
        MOV   r10, tid
sb:     CMP   r10, r22
        BRzp  sbd
        SHR   r11, r10, r20         // k
        MUL   r11, r11, r6
        AND   r12, r10, r21         // c
        ADD   r11, r11, r12
        ADD   r11, r11, r8
        LDR   r12, [r11]
        ADD   r13, r10, r22
        STSH  r12, r13
        ADD   r10, r10, nthr
        JMP   sb
sbd:    SYNC
        SHR   r14, tid, r20         // ty
        AND   r15, tid, r21         // tx
        MUL   r8, r14, r7           // sh &A_tile[ty, 0]
        ADD   r9, r22, r15          // sh &B_tile[0, tx]
        CONST r10, 0
        CONST r16, 4
        MOV   r11, r7
loop:   CMP   r11, r0
        BRz   fin
        LDSH  r12, r8
        LDSH  r13, r9
        FMA   r10, r12, r13
        ADD   r8, r8, r1
        ADD   r9, r9, r16
        SUB   r11, r11, r1
        JMP   loop
fin:    SHL   r12, r4, r20
        ADD   r12, r12, r14         // row = 4*tr + ty
        MUL   r12, r12, r6
        SHL   r13, r5, r20
        ADD   r13, r13, r15         // col = 4*tc + tx
        ADD   r12, r12, r13
        LDR   r13, r0, C
        ADD   r12, r12, r13
        STR   r10, [r12]
        EXIT
