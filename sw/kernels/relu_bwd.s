// dX[i] = dY[i] if Z[i] > 0 else 0   (Z = the pre-activation), branch-free.  dX may be the same buffer as dY.
.param Z, dY, dX, n
        CONST r0, 0
        CONST r9, 31
        MUL   r1, bid, nthr
        ADD   r1, r1, tid
        LDR   r2, r0, n
        CMP   r1, r2
        BRzp  done
        LDR   r3, r0, Z
        ADD   r3, r3, r1
        LDR   r4, [r3]              // z bits
        MAX   r4, r4, r0            // relu(z): 0 for z <= 0, including -0.0 (0x80000000 is negative as an integer)
        SUB   r4, r0, r4            // negative exactly when z > 0
        SHR   r4, r4, r9            // 1 when z > 0
        NEG   r4, r4                // all-ones mask or 0
        LDR   r5, r0, dY
        ADD   r5, r5, r1
        LDR   r6, [r5]
        AND   r6, r6, r4
        LDR   r7, r0, dX
        ADD   r7, r7, r1
        STR   r6, [r7]
done:   EXIT
