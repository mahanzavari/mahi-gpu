"""mahi-gpu assembler (v2).

  python -m mahi.asm kernel.s -o build/kernel            # writes kernel.prog.hex, kernel.dmem.hex, kernel.map.json
  python -m mahi.asm kernel.s -o build/kernel -l          # also kernel.lst (address, word, source)

Instruction semantics are those of the golden model (ASIC/scripts/isa.py), which is checked against the RTL.

Syntax
  Comments start with //, # or ;.  Labels: `name:` (alone or before an instruction).  Mnemonics are case-insensitive.
  Registers r0..r31, plus aliases:  at = r28 (assembler temporary, clobbered by pseudo-instructions),
  bid = r29 (block id), nthr = r30 (threads per block), tid = r31 (thread id in the block). r29-r31 are read-only.
  Immediates are expressions over numbers and symbols: + - * // % << >> & | ^ ~ and ( ). Helpers: fbits(1.5) (FP32 bit
  pattern), hi(x) = x >> 12, lo(x) = x & 0xFFF.

Instructions (the value stored by STR/STSH is in the first operand, as in the hardware's rd slot)
  ADD SUB MUL DIV MOD AND OR XOR SHL SHR MIN MAX MAC FADD FSUB FMUL FMA ATOM_ADD ATOM_CAS   rd, rs, rt
  ABS NEG POPCNT CLZ BREV                                                                   rd, rs
  CMP rs, rt          CONST rd, imm16 (sign-extended)          LUI rd, imm20 (rd = imm20 << 12)
  LDR rd, rs, imm     LDR rd, [rs + imm]      STR rv, rs, imm   STR rv, [rs + imm]
  LDSH rd, rs         STSH rv, rs             (shared memory has no offset)
  BR nzp, target      BRn BRz BRp BRnz BRnp BRzp BRnzp target    CALL target    RET    EXIT    SYNC    NOP
  MUL is signed, DIV/MOD unsigned, CMP unsigned (it sets N/Z/P for the next BR), MIN/MAX signed.
  MAX rd, rs, rz with rz = 0 is a ReLU on FP32 bit patterns (negative floats are negative as signed integers).

Pseudo-instructions (may use `at`)
  LI rd, expr       load any 32-bit constant (1 to 3 instructions)
  LIF rd, float     load an FP32 constant
  MOV rd, rs        NOT rd, rs        ADDI rd, rs, expr        JMP target (CMP at, at ; BRz target)

Directives
  .text / .data           switch section (text = program memory, data = data memory)
  .org expr               set the location counter of the current section
  .word e, ...  .float f, ...  .zero n      data words (data section only)
  .equ name, expr         define a constant
  .param a, b, ...        kernel arguments: one word each in the parameter block (data words 0..15); the symbol is
                          the word's address, so a kernel reads an argument with  LDR r, rz, a  (rz holding 0)

Memory convention: data words 0..15 are the parameter block, the data section starts at word 16 by default.
"""
import argparse, ast, json, os, re, struct, sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', '..', 'ASIC', 'scripts'))
from isa import OP, NAME  # noqa: E402  (opcode numbers: single source of truth with the golden model)

PARAM_BASE, PARAM_WORDS, DATA_BASE = 0, 16, 16
ALIASES = {'at': 28, 'bid': 29, 'nthr': 30, 'tid': 31}
R3 = ['ADD', 'SUB', 'MUL', 'DIV', 'MOD', 'AND', 'OR', 'XOR', 'SHL', 'SHR', 'MIN', 'MAX', 'MAC',
      'FADD', 'FSUB', 'FMUL', 'FMA', 'ATOM_ADD', 'ATOM_CAS']
R2 = ['ABS', 'NEG', 'POPCNT', 'CLZ', 'BREV']
NOARG = {'RET': 'RET', 'EXIT': 'EXIT', 'SYNC': 'SYNC', 'NOP': 'NOP'}
BR_ALIAS = {'BRN': 4, 'BRZ': 2, 'BRP': 1, 'BRNZ': 6, 'BRNP': 5, 'BRZP': 3, 'BRNZP': 7}
M32 = 0xFFFFFFFF


class AsmError(Exception):
    pass


def fbits(x):
    return struct.unpack('<I', struct.pack('<f', float(x)))[0]


