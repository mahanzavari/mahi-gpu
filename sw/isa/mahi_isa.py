"""The mahi ISA as Python objects, loaded from mahi.toml (the only place encodings are defined).

    from mahi_isa import ISA
    w = ISA.encode('ADD', rd=1, rs=2, rt=3)
    ins, fields, stray = ISA.decode(w)      # stray = bits set outside the format's fields

Operand roles and syntax conventions are documented at the top of mahi.toml.
"""
import os, tomllib

SPEC_PATH = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'mahi.toml')

# syntax token -> instruction fields it occupies
TOKEN_FIELDS = {'rd': ['rd'], 'rc': ['rd'], 'rv': ['rd'], 'rs': ['rs'], 'rt': ['rt'],
                'imm': ['imm16'], 'uimm20': ['imm20'], 'target': ['imm16'], 'nzp': ['nzp'],
                '[rs+imm]': ['rs', 'imm16'], '[rs]': ['rs']}


def split_operands(s):
    """'rd, [rs+imm], rt' -> ['rd', '[rs+imm]', 'rt']; commas inside brackets do not split."""
    out, cur, depth = [], '', 0
    for c in s:
        if c in '[(': depth += 1
        elif c in '])': depth -= 1
        if c == ',' and depth == 0:
            out.append(cur.strip()); cur = ''
        else:
            cur += c
    if cur.strip(): out.append(cur.strip())
    return out


class Instr:
    def __init__(self, d, formats):
        self.name, self.opcode, self.format = d['name'], d['opcode'], d['format']
        self.fields = formats[self.format]
        self.syntax = split_operands(d['syntax'])
        self.legacy = [split_operands(s) for s in d.get('legacy', [])]
        self.unit, self.sem, self.ctrl = d['unit'], d['sem'], d.get('ctrl', {})

    def reg_roles(self):
        """{'rd': role} for register operands, e.g. MAC -> {'rd': 'rc', 'rs': 'rs', 'rt': 'rt'}."""
        roles = {}
        for t in self.syntax:
            if t in ('rd', 'rc', 'rv', 'rs', 'rt'): roles[TOKEN_FIELDS[t][0]] = t
            elif t in ('[rs+imm]', '[rs]'): roles['rs'] = 'rs'
        return roles

    def writes(self):
        return [f for f, role in self.reg_roles().items() if role in ('rd', 'rc')]

    def reads(self):
        return [f for f, role in self.reg_roles().items() if role in ('rc', 'rv', 'rs', 'rt')]


class Isa:
    def __init__(self, path=SPEC_PATH):
        with open(path, 'rb') as f: self.spec = tomllib.load(f)
        s = self.spec
        self.version = s['meta']['version']
        self.field_bits = {k: tuple(v) for k, v in s['fields'].items()}
        self.formats = s['formats']
        self.instrs = [Instr(d, self.formats) for d in s['instr']]
        self.by_name = {i.name: i for i in self.instrs}
        self.by_opcode = {i.opcode: i for i in self.instrs}
        self.nzp_bits = s['nzp']
        self.read_only = set(s['registers']['read_only'])
        self.reg_alias = {v['alias']: int(k) for k, v in s['registers']['special'].items()}
        self.pseudo = {p['name']: p for p in s.get('pseudo', [])}
        self.profiles = s['profiles']

    # ---- fields
    def width(self, f):
        msb, lsb = self.field_bits[f]
        return msb - lsb + 1

    def mask(self, f):
        msb, lsb = self.field_bits[f]
        return ((1 << (msb - lsb + 1)) - 1) << lsb

    def get(self, word, f):
        msb, lsb = self.field_bits[f]
        return (word >> lsb) & ((1 << (msb - lsb + 1)) - 1)

    def put(self, f, value):
        if not 0 <= value < (1 << self.width(f)):
            raise ValueError(f'{f} value {value} does not fit {self.width(f)} bits')
        return value << self.field_bits[f][1]

    # ---- encode / decode
    def encode(self, name, **fields):
        """Canonical encoding; `fields` are raw field values (imm16 may be given signed)."""
        ins = self.by_name[name]
        extra = set(fields) - set(ins.fields)
        if extra: raise ValueError(f'{name} has no field(s) {sorted(extra)}')
        w = self.put('op', ins.opcode)
        for f in ins.fields:
            v = fields.get(f, 0)
            if f == 'imm16' and v < 0: v &= 0xFFFF
            w |= self.put(f, v)
        return w

    def decode(self, word):
        """(Instr or None, {field: value}, stray_bits). stray_bits are set bits the format does not use:
        the decoder ignores them, so they only make an encoding non-canonical."""
        word &= 0xFFFFFFFF
        ins = self.by_opcode.get(self.get(word, 'op'))
        if ins is None: return None, {}, word & ~self.mask('op') & 0xFFFFFFFF
        used = self.mask('op')
        for f in ins.fields: used |= self.mask(f)
        return ins, {f: self.get(word, f) for f in ins.fields}, word & ~used & 0xFFFFFFFF

    def nzp_text(self, v):
        return ''.join(c for c in 'nzp' if v & self.nzp_bits[c])

    def nzp_value(self, s):
        v = 0
        for c in s.lower():
            if c not in self.nzp_bits: raise ValueError(f'bad condition {s!r} (letters n, z, p)')
            v |= self.nzp_bits[c]
        return v

    def profile(self, name):
        p = dict(self.profiles[name])
        p['pmem_words'] = p.get('chip_pmem_words', 1 << min(p['pmem_addr_bits'], self.width('imm16')))
        p['dmem_words'] = p.get('chip_dmem_words', 1 << min(p['dmem_addr_bits'], 32))
        return p


ISA = Isa()
