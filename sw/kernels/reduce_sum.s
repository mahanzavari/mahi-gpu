// out[block] = sum of x[block*nthr .. block*nthr + nthr - 1]  (FP32), one value per thread, threads = whole blocks.
// Tree reduction in shared memory. The loop is warp-uniform and branch-free inside, so every SYNC is reached by the
// whole warp (SYNC after divergence faults, ASIC L1): threads that do not add this round add 0 instead.
.param x, out
        CONST r0, 0
        CONST r9, 1
        CONST r15, 31
        MUL   r1, bid, nthr
        ADD   r1, r1, tid
        LDR   r2, r0, x
        ADD   r2, r2, r1
        LDR   r3, [r2]
        STSH  r3, tid               // sh[tid] = x[gid]
        SYNC
        SHR   r10, nthr, r9         // stride = nthr / 2
loop:   CMP   r10, r0
        BRz   end
        ADD   r11, tid, r10
        LDSH  r12, r11              // other = sh[tid + stride]
        LDSH  r13, tid
        SUB   r14, tid, r10
        SHR   r14, r14, r15         // 1 if tid < stride (sign of tid - stride)
        NEG   r14, r14              // all-ones mask or 0
        AND   r12, r12, r14         // other, or +0.0
        FADD  r13, r13, r12
        STSH  r13, tid
        SYNC
        SHR   r10, r10, r9
        JMP   loop
end:    CMP   tid, r0
        BRp   done                  // only thread 0 writes the block's sum
        LDSH  r12, r0
        LDR   r16, r0, out
        ADD   r16, r16, bid
        STR   r12, [r16]
done:   EXIT
