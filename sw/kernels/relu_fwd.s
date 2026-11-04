// Y[i] = max(X[i], 0)  for i < n.  One instruction: a float's bit pattern, read as a signed integer, has its sign.
.param X, Y, n
        CONST r0, 0
        MUL   r1, bid, nthr
        ADD   r1, r1, tid
        LDR   r2, r0, n
        CMP   r1, r2
        BRzp  done
        LDR   r3, r0, X
        ADD   r3, r3, r1
        LDR   r4, [r3]
        MAX   r4, r4, r0            // ReLU
        LDR   r5, r0, Y
        ADD   r5, r5, r1
        STR   r4, [r5]
done:   EXIT
