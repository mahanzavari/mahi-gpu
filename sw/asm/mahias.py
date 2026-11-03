#!/usr/bin/env python3
"""mahi assembler (v2). Encodings come from sw/isa/mahi.toml; nothing is hard-coded here.

    python sw/asm/mahias.py kernel.asm [-o kernel.hex] [-f hex|hex128|bin] [-l kernel.lst] [--profile fpga]

Source syntax (canonical forms are what the disassembler prints; see the ISA reference sw/isa/ISA.md):
    label:                      labels may share a line with an instruction
    ADD r1, r2, r3              registers r0..r31 (any case); r29/r30/r31 also as bid/nthr/tid
    LDR r1, [r2+4]              memory: [reg], [reg+expr], [reg-expr]
    BRzp loop                   branch: BR + any of n, z, p;  also `BR 7, loop` / `BR nzp, loop`
    CONST r4, -(SIZE*2)         expressions: + - * / % << >> & | ^ ~ ( ), numbers 12 0x1f 0b101, symbols
    .equ SIZE, 16               (also .set)   .word expr[, expr...]   .org expr (pads with NOP)
    // comment   ; comment   # comment
Pseudo-instructions: MOV rd, rs | JMP target (CMP r0, r0 + BRz; clobbers nzp) | LI rd, imm32.
Older kernels (assembler/assembler.py syntax: `LDR r1, r2, 4`, `STSH r2, r31, 0`, `BR 7, L`) still assemble.
"""
import argparse, ast, os, re, sys
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'isa'))
from mahi_isa import ISA, split_operands


class AsmError(Exception):
    def __init__(self, errors):
        super().__init__('\n'.join(errors))
        self.errors = errors


class LineError(Exception):
    pass


REG_RE = re.compile(r'^r(\d+)$', re.I)
SYM_RE = re.compile(r'^[A-Za-z_.$][\w.$]*$')
MEM_RE = re.compile(r'^\[\s*([^\]+\-\s]+)\s*(?:([+-])\s*(.+?))?\s*\]$')


def parse_reg(s):
    t = s.strip()
    m = REG_RE.match(t)
    if m and int(m.group(1)) < 32: return int(m.group(1))
    if t.lower() in ISA.reg_alias: return ISA.reg_alias[t.lower()]
    raise LineError(f'expected a register r0..r31, got {s!r}')


def is_reg(s):
    try: parse_reg(s); return True
    except LineError: return False


_BIN = {ast.Add: lambda a, b: a + b, ast.Sub: lambda a, b: a - b, ast.Mult: lambda a, b: a * b,
        ast.Div: lambda a, b: int(a / b), ast.FloorDiv: lambda a, b: a // b, ast.Mod: lambda a, b: a % b,
        ast.LShift: lambda a, b: a << b, ast.RShift: lambda a, b: a >> b,
        ast.BitAnd: lambda a, b: a & b, ast.BitOr: lambda a, b: a | b, ast.BitXor: lambda a, b: a ^ b}
_UN = {ast.USub: lambda a: -a, ast.UAdd: lambda a: a, ast.Invert: lambda a: ~a}


def evaluate(expr, symbols):
    """Integer expression over numbers and symbols (no Python beyond the arithmetic operators)."""
    try:
        tree = ast.parse(expr.strip(), mode='eval')
    except SyntaxError:
        raise LineError(f'bad expression {expr!r}')

    def ev(n):
        if isinstance(n, ast.Expression): return ev(n.body)
        if isinstance(n, ast.Constant) and isinstance(n.value, int) and not isinstance(n.value, bool): return n.value
        if isinstance(n, ast.Name):
            if n.id in symbols: return symbols[n.id]
            raise LineError(f'undefined symbol {n.id!r}')
        if isinstance(n, ast.BinOp) and type(n.op) in _BIN:
            a, b = ev(n.left), ev(n.right)
            if isinstance(n.op, (ast.Div, ast.FloorDiv, ast.Mod)) and b == 0: raise LineError('division by zero')
            return _BIN[type(n.op)](a, b)
        if isinstance(n, ast.UnaryOp) and type(n.op) in _UN: return _UN[type(n.op)](ev(n.operand))
        raise LineError(f'unsupported expression {expr!r}')
    return ev(tree)


def check_range(v, lo, hi, what):
    if not lo <= v <= hi: raise LineError(f'{what} {v} out of range {lo}..{hi}')
    return v


