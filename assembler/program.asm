
// 1. Initialize Constants and Base Addresses
CONST r1, 0         // r1 = Base Address of Input Image (0)
CONST r2, 64        // r2 = Base Address of Filter (64)
CONST r3, 73        // r3 = Base Address of Output (64 + 9 = 73)

CONST r4, 8         // r4 = W_in (Image Width = 8)
CONST r5, 6         // r5 = W_out (Output Width = 8 - 3 + 1 = 6)
CONST r6, 3         // r6 = K 
CONST r7, 1         // r7 = Constant 1

// 2. Fetch Global Thread ID 
// global_id = (block_id * threads_per_core) + local_thread_id
MUL r8, r29, r30    // r8 = block_id * 16
ADD r8, r8, r31     // r8 = global_thread_id

// 2b. Bounds Check - Only 36 pixels are needed! 
CONST r22, 36       
CMP r8, r22
BR 3, end_thread    // If r8 >= 36 (Zero | Positive), jump straight to EXIT

// 3. Calculate 2D coordinates for this output pixel
DIV r9, r8, r5      // r9 = out_row = thread_id / W_out
MOD r10, r8, r5     // r10 = out_col = thread_id % W_out

// 4. Setup Initial Memory Pointers 
// img_ptr = Base_Image + (out_row * W_in) + out_col
MUL r16, r9, r4     // r16 = out_row * W_in
ADD r16, r16, r10   // r16 = (out_row * W_in) + out_col
ADD r16, r16, r1    // r16 = img_ptr

// fil_ptr = Base_Filter (Filter always starts at the beginning for every thread)
MIN r17, r2, r2     // r17 = fil_ptr = r2

// 5. Calculate Image Stride
// When the inner loop finishes a row of the filter, the image pointer 
// needs to jump to the next row, but rewind back to out_col.
// stride = W_in - K
SUB r18, r4, r6     // r18 = img_stride

// 6. Initialize Accumulator
CONST r11, 0        // r11 = sum = 0

// =========================================================================
// OUTER LOOP: Filter Rows (ky)
// =========================================================================
CONST r12, 0        // r12 = ky = 0
loop_ky:
    CMP r12, r6         // Compare ky to K
    BR 3, end_ky        // Branch to end_ky if ky >= K (3 = Zero | Positive)

    // =====================================================================
    // INNER LOOP: Filter Columns (kx)
    // =====================================================================
    CONST r13, 0        // r13 = kx = 0
    loop_kx:
        CMP r13, r6         // Compare kx to K
        BR 3, end_kx        // Branch to end_kx if kx >= K

        // Fetch memory using our moving pointers
        LDR r19, r16, 0     // r19 = Image[img_ptr]
        LDR r20, r17, 0     // r20 = Filter[fil_ptr]

        // Accumulate
        MAC r11, r19, r20   // sum += Image_val * Filter_val

        // Bump Pointers for the next pixel in the row
        ADD r16, r16, r7    // img_ptr++
        ADD r17, r17, r7    // fil_ptr++

        // Increment kx and repeat inner loop
        ADD r13, r13, r7    // kx++
        BR 7, loop_kx       // Unconditional jump back to loop_kx (7 = 111)
        
    end_kx:
    // =====================================================================
    
    // Inner loop finished. Bump the Image Pointer to the next row.
    // Filter pointer is already exactly where it needs to be!
    ADD r16, r16, r18   // img_ptr += img_stride

    // Increment ky and repeat outer loop
    ADD r12, r12, r7    // ky++
    BR 7, loop_ky       // Unconditional jump back to loop_ky

end_ky:
// =========================================================================

// 7. Calculate Final Address for Output and Store
// out_ptr = Base_Output + thread_id
ADD r21, r3, r8     // r21 = Base_Output + thread_id
STR r11, r21, 0     // Memory[out_ptr] = sum

end_thread:
// 8. Terminate Thread
EXIT