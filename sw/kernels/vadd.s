// c[i] = a[i] + b[i]  (FP32), i = global thread id, threads >= n
.param a, b, c, n
        CONST r0, 0
        MUL   r1, bid, nthr
        ADD   r1, r1, tid           // r1 = global id
        LDR   r2, r0, n
        CMP   r1, r2
        BRzp  done                  // gid >= n (unsigned compare)
        LDR   r3, r0, a
        LDR   r4, r0, b
        LDR   r5, r0, c
        ADD   r3, r3, r1
        ADD   r4, r4, r1
        ADD   r5, r5, r1
        LDR   r6, [r3]
        LDR   r7, [r4]
        FADD  r6, r6, r7
        STR   r6, [r5]
done:   EXIT
