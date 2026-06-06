// fp32_test.asm
// Verifies FADD, FSUB, FMUL, and FMA along with the FP32 pipeline and Scoreboard logic.

// --- 1. Load Floating Point Constants via LUI ---
// 1.0 (0x3F800000) -> Shifted right by 12 = 0x3F800
LUI r1, 0x3F800

// 2.0 (0x40000000) -> Shifted right by 12 = 0x40000
LUI r2, 0x40000

// 3.0 (0x40400000) -> Shifted right by 12 = 0x40400
LUI r3, 0x40400

// --- 2. Perform Single Precision Math ---
// FADD: 2.0 + 3.0 = 5.0 (0x40A00000)
FADD r4, r2, r3

// FMUL: 2.0 * 3.0 = 6.0 (0x40C00000)
FMUL r5, r2, r3

// FSUB: 3.0 - 2.0 = 1.0 (0x3F800000)
FSUB r6, r3, r2

// FMA: 2.0 * 3.0 + 1.0 = 7.0 (0x40E00000)
// FMA uses rd as both an input (C operand) and the output.
LUI r7, 0x3F800  // Copy 1.0 into r7
FMA r7, r2, r3   // r7 = (r2 * r3) + r7

// --- 3. Isolate Thread 0 and Write to Memory ---
CONST r0, 0
CMP r31, r0
BR 5, END_PROGRAM  // If r31 != 0 (Condition 5 = Not Equal), skip to END

// [FIX] Store the results using WORD offsets (0, 1, 2, 3) 
// This ensures they all pack neatly into AXI Block 0.
CONST r8, 0
STR r4, r8, 0   // Word 0 <= 5.0
STR r5, r8, 1   // Word 1 <= 6.0
STR r6, r8, 2   // Word 2 <= 1.0
STR r7, r8, 3   // Word 3 <= 7.0

END_PROGRAM:
EXIT