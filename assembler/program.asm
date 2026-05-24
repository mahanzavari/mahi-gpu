// --- TINY-GPU BUG FIX VERIFICATION ---
// All threads compute the values, proving out the ALU fixes.

// 1. Setup Base Value 0x12345678 in r2
LUI r2, 0x12345
CONST r3, 0x678
OR r2, r2, r3

// 2. Compute ALU Unary Operations
POPCNT r5, r2      // POPCNT of 0x12345678 -> 13
CLZ r6, r2         // CLZ of 0x12345678    -> 3 (Verifies Bug 1.1)
BREV r7, r2        // BREV of 0x12345678   -> 0x1E6A2C48 (Verifies Bug 1.2)

// 3. Test Out-of-Bounds shifts (Verifies Bug 1.3)
// If the bug remained, the Verilog simulator would emit an array bounds error here
CONST r8, 32
SHL r9, r2, r8
SHR r10, r2, r8

// 4. Test Barrier Double-Count (Verifies Bug 1.6)
// If the bug remained, the scheduler would hang or fire SYNC erroneously
SYNC

// 5. Isolate Thread 0 for Memory Writeback
CONST r0, 0
CMP r31, r0
BR 5, END_PROGRAM  // If r31 != 0 (Condition 5 = Not Equal), skip to END

// 6. Write results to trigger D-Cache and VWB (Verifies Bugs 1.4 & 1.5)
CONST r4, 200
STR r2, r4, 0
CONST r4, 201
STR r5, r4, 0
CONST r4, 202
STR r6, r4, 0
CONST r4, 203
STR r7, r4, 0

END_PROGRAM:
EXIT