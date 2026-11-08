// C[M, N] = A[M, K] @ B[K, N]  (FP32, row-major), one thread per element: launch threads = M * N, N = 1 << logN.
// Every operand comes from global memory (through the 16-line L1).
.param A, B, C, K, N, logN
        CONST r0, 0
        CONST r1, 1
        MUL   r2, bid, nthr
        ADD   r2, r2, tid           // gid
        LDR   r3, r0, logN
        LDR   r6, r0, N
        LDR   r7, r0, K
        SHR   r4, r2, r3            // row
        SUB   r5, r6, r1
        AND   r5, r2, r5            // col
        LDR   r8, r0, A
        MUL   r9, r4, r7
        ADD   r8, r8, r9            // &A[row, 0]
        LDR   r9, r0, B
        ADD   r9, r9, r5            // &B[0, col]
        CONST r10, 0
        MOV   r11, r7               // k
loop:   CMP   r11, r0
        BRz   fin
        LDR   r12, [r8]
        LDR   r13, [r9]
        FMA   r10, r12, r13
        ADD   r8, r8, r1
        ADD   r9, r9, r6
        SUB   r11, r11, r1
        JMP   loop
fin:    LDR   r12, r0, C
        ADD   r12, r12, r2
        STR   r10, [r12]
        EXIT
