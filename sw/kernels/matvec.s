// y[i] = sum_k W[i*k_dim + k] * x[k] + b[i]   (FP32, FMA), i = global thread id < m
.param W, x, b, y, m, k_dim
        CONST r0, 0
        MUL   r1, bid, nthr
        ADD   r1, r1, tid           // r1 = i
        LDR   r2, r0, m
        CMP   r1, r2
        BRzp  done
        LDR   r3, r0, k_dim         // r3 = K
        LDR   r4, r0, W
        MUL   r5, r1, r3
        ADD   r4, r4, r5            // r4 = &W[i][0]
        LDR   r6, r0, x             // r6 = &x[0]
        LDR   r7, r0, b
        ADD   r7, r7, r1
        LDR   r8, [r7]              // r8 = acc = b[i]
        CONST r9, 0                 // k
        CONST r10, 1
loop:   CMP   r9, r3
        BRzp  store
        LDR   r11, [r4]
        LDR   r12, [r6]
        FMA   r8, r11, r12          // acc += W[i][k] * x[k]
        ADD   r4, r4, r10
        ADD   r6, r6, r10
        ADD   r9, r9, r10
        JMP   loop
store:  LDR   r13, r0, y
        ADD   r13, r13, r1
        STR   r8, [r13]
done:   EXIT
