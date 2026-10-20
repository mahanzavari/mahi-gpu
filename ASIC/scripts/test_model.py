#!/usr/bin/env python3
"""Self-test for the golden model: re-implements tb_asic_call_ret_branch's hand-checked
program and requires the interpreter to reproduce its published results (111/211/311),
plus spot checks of ALU edge cases against hand-computed values."""
import os, sys
sys.path.insert(0, os.path.dirname(__file__))
from isa import *

p = {}
p[0] = enc_I('CONST', 2, 0, 4);  p[1] = enc_R('ADD', 1, 31, 0); p[2] = enc_R('CMP', 0, 1, 2)
p[3] = enc_BR(4, 10); p[4] = enc_BR(2, 14); p[5] = enc_BR(1, 18); p[6] = enc_EXIT()
p[10] = enc_I('CONST', 3, 0, 1); p[11] = enc_BR(7, 22)
p[14] = enc_I('CONST', 3, 0, 2); p[15] = enc_BR(7, 22)
p[18] = enc_I('CONST', 3, 0, 3); p[19] = enc_BR(7, 22)
p[22] = enc_I('CONST', 4, 0, 0); p[23] = enc_CALL(30)
p[24] = enc_I('CONST', 5, 0, 100); p[25] = enc_R('MUL', 6, 3, 5); p[26] = enc_R('ADD', 7, 6, 4)
p[27] = enc_I('STR', 7, 31, 0); p[28] = enc_EXIT()
p[30] = enc_I('CONST', 8, 0, 10); p[31] = enc_R('ADD', 4, 4, 8); p[32] = enc_CALL(40); p[33] = enc_RET()
p[40] = enc_I('CONST', 9, 0, 1); p[41] = enc_R('ADD', 4, 4, 9); p[42] = enc_RET()
words = [p.get(i, 0) for i in range(max(p) + 1)]
mem = {}
Machine(words, mem).run()
got = [mem.get(t, 0) for t in range(8)]
assert got == [111, 111, 111, 111, 211, 311, 311, 311], got

# ALU edge cases (hand computed)
assert alu('ADD', M, 1) == 0 and alu('SUB', 0, 1) == M
assert alu('MUL', 0x80000000, 0xFFFFFFFF) == 0x80000000          # -2^31 * -1 wraps
assert alu('SHL', 1, 31) == 0x80000000 and alu('SHL', 1, 32) == 0 and alu('SHR', M, 32) == 0
assert alu('ABS', 0x80000000, 0) == 0x80000000 and alu('NEG', 1, 0) == M
assert alu('MIN', 0xFFFFFFFF, 1) == 0xFFFFFFFF and alu('MAX', 0xFFFFFFFF, 1) == 1   # signed
assert alu('CLZ', 0, 0) == 32 and alu('CLZ', 1, 0) == 31 and alu('POPCNT', M, 0) == 32
assert alu('BREV', 1, 0) == 0x80000000 and alu('MAC', 3, 4, 10) == 22
assert alu('DIV', 7, 2) == 3 and alu('MOD', 7, 2) == 1 and alu('DIV', M, 2) == 0x7FFFFFFF  # unsigned
print('test_model: PASSED')
