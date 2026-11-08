// Inclusive prefix sum of each block's nthr elements (int): y[gid] = sum_{j <= tid} x[bid*nthr + j].
// Hillis-Steele in shared memory, log2(nthr) rounds, branch-free (a lane with tid < off adds 0 from a clamped index).
.param x, y
        CONST r0, 0
        CONST r1, 1
        CONST r15, 31
        MUL   r2, bid, nthr
        ADD   r2, r2, tid
        LDR   r3, r0, x
        ADD   r3, r3, r2
        LDR   r4, [r3]
        STSH  r4, tid
        SYNC
        CONST r5, 1                 // off
loop:   CMP   r5, nthr
        BRzp  fin
        SUB   r6, tid, r5
        SHR   r7, r6, r15           // 1 if tid < off
        SUB   r7, r7, r1            // all ones if tid >= off, else 0
        MAX   r6, r6, r0            // clamped index
        LDSH  r8, r6
        AND   r8, r8, r7
        LDSH  r9, tid
        ADD   r9, r9, r8
        SYNC
        STSH  r9, tid
        SYNC
        ADD   r5, r5, r5
        JMP   loop
fin:    LDSH  r9, tid
        LDR   r3, r0, y
        ADD   r3, r3, r2
        STR   r9, [r3]
        EXIT
