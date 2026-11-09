// Linear layer backward, parameter gradients (summed over the batch):
//   db[j] = sum_b dY[b, j]        dW[j, k] = sum_b dY[b, j] * X[b, k]          (one thread per output j < N)
.param dY, X, dW, db, B, K, N
        CONST r0, 0
        CONST r20, 1
        MUL   r1, bid, nthr
        ADD   r1, r1, tid           // j
        LDR   r4, r0, N
        CMP   r1, r4
        BRzp  done
        LDR   r2, r0, B
        LDR   r3, r0, K
        LDR   r5, r0, dY
        ADD   r5, r5, r1            // &dY[0, j]
        // db[j]
        CONST r11, 0
        MOV   r12, r5
        CONST r14, 0                // b
bloop:  CMP   r14, r2
        BRzp  bend
        LDR   r15, [r12]
        FADD  r11, r11, r15
        ADD   r12, r12, r4          // next sample
        ADD   r14, r14, r20
        JMP   bloop
bend:   LDR   r6, r0, db
        ADD   r6, r6, r1
        STR   r11, [r6]
        // dW[j, :]
        LDR   r7, r0, dW
        MUL   r6, r1, r3
        ADD   r7, r7, r6            // &dW[j, 0]
        LDR   r8, r0, X             // &X[0, k]
        CONST r10, 0                // k
kloop:  CMP   r10, r3
        BRzp  done
        CONST r11, 0
        MOV   r12, r5               // &dY[b, j]
        MOV   r13, r8               // &X[b, k]
        CONST r14, 0                // b
kb:     CMP   r14, r2
        BRzp  kbend
        LDR   r15, [r12]
        LDR   r16, [r13]
        FMA   r11, r15, r16
        ADD   r12, r12, r4
        ADD   r13, r13, r3
        ADD   r14, r14, r20
        JMP   kb
kbend:  STR   r11, [r7]
        ADD   r7, r7, r20
        ADD   r8, r8, r20
        ADD   r10, r10, r20
        JMP   kloop
done:   EXIT
