// Read bandwidth: out[gid] = sum over `reps` passes of a[i], i = gid, gid + T, ... < n  (FP32, grid-stride: the lanes
// of a warp read consecutive words, one line per warp load). n must be a multiple of T (no divergence).
.param a, out, n, T, reps
        CONST r0, 0
        CONST r1, 1
        MUL   r2, bid, nthr
        ADD   r2, r2, tid           // gid
        LDR   r3, r0, n
        LDR   r4, r0, T
        LDR   r5, r0, a
        LDR   r6, r0, reps
        CONST r7, 0                 // acc = +0.0
rep:    CMP   r6, r0
        BRz   fin
        MOV   r8, r2                // i
loop:   CMP   r8, r3
        BRzp  next
        ADD   r9, r5, r8
        LDR   r10, [r9]
        FADD  r7, r7, r10
        ADD   r8, r8, r4
        JMP   loop
next:   SUB   r6, r6, r1
        JMP   rep
fin:    LDR   r9, r0, out
        ADD   r9, r9, r2
        STR   r7, [r9]
        EXIT
