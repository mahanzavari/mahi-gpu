"""Assembler tests: encodings vs the golden model's encoders, pseudo-instructions executed on the golden model."""
import os, sys, unittest
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), '..'))
import numpy as np
from mahi import assemble, AsmError, Device, fbits, disassemble
from isa import enc_R, enc_I, enc_BR, enc_LUI, enc_CALL, enc_RET, enc_EXIT


class Encodings(unittest.TestCase):
    def test_match_golden_encoders(self):
        src = """
            ADD r1, r2, r3
            FMA r4, r5, r6
            ATOM_ADD r7, r8, r9
            NEG r10, r11
            CMP r12, r13
            CONST r14, -5
            LUI r15, 0xABCDE
            LDR r1, r2, 7
            LDR r1, [r2 + 7]
            STR r3, [r4 - 2]
            LDSH r5, tid
            STSH r6, r7
        lab: BR 5, lab
            BRnzp lab
            CALL lab
            RET
            EXIT
        """
        p = assemble(src)
        want = [enc_R('ADD', 1, 2, 3), enc_R('FMA', 4, 5, 6), enc_R('ATOM_ADD', 7, 8, 9), enc_R('NEG', 10, 11, 0),
                enc_R('CMP', 0, 12, 13), enc_I('CONST', 14, 0, -5), enc_LUI(15, 0xABCDE), enc_I('LDR', 1, 2, 7),
                enc_I('LDR', 1, 2, 7), enc_I('STR', 3, 4, -2), enc_R('LDSH', 5, 31, 0), enc_R('STSH', 6, 7, 0),
                enc_BR(5, 12), enc_BR(7, 12), enc_CALL(12), enc_RET(), enc_EXIT()]
        self.assertEqual(p.text, want)
        for w in p.text: disassemble(w)        # every word disassembles

    def test_errors(self):
        for bad in ['ADD r1, r2', 'CONST r1, 40000', 'ADD r29, r1, r2', 'FOO r1', 'BR 9, 0', 'LDR r1, r2, x',
                    'LUI r1, 0x100000', '.word 1']:
            with self.assertRaises(AsmError, msg=bad): assemble(bad)


class Pseudo(unittest.TestCase):
    VALUES = [0, 1, -1, 32767, -32768, 32768, 0x12345000, 0x12345678, 0xFFFFFFFF, 0x80000000, 0x7FFF0FFF]
    FLOATS = [0.0, 1.0, -2.5, 3.14159, 1e-3, -1234.5]

    def test_li_and_friends_on_golden(self):
        lines = ['.param out', 'CONST r0, 0', 'LDR r20, r0, out']
        for k, v in enumerate(self.VALUES):
            lines += [f'LI r1, {v}', f'STR r1, [r20 + {k}]']
        for k, f in enumerate(self.FLOATS):
            lines += [f'LIF r1, {f}', f'STR r1, [r20 + {len(self.VALUES) + k}]']
        base = len(self.VALUES) + len(self.FLOATS)
        lines += ['LI r2, 0x0F0F0F0F', 'NOT r3, r2', f'STR r3, [r20 + {base}]',
                  'MOV r4, r2', f'STR r4, [r20 + {base + 1}]',
                  'ADDI r5, r2, -16', f'STR r5, [r20 + {base + 2}]',
                  'JMP over', f'STR r2, [r20 + {base + 3}]', 'over: EXIT']
        p = assemble('\n'.join(lines))
        dev = Device('golden'); out = dev.alloc(base + 4)
        dev.launch(p, threads=1, out=out)
        got = [int(x) for x in dev.read(out, np.uint32)]
        self.assertEqual(got[:len(self.VALUES)], [v & 0xFFFFFFFF for v in self.VALUES])
        self.assertEqual(got[len(self.VALUES):base], [fbits(f) for f in self.FLOATS])
        self.assertEqual(got[base:], [0xF0F0F0F0, 0x0F0F0F0F, 0x0F0F0EFF, 0])   # JMP skipped the last store

    def test_data_params_symbols(self):
        p = assemble('.param a, b\n.equ K, 3\n.data\ntab: .word 1, K*2, end\n.float 0.5\nend: .zero 2\n.text\nEXIT')
        self.assertEqual(p.params, ['a', 'b'])
        self.assertEqual(p.sym('a'), 0); self.assertEqual(p.sym('b'), 1); self.assertEqual(p.sym('tab'), 16)
        self.assertEqual([p.data[16 + i] for i in range(6)], [1, 6, 20, fbits(0.5), 0, 0])


if __name__ == '__main__':
    unittest.main()