def bitsf(w):
    return struct.unpack('<f', struct.pack('<I', w & M32))[0]


# ---- expressions ---------------------------------------------------------------------------------------------------
_BIN = {ast.Add: lambda a, b: a + b, ast.Sub: lambda a, b: a - b, ast.Mult: lambda a, b: a * b,
        ast.FloorDiv: lambda a, b: a // b, ast.Mod: lambda a, b: a % b, ast.LShift: lambda a, b: a << b,
        ast.RShift: lambda a, b: a >> b, ast.BitAnd: lambda a, b: a & b, ast.BitOr: lambda a, b: a | b,
        ast.BitXor: lambda a, b: a ^ b}
_FUN = {'fbits': fbits, 'hi': lambda x: (int(x) >> 12) & 0xFFFFF, 'lo': lambda x: int(x) & 0xFFF}


class Unresolved(Exception):
    pass


def evaluate(expr, syms):
    try:
        tree = ast.parse(expr.strip(), mode='eval').body
    except SyntaxError:
        raise AsmError(f'bad expression "{expr}"')

    def ev(n):
        if isinstance(n, ast.Constant) and isinstance(n.value, (int, float)): return n.value
        if isinstance(n, ast.Name):
            if n.id in syms: return syms[n.id]
            raise Unresolved(n.id)
        if isinstance(n, ast.BinOp) and type(n.op) in _BIN: return _BIN[type(n.op)](ev(n.left), ev(n.right))
        if isinstance(n, ast.UnaryOp) and isinstance(n.op, ast.USub): return -ev(n.operand)
        if isinstance(n, ast.UnaryOp) and isinstance(n.op, ast.UAdd): return ev(n.operand)
        if isinstance(n, ast.UnaryOp) and isinstance(n.op, ast.Invert): return ~ev(n.operand)
        if isinstance(n, ast.Call) and isinstance(n.func, ast.Name) and n.func.id in _FUN and len(n.args) == 1:
            return _FUN[n.func.id](ev(n.args[0]))
        raise AsmError(f'unsupported expression "{expr}"')
    return ev(tree)


def reg(tok):
    t = tok.strip().lower()
    if t in ALIASES: return ALIASES[t]
    m = re.fullmatch(r'r(\d+)', t)
    if not m or int(m.group(1)) > 31: raise AsmError(f'bad register "{tok}"')
    return int(m.group(1))


def wreg(tok):
    r = reg(tok)
    if r >= 29: raise AsmError(f'{tok} (r{r}) is read-only')
    return r


def split_ops(s):
    """operand list, keeping [ ... ] together"""
    out, depth, cur = [], 0, ''
    for ch in s:
        if ch == '[': depth += 1
        if ch == ']': depth -= 1
        if ch == ',' and depth == 0: out.append(cur.strip()); cur = ''
        else: cur += ch
    if cur.strip(): out.append(cur.strip())
    return out


def mem_operand(ops, mn):
    """LDR/STR operands: 'rx, rs, imm' or 'rx, [rs + imm]' / '[rs, imm]' / '[rs]' -> (rs token, imm expr)"""
    if len(ops) == 2 and ops[1].startswith('['):
        inner = ops[1].strip()[1:-1].strip()
        m = re.fullmatch(r'(\w+)\s*(?:([,+-])\s*(.+))?', inner)
        if not m: raise AsmError(f'bad memory operand "{ops[1]}"')
        imm = '0' if m.group(2) is None else (('-' if m.group(2) == '-' else '') + '(' + m.group(3) + ')')
        return m.group(1), imm
    if len(ops) == 3: return ops[1], ops[2]
    raise AsmError(f'{mn} needs "rd, rs, imm" or "rd, [rs + imm]"')


# ---- encoders ------------------------------------------------------------------------------------------------------
def e_r(op, rd=0, rs=0, rt=0): return (OP[op] << 26) | (rd << 21) | (rs << 16) | (rt << 11)


def e_i(op, rd, rs, imm): return (OP[op] << 26) | (rd << 21) | (rs << 16) | (imm & 0xFFFF)


def e_br(nzp, t): return (OP['BR'] << 26) | (nzp << 23) | (t & 0xFFFF)


def e_lui(rd, imm20): return (OP['LUI'] << 26) | (rd << 21) | ((imm20 & 0xFFFFF) << 1)


