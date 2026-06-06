// fractal_fp32.asm
// Complex FPU & Divergence Stress Test

CONST r0, 0      // Zero constant for comparisons

// --- 1. Thread Divergence: Set Initial V based on Thread ID (r31) ---
LUI r5, 0x3F800  // Default V = 1.0 (Thread 0)  <-- FIXED ZERO

CONST r11, 1
CMP r31, r11
BR 2, THREAD_1   // Branch if Zero (r31 == 1)

CONST r11, 2
CMP r31, r11
BR 2, THREAD_2   // Branch if Zero (r31 == 2)

CONST r11, 3
CMP r31, r11
BR 2, THREAD_3   // Branch if Zero (r31 == 3)

BR 7, MATH_START // Unconditional branch (skip) for Thread 0

THREAD_1:
LUI r5, 0x40000  // V = 2.0 <-- FIXED ZERO
BR 7, MATH_START

THREAD_2:
LUI r5, 0x40400  // V = 3.0 <-- FIXED ZERO
BR 7, MATH_START

THREAD_3:
LUI r5, 0x40800  // V = 4.0 <-- FIXED ZERO
// Falls through to MATH_START

MATH_START:
// --- 2. Initialize Shared Float Constants ---
LUI r1, 0x3FC00  // r1 (A) = 1.5   <-- FIXED ZERO
LUI r2, 0x3F000  // r2 (B) = 0.5   <-- FIXED ZERO
LUI r3, 0x40000  // r3 (C) = 2.0   <-- FIXED ZERO
LUI r4, 0x3FA00  // r4 (D) = 1.25  <-- FIXED ZERO

// --- 3. Initialize Loop Counters ---
CONST r8, 2      // Loop count = 2
CONST r9, 1      // Decrement step

LOOP_START:
CMP r8, r0
BR 2, LOOP_END   // Exit loop if counter == 0 (Condition 2 = Zero)

// --- 4. FPU Math Pipeline ---
ADD r6, r2, r0   // r6 (T1) = r2 (B) + 0 
FMA r6, r5, r1   // r6 = r5(V) * r1(A) + r6(B)

FMUL r7, r6, r3  // r7 = r6 * r3

FSUB r10, r7, r4 // r10 = r7 - r4

FADD r5, r10, r5 // r5 = r10 + r5

// Decrement loop counter
SUB r8, r8, r9
BR 7, LOOP_START

LOOP_END:
// --- 5. Store Result to Memory ---
STR r5, r31, 0   // MEM[r31 + 0] = r5

EXIT