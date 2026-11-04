// Fused training of a one-hidden-layer MLP:  IN -> H (ReLU) -> OUT (linear), MSE loss, SGD.  `steps` full training
// steps per launch, no host involvement in between. Launch with threads = B (one block: the whole batch must share a
// SYNC barrier). Same arithmetic, in the same order, as the unfused kernels (linear_fwd, relu_*, mse, linear_bwd_*,
// sgd), so the weights are bit-identical to mahi.nn.MLP.
//
// Memory (word addresses, FP32):
//   X [B, IN]   T [B, OUT]
//   P = W1 [H, IN] | b1 [H] | W2 [OUT, H] | b2 [OUT]                  parameters, contiguous
//   S = Z1 [B, H] | dZ1 [B, H] | dZ2 [B, OUT] | E [B] | junk [B]      scratch; E[b] = sum_o d^2 of the last step
// h_iters = ceil(H / B), o_iters = ceil(OUT / B): update-loop trips (the host computes them: no division on the GPU).
//
// Each step:
//   phase A (thread = sample b): z1 = b1 + W1 x;  y = b2 + W2 relu(z1);  d = y - t;  E[b] = sum d^2;
//            dZ2 = d * scale;  dZ1 = (W2^T dZ2) masked by z1 > 0                       ... SYNC
//   phase B (thread = parameter row r = q*B + tid): gradient of row r summed over the batch, then p += neg_lr * g.
//            Threads with r >= rows compute on a clamped row and store to their junk word instead (no branch, so
//            every SYNC is reached by whole warps: SYNC while diverged is a fault, ASIC L1)       ... SYNC
.param X, T, P, S, B, IN, H, OUT, steps, neg_lr, scale, h_iters, o_iters
        CONST r0, 0
        CONST r1, 1
        LDR   r2, r0, B
        LDR   r3, r0, IN
        LDR   r4, r0, H
        LDR   r5, r0, OUT
        LDR   r6, r0, P             // W1
        MUL   r7, r4, r3
        ADD   r7, r6, r7            // b1 = W1 + H*IN
        ADD   r8, r7, r4            // W2 = b1 + H
        MUL   r9, r5, r4
        ADD   r9, r8, r9            // b2 = W2 + OUT*H
        LDR   r10, r0, S            // Z1
        MUL   r11, r2, r4
        ADD   r11, r10, r11         // dZ1 = Z1 + B*H
        MUL   r12, r2, r4
        ADD   r12, r11, r12         // dZ2 = dZ1 + B*H
        LDR   r13, r0, steps

step:   CMP   r13, r0
        BRz   done
// ================================================= phase A: one sample per thread
        LDR   r14, r0, X
        MUL   r15, tid, r3
        ADD   r14, r14, r15         // &X[b, 0]
        MUL   r15, tid, r4
        ADD   r16, r10, r15         // &Z1[b, 0]
        ADD   r17, r11, r15         // &dZ1[b, 0]
        // hidden pre-activations: Z1[b, j] = b1[j] + sum_k X[b, k] * W1[j, k]
        MOV   r18, r6               // walks W1 row after row
        CONST r19, 0                // j
hj:     CMP   r19, r4
        BRzp  hend
        ADD   r20, r7, r19
        LDR   r21, [r20]            // acc = b1[j]
        MOV   r22, r14
        CONST r23, 0                // k
hk:     CMP   r23, r3
        BRzp  hkend
        LDR   r24, [r22]
        LDR   r25, [r18]
        FMA   r21, r24, r25
        ADD   r22, r22, r1
        ADD   r18, r18, r1
        ADD   r23, r23, r1
        JMP   hk
hkend:  ADD   r20, r16, r19
        STR   r21, [r20]
        ADD   r19, r19, r1
        JMP   hj
