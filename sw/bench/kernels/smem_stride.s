// Shared-memory bank conflicts: fill sh[x] = x, then out[gid] = sum_k sh[(tid*S + k*nthr*S) & (SH - 1)]  (int).
// 4 banks (address & 3): S = 1 conflict-free, S = 2 two-way, S = 4 four-way (all lanes of a warp in one bank).
.param out, S, SH, iters
        CONST r0, 0
        CONST r1, 1
        MUL   r2, bid, nthr
        ADD   r2, r2, tid           // gid
        LDR   r3, r0, S
        LDR   r5, r0, SH
        MOV   r8, tid
fill:   CMP   r8, r5
        BRzp  filled
        STSH  r8, r8
        ADD   r8, r8, nthr
        JMP   fill
filled: SYNC
        SUB   r5, r5, r1            // SH - 1
        LDR   r7, r0, iters
        MUL   r8, tid, r3           // tid * S
        MUL   r9, nthr, r3          // nthr * S (a multiple of 4: same bank pattern every round)
        CONST r10, 0
loop:   CMP   r7, r0
        BRz   fin
        AND   r12, r8, r5
        LDSH  r13, r12
        ADD   r10, r10, r13
        ADD   r8, r8, r9
        SUB   r7, r7, r1
        JMP   loop
fin:    LDR   r12, r0, out
        ADD   r12, r12, r2
        STR   r10, [r12]
        EXIT
