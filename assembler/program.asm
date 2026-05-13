// --- Convolution Kernel + Phase 1 Feature Test ---

CONST r1, 0         
CONST r2, 64        
CONST r3, 73        

CONST r4, 8         
CONST r5, 6         
CONST r6, 3         
CONST r7, 1         

MUL r8, r29, r30    
ADD r8, r8, r31     

CONST r22, 36       
CMP r8, r22
BR 3, test_features_diverge  // If r8 >= 36, skip to tests/exit

DIV r9, r8, r5      
MOD r10, r8, r5     

MUL r16, r9, r4     
ADD r16, r16, r10   
ADD r16, r16, r1    
MIN r17, r2, r2     
SUB r18, r4, r6     

CONST r11, 0        

loop_ky:
    CMP r12, r6         
    BR 3, end_ky        

    CONST r13, 0        
    loop_kx:
        CMP r13, r6         
        BR 3, end_kx        

        LDR r19, r16, 0     
        LDR r20, r17, 0     
        MAC r11, r19, r20   

        ADD r16, r16, r7    
        ADD r17, r17, r7    

        ADD r13, r13, r7    
        BR 7, loop_kx       
        
    end_kx:
    ADD r16, r16, r18   

    ADD r12, r12, r7    
    BR 7, loop_ky       

end_ky:
ADD r21, r3, r8     
STR r11, r21, 0     

// --- PHASE 1 ALU FEATURE TESTS ---
test_features_diverge:
CONST r23, 0
CMP r8, r23
BR 6, end_thread    // If NOT Thread 0, skip the tests entirely

// 1. Test LUI (Load Upper Immediate) & OR
LUI r24, 0x12345    // Loads 0x12345 into the upper 20 bits => r24 = 0x12345000
CONST r25, 0x0678   // r25 = 0x0678
OR r24, r24, r25    // r24 = 0x12345678
STR r24, r23, 200   // Store to Address 200

// 2. Test POPCNT (Population Count)
POPCNT r25, r24     // POPCNT of 0x12345678 (13 active bits)
STR r25, r23, 201   // Store to Address 201

// 3. Test CLZ (Count Leading Zeros)
CLZ r26, r24        // CLZ of 0x12345678 (3 leading zeros before the first 1 at bit 28)
STR r26, r23, 202   // Store to Address 202

// 4. Test BREV (Bit Reverse)
BREV r27, r24       // BREV of 0x12345678 = 0x1E6A2C48
STR r27, r23, 203   // Store to Address 203

end_thread:
EXIT