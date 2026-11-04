// Mean squared error, per element i < n:  d = Y - T;  E[i] = d * d;  dY[i] = d * scale   (scale = 2 / n for the mean)
// The loss is sum(E) / n.
.param Y, T, dY, E, n, scale
        CONST r0, 0
        MUL   r1, bid, nthr
        ADD   r1, r1, tid
        LDR   r2, r0, n
        CMP   r1, r2
        BRzp  done
        LDR   r3, r0, Y
        ADD   r3, r3, r1
        LDR   r4, [r3]
        LDR   r3, r0, T
        ADD   r3, r3, r1
        LDR   r5, [r3]
        FSUB  r6, r4, r5            // d
        FMUL  r7, r6, r6
        LDR   r3, r0, E
        ADD   r3, r3, r1
        STR   r7, [r3]
        LDR   r8, r0, scale
        FMUL  r7, r6, r8
        LDR   r3, r0, dY
        ADD   r3, r3, r1
        STR   r7, [r3]
done:   EXIT
