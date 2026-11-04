// Linear layer backward, input gradient:  dX[b, k] = sum_j dY[b, j] * W[j, k]      (one thread per sample b < B)
.param dY, W, dX, B, K, N
        CONST r0, 0
        CONST r20, 1
        MUL   r1, bid, nthr
        ADD   r1, r1, tid           // b
        LDR   r2, r0, B
        CMP   r1, r2
        BRzp  done
        LDR   r3, r0, K
        LDR   r4, r0, N
        LDR   r5, r0, dY
        MUL   r6, r1, r4
        ADD   r5, r5, r6            // &dY[b, 0]
        LDR   r7, r0, dX
        MUL   r6, r1, r3
        ADD   r7, r7, r6            // &dX[b, 0]
        LDR   r8, r0, W             // &W[0, k]
        CONST r10, 0                // k
kloop:  CMP   r10, r3
        BRzp  done
        CONST r11, 0                // acc = +0.0
        MOV   r12, r5               // &dY[b, j]
        MOV   r13, r8               // &W[j, k]
        CONST r14, 0                // j
jloop:  CMP   r14, r4
        BRzp  jend
        LDR   r15, [r12]
        LDR   r16, [r13]
        FMA   r11, r15, r16         // acc += dY[b, j] * W[j, k]
        ADD   r12, r12, r20
        ADD   r13, r13, r3          // next row of W
        ADD   r14, r14, r20
        JMP   jloop
jend:   STR   r11, [r7]
        ADD   r7, r7, r20
        ADD   r8, r8, r20
        ADD   r10, r10, r20
        JMP   kloop
done:   EXIT
