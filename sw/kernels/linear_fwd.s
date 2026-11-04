// Linear layer forward:  Y[b, j] = bias[j] + sum_k X[b, k] * W[j, k]      (FP32, row-major, W is [N, K] like PyTorch)
// One thread per sample b < B; loops over j < N and k < K (the same trip counts in every thread).
.param X, W, bias, Y, B, K, N
        CONST r0, 0
        CONST r20, 1
        MUL   r1, bid, nthr
        ADD   r1, r1, tid           // b
        LDR   r2, r0, B
        CMP   r1, r2
        BRzp  done
        LDR   r3, r0, K
        LDR   r4, r0, N
        LDR   r5, r0, X
        MUL   r6, r1, r3
        ADD   r5, r5, r6            // &X[b, 0]
        LDR   r7, r0, Y
        MUL   r6, r1, r4
        ADD   r7, r7, r6            // &Y[b, 0]
        LDR   r8, r0, W             // walks W row after row
        LDR   r9, r0, bias          // &bias[j]
        CONST r10, 0                // j
jloop:  CMP   r10, r4
        BRzp  done
        LDR   r11, [r9]             // acc = bias[j]
        MOV   r12, r5               // &X[b, k]
        CONST r13, 0                // k
kloop:  CMP   r13, r3
        BRzp  kend
        LDR   r14, [r12]
        LDR   r15, [r8]
        FMA   r11, r14, r15         // acc += X[b, k] * W[j, k]
        ADD   r12, r12, r20
        ADD   r8, r8, r20
        ADD   r13, r13, r20
        JMP   kloop
kend:   STR   r11, [r7]
        ADD   r7, r7, r20
        ADD   r9, r9, r20
        ADD   r10, r10, r20
        JMP   jloop
done:   EXIT