def li_seq(rd, v):
    """shortest sequence loading the 32-bit value v into rd (uses at only for the 3-instruction form)"""
    v &= M32; sv = v - (1 << 32) if v & 0x80000000 else v
    if -32768 <= sv <= 32767: return [e_i('CONST', rd, 0, sv)]
    hi, lo = v >> 12, v & 0xFFF
    if lo == 0: return [e_lui(rd, hi)]
    if rd == ALIASES['at']: raise AsmError('LI into at needs a temporary; use another register')
    return [e_lui(rd, hi), e_i('CONST', ALIASES['at'], 0, lo), e_r('OR', rd, rd, ALIASES['at'])]


def check16(v, what, signed=True):
    lo, hi = (-32768, 32767) if signed else (0, 65535)
    if not lo <= v <= hi: raise AsmError(f'{what} {v} out of range [{lo}, {hi}]')
    return v


# ---- assembler -----------------------------------------------------------------------------------------------------
class Program:
    def __init__(self, text, data, symbols, params, listing, source):
        self.text, self.data, self.symbols, self.params = text, data, symbols, params
        self.listing, self.source = listing, source

    def data_image(self, size=1024):
        img = [0] * size
        for a, w in self.data.items():
            if not 0 <= a < size: raise AsmError(f'data word at {a} outside the {size}-word memory')
            img[a] = w
        return img

    def data_end(self):
        return max(self.data) + 1 if self.data else DATA_BASE

    def sym(self, name):
        return self.symbols[name]['addr']

    def write(self, prefix, listing=False):
        os.makedirs(os.path.dirname(os.path.abspath(prefix)), exist_ok=True)
        with open(prefix + '.prog.hex', 'w') as f: f.write(''.join(f'{w:08x}\n' for w in self.text))
        with open(prefix + '.dmem.hex', 'w') as f: f.write(''.join(f'{w:08x}\n' for w in self.data_image()))
        with open(prefix + '.map.json', 'w') as f:
            json.dump({'symbols': self.symbols, 'params': self.params, 'text_words': len(self.text),
                       'data_end': self.data_end()}, f, indent=1)
        if listing:
            with open(prefix + '.lst', 'w') as f: f.write('\n'.join(self.listing) + '\n')