hend:   // outputs, loss and output gradient
        CONST r26, 0                // e = sum_o d^2
        LDR   r14, r0, T
        MUL   r15, tid, r5
        ADD   r14, r14, r15         // &T[b, 0]
        ADD   r27, r12, r15         // &dZ2[b, 0]
        MOV   r18, r8               // walks W2 row after row
        CONST r19, 0                // o
oo:     CMP   r19, r5
        BRzp  oend
        ADD   r20, r9, r19
        LDR   r21, [r20]            // y = b2[o]
        MOV   r22, r16
        CONST r23, 0                // j
oj:     CMP   r23, r4
        BRzp  ojend
        LDR   r24, [r22]
        MAX   r24, r24, r0          // relu(Z1[b, j])
        LDR   r25, [r18]
        FMA   r21, r24, r25
        ADD   r22, r22, r1
        ADD   r18, r18, r1
        ADD   r23, r23, r1
        JMP   oj
ojend:  ADD   r20, r14, r19
        LDR   r24, [r20]
        FSUB  r21, r21, r24         // d = y - t
        FMA   r26, r21, r21         // e += d * d
        LDR   r24, r0, scale
        FMUL  r21, r21, r24
        ADD   r20, r27, r19
        STR   r21, [r20]            // dZ2[b, o] = d * scale
        ADD   r19, r19, r1
        JMP   oo
oend:   MUL   r24, r2, r5
        ADD   r20, r12, r24         // E = dZ2 + B*OUT
        ADD   r20, r20, tid
        STR   r26, [r20]
        // hidden gradient: dZ1[b, j] = (sum_o dZ2[b, o] * W2[o, j]) if Z1[b, j] > 0 else 0
        CONST r19, 0                // j
bj:     CMP   r19, r4
        BRzp  bend
        CONST r21, 0
        MOV   r22, r27              // &dZ2[b, 0]
        ADD   r18, r8, r19          // &W2[0, j]
        CONST r23, 0                // o
bo:     CMP   r23, r5
        BRzp  boend
        LDR   r24, [r22]
        LDR   r25, [r18]
        FMA   r21, r24, r25
        ADD   r22, r22, r1
        ADD   r18, r18, r4          // next row of W2
        ADD   r23, r23, r1
        JMP   bo
boend:  ADD   r20, r16, r19
        LDR   r24, [r20]
        MAX   r24, r24, r0
        SUB   r24, r0, r24
        CONST r23, 31
        SHR   r24, r24, r23
        NEG   r24, r24              // all ones when Z1[b, j] > 0
        AND   r21, r21, r24
        ADD   r20, r17, r19
        STR   r21, [r20]
        ADD   r19, r19, r1
        JMP   bj
bend:   SYNC
// ================================================= phase B: parameter rows
        MUL   r24, r2, r5
        ADD   r19, r12, r24         // E = dZ2 + B*OUT
        ADD   r19, r19, r2          // junk = E + B
        ADD   r19, r19, tid         // r19 = &junk[tid]
        // ---- hidden layer rows: b1[r], W1[r, :]
        LDR   r15, r0, h_iters
        CONST r14, 0                // q
hq:     CMP   r14, r15
        BRzp  hqend
        MUL   r16, r14, r2
        ADD   r16, r16, tid         // r = q*B + tid
        SUB   r17, r16, r4
        CONST r23, 31
        SHR   r17, r17, r23
        NEG   r17, r17              // mask: all ones when r < H
        SUB   r18, r4, r1
        MIN   r16, r16, r18         // rc = min(r, H - 1)
        // b1[rc] += neg_lr * sum_b dZ1[b, rc]
        CONST r21, 0
        ADD   r22, r11, r16
        CONST r23, 0                // b
hgb:    CMP   r23, r2
        BRzp  hgbend
        LDR   r24, [r22]
        FADD  r21, r21, r24
        ADD   r22, r22, r4
        ADD   r23, r23, r1
        JMP   hgb
