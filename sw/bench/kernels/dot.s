// Dot product: out[block] = sum over this block's threads of sum_i x[i] * y[i], i = gid, gid + T, ... < n (FP32).
// Grid-stride FMA, then a branch-free shared-memory tree (as kernels/reduce_sum.s). The host adds the block sums.
.param x, y, out, n, T
        CONST r0, 0
        CONST r9, 1
        CONST r15, 31
        MUL   r2, bid, nthr
        ADD   r2, r2, tid
        LDR   r3, r0, n
        LDR   r4, r0, T
        LDR   r5, r0, x
        LDR   r6, r0, y
        CONST r7, 0
loop:   CMP   r2, r3
        BRzp  red
        ADD   r8, r5, r2
        LDR   r10, [r8]
        ADD   r8, r6, r2
        LDR   r11, [r8]
        FMA   r7, r10, r11
        ADD   r2, r2, r4
        JMP   loop
red:    STSH  r7, tid
        SYNC
        SHR   r10, nthr, r9
tree:   CMP   r10, r0
        BRz   end
        ADD   r11, tid, r10
        LDSH  r12, r11
        LDSH  r13, tid
        SUB   r14, tid, r10
        SHR   r14, r14, r15
        NEG   r14, r14              // all ones if tid < stride
        AND   r12, r12, r14
        FADD  r13, r13, r12
        STSH  r13, tid
        SYNC
        SHR   r10, r10, r9
        JMP   tree
end:    CMP   tid, r0
        BRp   done
        LDSH  r12, r0
        LDR   r16, r0, out
        ADD   r16, r16, bid
        STR   r12, [r16]
done:   EXIT