def assemble(src, name='<input>', max_text=4096, include_dirs=()):
    lines = expand_includes(src, name, include_dirs)
    syms, kinds = {}, {}                    # value, section ('text'/'data'/'equ'/'param')
    params = []

    def define(n, v, kind, where):
        if n in syms and syms[n] != v: raise AsmError(f'{where}: symbol "{n}" redefined')
        if n in ALIASES or re.fullmatch(r'r\d+', n): raise AsmError(f'{where}: "{n}" is a register name')
        syms[n] = v; kinds[n] = kind

    def parse(line):
        line = re.split(r'//|#|;', line, maxsplit=1)[0].strip()
        labels = []
        while True:
            m = re.match(r'([A-Za-z_.$][\w.$]*)\s*:(.*)', line)
            if not m: break
            labels.append(m.group(1)); line = m.group(2).strip()
        if not line: return labels, None, []
        parts = line.split(None, 1)
        return labels, parts[0], split_ops(parts[1]) if len(parts) > 1 else []

    # pass 1: sizes and symbols; pass 2: encode (pseudo sizes fixed in pass 1, padded with NOP if pass 2 is shorter)
    sizes = {}
    for pas in (1, 2):
        sec, loc = 'text', {'text': 0, 'data': DATA_BASE}
        text, data, listing = [], {}, []
        for idx, (fname, lno, raw) in enumerate(lines):
            where = f'{fname}:{lno}'
            try:
                labels, mn, ops = parse(raw)
                for lb in labels:
                    if pas == 1: define(lb, loc[sec], sec, where)
                if mn is None: continue
                m = mn.upper()
                if m.startswith('.'):
                    d = m
                    if d in ('.TEXT', '.DATA'): sec = d[1:].lower(); continue
                    if d == '.ORG': loc[sec] = int(evaluate(ops[0], syms)); continue
                    if d == '.EQU':
                        if pas == 1: define(ops[0], evaluate(ops[1], syms), 'equ', where)
                        continue
                    if d == '.PARAM':
                        if pas == 1:
                            for p in ops:
                                if len(params) >= PARAM_WORDS: raise AsmError(f'more than {PARAM_WORDS} params')
                                define(p, PARAM_BASE + len(params), 'param', where); params.append(p)
                        continue
                    if d in ('.WORD', '.FLOAT', '.ZERO'):
                        if sec != 'data': raise AsmError(f'{mn} only in .data')
                        if d == '.ZERO': vals = [0] * int(evaluate(ops[0], syms))
                        elif d == '.FLOAT': vals = [fbits(evaluate(o, syms)) for o in ops]
                        else:
                            vals = []
                            for o in ops:
                                try: vals.append(int(evaluate(o, syms)) & M32)
                                except Unresolved:
                                    if pas == 2: raise
                                    vals.append(0)
                        for v in vals:
                            if pas == 2:
                                if loc['data'] in data: raise AsmError(f'data word {loc["data"]} defined twice')
                                data[loc['data']] = v
                            loc['data'] += 1
                        continue
                    raise AsmError(f'unknown directive {mn}')
                if sec != 'text': raise AsmError('instructions only in .text')
                pc = loc['text']
                if pas == 1:
                    try:
                        n = len(encode(m, ops, syms, pc))
                    except Unresolved:
                        n = 3 if m in ('LI', 'ADDI') else (2 if m == 'JMP' else 1)
                    sizes[idx] = n
                    loc['text'] += n
                else:
                    words = encode(m, ops, syms, pc)
                    if len(words) > sizes[idx]: raise AsmError('internal: pseudo-instruction grew between passes')
                    words += [0] * (sizes[idx] - len(words))
                    for k, w in enumerate(words):
                        listing.append(f'{pc + k:04x}  {w:08x}  ' + (f'{raw.strip()}' if k == 0 else '   (cont.)'))
                    text += words; loc['text'] += len(words)
            except Unresolved as e:
                raise AsmError(f'{where}: undefined symbol "{e.args[0]}"')
            except AsmError as e:
                raise AsmError(f'{where}: {e}  [{raw.strip()}]')
    if len(text) > max_text: raise AsmError(f'program is {len(text)} words, more than {max_text}')
    symbols = {n: {'addr': v, 'section': kinds[n]} for n, v in syms.items()}
    return Program(text, data, symbols, params, listing, name)


def encode(m, ops, syms, pc):
    def need(n):
        if len(ops) != n: raise AsmError(f'{m} takes {n} operand(s), got {len(ops)}')

    def imm(e): return int(evaluate(e, syms))

    def target(e):
        t = imm(e)
        if not 0 <= t <= 0xFFFF: raise AsmError(f'branch target {t} out of range')
        return t
    if m in R3:
        need(3); return [e_r(m, wreg(ops[0]), reg(ops[1]), reg(ops[2]))]
    if m in R2:
        need(2); return [e_r(m, wreg(ops[0]), reg(ops[1]))]
    if m == 'CMP':
        need(2); return [e_r('CMP', 0, reg(ops[0]), reg(ops[1]))]
    if m == 'CONST':
        need(2); return [e_i('CONST', wreg(ops[0]), 0, check16(imm(ops[1]), 'CONST immediate'))]
    if m == 'LUI':
        need(2); v = imm(ops[1])
        if not 0 <= v <= 0xFFFFF: raise AsmError(f'LUI immediate {v} out of range [0, 0xFFFFF]')
        return [e_lui(wreg(ops[0]), v)]
    if m in ('LDR', 'STR'):
        rs, e = mem_operand(ops, m)
        rd = wreg(ops[0]) if m == 'LDR' else reg(ops[0])
        return [e_i(m, rd, reg(rs), check16(imm(e), 'offset'))]
    if m in ('LDSH', 'STSH'):
        need(2); return [e_r(m, wreg(ops[0]) if m == 'LDSH' else reg(ops[0]), reg(ops[1]))]
    if m == 'BR':
        need(2); nzp = imm(ops[0])
        if not 0 <= nzp <= 7: raise AsmError('BR mask must be 0..7 (n=4, z=2, p=1)')
        return [e_br(nzp, target(ops[1]))]
    if m in BR_ALIAS:
        need(1); return [e_br(BR_ALIAS[m], target(ops[0]))]
    if m == 'CALL':
        need(1); return [(OP['CALL'] << 26) | target(ops[0])]
    if m in NOARG:
        need(0); return [OP[NOARG[m]] << 26]
    # pseudo-instructions
    if m == 'LI':
        need(2); return li_seq(wreg(ops[0]), int(evaluate(ops[1], syms)))
    if m == 'LIF':
        need(2); return li_seq(wreg(ops[0]), fbits(evaluate(ops[1], syms)))
    if m == 'MOV':
        need(2); s = reg(ops[1]); return [e_r('OR', wreg(ops[0]), s, s)]
    if m == 'NOT':
        need(2); return [e_i('CONST', 28, 0, -1), e_r('XOR', wreg(ops[0]), reg(ops[1]), 28)]
    if m == 'ADDI':
        need(3); rd, rs = wreg(ops[0]), reg(ops[1])
        if 28 in (rd, rs): raise AsmError('ADDI cannot use at')
        v = int(evaluate(ops[2], syms)) & M32; sv = v - (1 << 32) if v & 0x80000000 else v
        if not -32768 <= sv <= 32767: raise AsmError('ADDI immediate must fit 16 bits signed')
        return [e_i('CONST', 28, 0, sv), e_r('ADD', rd, rs, 28)]
    if m == 'JMP':
        need(1); return [e_r('CMP', 0, 28, 28), e_br(2, target(ops[0]))]
    raise AsmError(f'unknown mnemonic {m}')


