// SGD step, i < n:  P[i] += neg_lr * G[i]     (neg_lr = -learning rate, one FMA)
.param P, G, neg_lr, n
        CONST r0, 0
        MUL   r1, bid, nthr
        ADD   r1, r1, tid
        LDR   r2, r0, n
        CMP   r1, r2
        BRzp  done
        LDR   r3, r0, P
        ADD   r3, r3, r1
        LDR   r4, [r3]
        LDR   r5, r0, G
        ADD   r5, r5, r1
        LDR   r6, [r5]
        LDR   r7, r0, neg_lr
        FMA   r4, r6, r7
        STR   r4, [r3]
done:   EXIT
