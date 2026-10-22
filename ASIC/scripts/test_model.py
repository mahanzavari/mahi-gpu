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
# FP: exactly-representable cases, truncation, flush-to-zero, cancellation (hand computed)
import struct
fb = lambda v: struct.unpack('<I', struct.pack('<f', v))[0]
bf = lambda b: struct.unpack('<f', struct.pack('<I', b))[0]
assert bf(fma_bits('FADD', fb(1.5), fb(2.25), 0)) == 3.75
assert bf(fma_bits('FSUB', fb(1.0), fb(2.0), 0)) == -1.0
assert bf(fma_bits('FMUL', fb(-2.0), fb(3.0), 0)) == -6.0
assert bf(fma_bits('FMA', fb(2.0), fb(3.0), fb(4.0))) == 10.0
assert fma_bits('FMA', fb(1.5), fb(1.5), fb(-2.25)) & 0x7FFFFFFF == 0           # exact cancellation -> zero
assert fma_bits('FADD', 0x00400000, fb(1.0), 0) == fb(1.0)                       # denormal input flushes to 0
assert fma_bits('FMUL', 0x00800000, 0x00800000, 0) == 0                           # underflow flushes to zero
assert fma_bits('FADD', fb(3.0e38), fb(3.0e38), 0) == 0x7F800000                  # overflow -> +inf encoding

# shared memory + barrier: thread t writes slot t, barrier, thread t reads slot (t+1)%8
c = [enc_I('CONST', 5, 0, 7), enc_I('CONST', 6, 0, 3), enc_R('MUL', 1, 31, 6), enc_R('ADD', 1, 1, 5),
     enc_I('STSH', 1, 31, 0), OP['SYNC'] << 26,
     enc_I('CONST', 3, 0, 1), enc_R('ADD', 3, 31, 3), enc_I('CONST', 4, 0, 7), enc_R('AND', 3, 3, 4),
     enc_R('LDSH', 2, 3, 0), enc_I('CONST', 7, 0, 300), enc_R('ADD', 7, 7, 31), enc_I('STR', 2, 7, 0), enc_EXIT()]
m = {}; Machine(c, m).run()
assert [m[300 + t] for t in range(8)] == [10, 13, 16, 19, 22, 25, 28, 7]
# barrier with a thread that exits early must be rejected
try:
    Machine([enc_I('CMP', 0, 0, 0) if False else enc_R('CMP', 0, 31, 27), enc_BR(1, 3), enc_EXIT(), OP['SYNC'] << 26, enc_EXIT()], {}).run()
    raise SystemExit('expected barrier fault')
except Fault: pass
# atomics: 8 threads each add (tid+1) to word 128
a = [enc_I('CONST', 4, 0, 128), enc_I('CONST', 5, 0, 1), enc_R('ADD', 5, 5, 31), enc_R('ATOM_ADD', 6, 4, 5), enc_EXIT()]
m = {}; Machine(a, m).run(); assert m[128] == 36
print('test_model: PASSED')