hgbend: ADD   r20, r7, r16
        LDR   r24, [r20]
        LDR   r25, r0, neg_lr
        FMA   r24, r21, r25
        SUB   r25, r20, r19
        AND   r25, r25, r17
        ADD   r25, r25, r19         // &b1[rc] if valid, else &junk[tid]
        STR   r24, [r25]
        // W1[rc, k] += neg_lr * sum_b dZ1[b, rc] * X[b, k]
        MUL   r26, r16, r3
        ADD   r26, r26, r6          // &W1[rc, 0]
        CONST r27, 0                // k
hwk:    CMP   r27, r3
        BRzp  hwkend
        CONST r21, 0
        ADD   r22, r11, r16         // &dZ1[0, rc]
        LDR   r20, r0, X
        ADD   r20, r20, r27         // &X[0, k]
        CONST r23, 0                // b
hwb:    CMP   r23, r2
        BRzp  hwbend
        LDR   r24, [r22]
        LDR   r25, [r20]
        FMA   r21, r24, r25
        ADD   r22, r22, r4
        ADD   r20, r20, r3
        ADD   r23, r23, r1
        JMP   hwb
hwbend: ADD   r20, r26, r27
        LDR   r24, [r20]
        LDR   r25, r0, neg_lr
        FMA   r24, r21, r25
        SUB   r25, r20, r19
        AND   r25, r25, r17
        ADD   r25, r25, r19
        STR   r24, [r25]
        ADD   r27, r27, r1
        JMP   hwk
hwkend: ADD   r14, r14, r1
        JMP   hq
hqend:  // ---- output layer rows: b2[r], W2[r, :]
        LDR   r15, r0, o_iters
        CONST r14, 0
oq:     CMP   r14, r15
        BRzp  oqend
        MUL   r16, r14, r2
        ADD   r16, r16, tid
        SUB   r17, r16, r5
        CONST r23, 31
        SHR   r17, r17, r23
        NEG   r17, r17              // mask: r < OUT
        SUB   r18, r5, r1
        MIN   r16, r16, r18         // rc = min(r, OUT - 1)
        // b2[rc] += neg_lr * sum_b dZ2[b, rc]
        CONST r21, 0
        ADD   r22, r12, r16
        CONST r23, 0
ogb:    CMP   r23, r2
        BRzp  ogbend
        LDR   r24, [r22]
        FADD  r21, r21, r24
        ADD   r22, r22, r5
        ADD   r23, r23, r1
        JMP   ogb
ogbend: ADD   r20, r9, r16
        LDR   r24, [r20]
        LDR   r25, r0, neg_lr
        FMA   r24, r21, r25
        SUB   r25, r20, r19
        AND   r25, r25, r17
        ADD   r25, r25, r19
        STR   r24, [r25]
        // W2[rc, j] += neg_lr * sum_b dZ2[b, rc] * relu(Z1[b, j])
        MUL   r26, r16, r4
        ADD   r26, r26, r8          // &W2[rc, 0]
        CONST r27, 0                // j
owj:    CMP   r27, r4
        BRzp  owjend
        CONST r21, 0
        ADD   r22, r12, r16         // &dZ2[0, rc]
        ADD   r20, r10, r27         // &Z1[0, j]
        CONST r23, 0
owb:    CMP   r23, r2
        BRzp  owbend
        LDR   r24, [r22]
        LDR   r25, [r20]
        MAX   r25, r25, r0
        FMA   r21, r24, r25
        ADD   r22, r22, r5
        ADD   r20, r20, r4
        ADD   r23, r23, r1
        JMP   owb
owbend: ADD   r20, r26, r27
        LDR   r24, [r20]
        LDR   r25, r0, neg_lr
        FMA   r24, r21, r25
        SUB   r25, r20, r19
        AND   r25, r25, r17
        ADD   r25, r25, r19
        STR   r24, [r25]
        ADD   r27, r27, r1
        JMP   owj
owjend: ADD   r14, r14, r1
        JMP   oq
oqend:  SYNC
        SUB   r13, r13, r1
        JMP   step
done:   EXIT