def match(ins, pattern, ops, symbols):
    """Fields for `ops` under one syntax pattern, or LineError."""
    if len(ops) != len(pattern):
        raise LineError(f'{ins.name} takes {len(pattern)} operand(s): {ins.name} {", ".join(pattern)}'.rstrip(': '))
    f = {}
    for tok, op in zip(pattern, ops):
        if tok in ('rd', 'rc', 'rv'): f['rd'] = parse_reg(op)
        elif tok in ('rs', 'rt'): f[tok] = parse_reg(op)
        elif tok == 'imm': f['imm16'] = check_range(evaluate(op, symbols), -32768, 32767, 'immediate') & 0xFFFF
        elif tok == 'uimm20': f['imm20'] = check_range(evaluate(op, symbols), 0, 0xFFFFF, 'upper immediate')
        elif tok == 'target': f['imm16'] = check_range(evaluate(op, symbols), 0, 0xFFFF, 'target')
        elif tok == 'nzp':
            f['nzp'] = ISA.nzp_value(op) if re.fullmatch(r'[nzpNZP]+', op) else check_range(evaluate(op, symbols), 0, 7, 'condition')
        elif tok in ('[rs+imm]', '[rs]'):
            m = MEM_RE.match(op)
            if not m: raise LineError(f'expected a memory operand like [r2] or [r2+4], got {op!r}')
            f['rs'] = parse_reg(m.group(1))
            off = 0
            if m.group(3) is not None:
                off = evaluate(m.group(3), symbols) * (-1 if m.group(2) == '-' else 1)
            if tok == '[rs]':
                if off: raise LineError(f'{ins.name} has no address offset (the hardware ignores it); use [reg]')
            else:
                f['imm16'] = check_range(off, -32768, 32767, 'offset') & 0xFFFF
        elif re.fullmatch(r'-?\d+', tok):                    # literal in a legacy form, e.g. `rd, rs, 0`
            if evaluate(op, symbols) != int(tok):
                raise LineError(f'{ins.name} has no address offset (the hardware ignores it); use [reg]' if ins.format == 'S'
                                else f'{ins.name}: expected {tok} here, got {op!r}')
        else:
            raise AssertionError(tok)
    return f


def encode_line(mnem, ops, symbols):
    """[(word, note)] for one instruction or pseudo-instruction; raises LineError."""
    m = mnem.upper()
    if m in ISA.by_name:
        ins = ISA.by_name[m]
        errs = []
        for pattern in [ins.syntax] + ins.legacy:
            try:
                return [ISA.encode(m, **match(ins, pattern, ops, symbols))]
            except LineError as e:
                errs.append((len(pattern) == len(ops), str(e)))
        raise LineError(next((e for fits, e in errs if fits), errs[0][1]))   # the form whose operand count fits
    if m.startswith('BR') and re.fullmatch(r'[NZP]+', m[2:]):
        if len(ops) != 1: raise LineError(f'{mnem} takes one operand: {mnem} target')
        return encode_line('BR', [m[2:].lower()] + ops, symbols)
    if m == 'MOV':
        if len(ops) != 2: raise LineError('MOV takes two operands: MOV rd, rs')
        return encode_line('OR', [ops[0], ops[1], ops[1]], symbols)
    if m == 'JMP':
        if len(ops) != 1: raise LineError('JMP takes one operand: JMP target')
        return encode_line('CMP', ['r0', 'r0'], symbols) + encode_line('BR', ['z', ops[0]], symbols)
    if m == 'LI':
        if len(ops) != 2: raise LineError('LI takes two operands: LI rd, imm32')
        v = evaluate(ops[1], symbols)
        check_range(v, -(1 << 31), (1 << 32) - 1, 'LI value')
        v &= 0xFFFFFFFF
        if v < 0x8000 or v >= 0xFFFF8000: return encode_line('CONST', [ops[0], str(v - (1 << 32) if v >> 31 else v)], symbols)
        if v & 0xFFF == 0: return encode_line('LUI', [ops[0], str(v >> 12)], symbols)
        raise LineError(f'LI value {v:#x} needs LUI + CONST + OR with a scratch register (no OR-immediate)')
    raise LineError(f'unknown instruction {mnem!r}')


def size_of(mnem):
    return 2 if mnem.upper() == 'JMP' else 1


def strip_comment(line):
    for i, c in enumerate(line):
        if c in ';#' or line.startswith('//', i): return line[:i]
    return line


class Program:
    def __init__(self):
        self.words, self.src, self.symbols, self.warnings = [], [], {}, []

    def listing(self):
        return '\n'.join(f'{a:04x}  {w:08x}  {s}' for a, (w, s) in enumerate(zip(self.words, self.src)))


