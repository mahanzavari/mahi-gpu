// Load-to-use latency: one thread follows p = a[p] for `iters` hops (a holds offsets into a); out = final p.
// Launch with threads = 1. Cycles per hop - 6 instructions = load latency of the level the chain's footprint fits in.
.param a, start, iters, out
        CONST r0, 0
        CONST r1, 1
        LDR   r2, r0, a
        LDR   r3, r0, start
        LDR   r4, r0, iters
loop:   CMP   r4, r0
        BRz   fin
        ADD   r5, r2, r3
        LDR   r3, [r5]
        SUB   r4, r4, r1
        JMP   loop
fin:    LDR   r5, r0, out
        STR   r3, [r5]
        EXIT