def expand_includes(src, name, include_dirs, depth=0):
    if depth > 8: raise AsmError('.include nested too deep')
    out = []
    for lno, line in enumerate(src.splitlines(), 1):
        m = re.match(r'\s*\.include\s+"([^"]+)"', line, re.I)
        if m:
            base = os.path.dirname(os.path.abspath(name)) if os.path.exists(name) else '.'
            for d in (base,) + tuple(include_dirs):
                p = os.path.join(d, m.group(1))
                if os.path.exists(p):
                    with open(p) as f: out += expand_includes(f.read(), p, include_dirs, depth + 1)
                    break
            else:
                raise AsmError(f'{name}:{lno}: include "{m.group(1)}" not found')
        else:
            out.append((name, lno, line))
    return out


def assemble_file(path, **kw):
    with open(path) as f: return assemble(f.read(), path, **kw)


# ---- disassembler (listings, debugging, round-trip tests) -----------------------------------------------------------
def disassemble(w):
    op = NAME.get(w >> 26, f'?{w >> 26}')
    rd, rs, rt, imm = (w >> 21) & 31, (w >> 16) & 31, (w >> 11) & 31, w & 0xFFFF
    simm = imm - 0x10000 if imm & 0x8000 else imm
    if op in R3: return f'{op} r{rd}, r{rs}, r{rt}'
    if op in R2: return f'{op} r{rd}, r{rs}'
    if op == 'CMP': return f'CMP r{rs}, r{rt}'
    if op == 'CONST': return f'CONST r{rd}, {simm}'
    if op == 'LUI': return f'LUI r{rd}, 0x{(w >> 1) & 0xFFFFF:x}'
    if op in ('LDR', 'STR'): return f'{op} r{rd}, [r{rs} + {simm}]'
    if op in ('LDSH', 'STSH'): return f'{op} r{rd}, r{rs}'
    if op == 'BR': return f'BR {(w >> 23) & 7}, 0x{imm:x}'
    if op == 'CALL': return f'CALL 0x{imm:x}'
    return op


def main():
    ap = argparse.ArgumentParser(description='mahi-gpu assembler')
    ap.add_argument('src'); ap.add_argument('-o', '--out', help='output prefix (default: source name)')
    ap.add_argument('-l', '--listing', action='store_true'); ap.add_argument('-I', dest='inc', action='append', default=[])
    ap.add_argument('--max-text', type=int, default=4096, help='program memory words (ASIC mini: 512)')
    a = ap.parse_args()
    try:
        p = assemble_file(a.src, max_text=a.max_text, include_dirs=a.inc)
    except AsmError as e:
        sys.exit(f'error: {e}')
    out = a.out or os.path.splitext(a.src)[0]
    p.write(out, a.listing)
    print(f'{a.src}: {len(p.text)} instructions, {len(p.data)} data words, {len(p.params)} params -> {out}.*')


if __name__ == '__main__':
    main()