def assemble(text, filename='<input>', profile=None):
    """Program for `text`; raises AsmError with every error found. `profile` (a mahi.toml profile name)
    enables size checks against that machine's program memory."""
    errors, prog = [], Program()
    items, pc, symbols = [], 0, prog.symbols

    def where(n): return f'{filename}:{n}'

    # pass 1: labels, .equ, sizes
    for n, raw in enumerate(text.splitlines(), 1):
        line = strip_comment(raw).strip()
        while True:
            m = re.match(r'^([A-Za-z_.$][\w.$]*)\s*:(.*)$', line)
            if not m: break
            name, line = m.group(1), m.group(2).strip()
            if is_reg(name) or name.upper() in ISA.by_name:
                errors.append(f'{where(n)}: error: label {name!r} is a register or mnemonic name'); continue
            if name in symbols: errors.append(f'{where(n)}: error: {name!r} defined twice')
            symbols[name] = pc
        if not line: continue
        parts = line.split(None, 1)
        mnem, ops = parts[0], split_operands(parts[1]) if len(parts) > 1 else []
        try:
            if mnem.lower() in ('.equ', '.set'):
                if len(ops) != 2 or not SYM_RE.match(ops[0]): raise LineError(f'{mnem} name, expr')
                symbols[ops[0]] = evaluate(ops[1], symbols)
            elif mnem.lower() == '.org':
                target = evaluate(ops[0], symbols) if len(ops) == 1 else None
                if target is None: raise LineError('.org expr')
                if target < pc: raise LineError(f'.org {target} is behind the current address {pc}')
                items.append((n, raw, '.org', [str(target)], pc)); pc = target
            elif mnem.lower() == '.word':
                if not ops: raise LineError('.word expr[, expr...]')
                items.append((n, raw, '.word', ops, pc)); pc += len(ops)
            elif mnem.startswith('.'):
                raise LineError(f'unknown directive {mnem}')
            else:
                items.append((n, raw, mnem, ops, pc)); pc += size_of(mnem)
        except LineError as e:
            errors.append(f'{where(n)}: error: {e}')

    # pass 2: encode
    for n, raw, mnem, ops, at in items:
        try:
            if mnem == '.org':
                words = [0] * (int(ops[0]) - len(prog.words))
            elif mnem == '.word':
                words = [check_range(evaluate(o, symbols), -(1 << 31), (1 << 32) - 1, '.word value') & 0xFFFFFFFF for o in ops]
            else:
                words = encode_line(mnem, ops, symbols)
                for w in words:
                    ins, f, _ = ISA.decode(w)
                    if 'rd' in ins.writes() and f['rd'] in ISA.read_only:
                        prog.warnings.append(f'{where(n)}: warning: {ins.name} writes r{f["rd"]}, which is read-only; the result is discarded')
            assert len(prog.words) == at or mnem == '.org'
            prog.words += words
            prog.src += [raw.strip()] + ['(cont.)'] * (len(words) - 1) if words else []
        except LineError as e:
            errors.append(f'{where(n)}: error: {e}')

    if profile:
        p = ISA.profile(profile)
        if len(prog.words) > p['pmem_words']:
            errors.append(f'{filename}: error: {len(prog.words)} words exceed the {p["pmem_words"]}-word program memory of profile {profile}')
    if errors: raise AsmError(errors)
    return prog


# ---- output formats
def to_hex(words): return ''.join(f'{w:08x}\n' for w in words)


def to_hex128(words):
    """4 words per line, word 3 first: the 128-bit program-memory lines of the AXI testbenches."""
    out = []
    for i in range(0, len(words), 4):
        c = (list(words[i:i + 4]) + [0, 0, 0])[:4]
        out.append(''.join(f'{w:08x}' for w in reversed(c)))
    return ''.join(l + '\n' for l in out)


def to_bin(words): return b''.join(w.to_bytes(4, 'little') for w in words)


def write(words, path, fmt):
    if fmt == 'bin':
        with open(path, 'wb') as f: f.write(to_bin(words))
    else:
        with open(path, 'w', newline='\n') as f: f.write(to_hex(words) if fmt == 'hex' else to_hex128(words))


def main(argv=None):
    ap = argparse.ArgumentParser(description='mahi assembler')
    ap.add_argument('src')
    ap.add_argument('-o', '--output')
    ap.add_argument('-f', '--format', choices=['hex', 'hex128', 'bin'], default='hex',
                    help='hex: one word per line ($readmemh); hex128: 4 words per line; bin: little-endian')
    ap.add_argument('-l', '--listing')
    ap.add_argument('--profile', choices=sorted(ISA.profiles))
    ap.add_argument('--Werror', action='store_true', help='treat warnings as errors')
    a = ap.parse_args(argv)
    with open(a.src, encoding='utf-8') as f: text = f.read()
    try:
        prog = assemble(text, a.src, a.profile)
    except AsmError as e:
        print(e, file=sys.stderr); return 1
    for w in prog.warnings: print(w, file=sys.stderr)
    if prog.warnings and a.Werror: return 1
    out = a.output or os.path.splitext(a.src)[0] + ('.bin' if a.format == 'bin' else '.hex')
    write(prog.words, out, a.format)
    if a.listing:
        with open(a.listing, 'w', newline='\n') as f: f.write(prog.listing() + '\n')
    print(f'{a.src}: {len(prog.words)} words -> {out} ({a.format})')
    return 0


if __name__ == '__main__':
    sys.exit(main())
