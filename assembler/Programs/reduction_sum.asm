// reduction.asm
// Parallel Tree Reduction (Sum 1 to 16)
// Tests: Shared Memory, SYNC barriers, and Intra-Warp Divergence

CONST r0, 0        // Zero constant
CONST r1, 1        // One constant
CONST r10, 8       // Initial stride length (16 threads / 2)

// --- 1. Initialization ---
// Every thread calculates: value = Thread_ID + 1
ADD r2, r31, r1    

// Store value into Shared Memory: SH[Thread_ID] = value
STSH r2, r31, 0    

// Barrier: Wait for all 16 threads to write to Shared Memory
SYNC               

// --- 2. Reduction Loop ---
REDUCE_LOOP:
// Check if stride == 0. If so, we are done reducing.
CMP r10, r0
BR 2, WRITE_OUT    // Branch if Z(2) (r10 == 0)

// Check if this specific thread should participate in this step
// If Thread_ID >= stride, skip the addition
CMP r31, r10
BR 3, DONT_ADD     // Branch if Z(2) or P(1) (r31 >= r10)

// --- Active Thread Logic ---
// Calculate neighbor address: neighbor_addr = Thread_ID + stride
ADD r3, r31, r10   

// Read neighbor value from Shared Memory
LDSH r4, r3, 0     

// Read my own value from Shared Memory
LDSH r5, r31, 0    

// Add them together
ADD r5, r5, r4     

// Store the sum back into my Shared Memory slot
STSH r5, r31, 0    

DONT_ADD:
// Barrier: All threads (active and inactive) wait here for the addition step to finish
SYNC               

// Divide stride by 2 for the next tree level
SHR r10, r10, r1   

// Loop back unconditionally
BR 7, REDUCE_LOOP  

// --- 3. Write Result to Global Memory ---
WRITE_OUT:
// Only Thread 0 writes the final result
CMP r31, r0
BR 5, DONE         // Branch if N(4) or P(1) (r31 != 0)

// Read the final sum from Shared Memory slot 0
LDSH r5, r0, 0     

// Write it out to Global Memory Address 0
STR r5, r0, 0      

DONE:
EXIT