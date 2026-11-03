#!/usr/bin/env python3
"""Keeps sw/isa/mahi.toml and the hardware in agreement.

  python sw/isa/check.py            check; exit 1 on any mismatch
  python sw/isa/check.py --update   regenerate sw/isa/ISA.md from mahi.toml, then check

Checks: (1) the spec is self-consistent (unique names and opcodes, syntax covers exactly the format's fields,
operand roles agree with the read/write enables in `ctrl`); (2) decoder.sv in ASIC/src/rtl and FPGA/src/rtl:
the opcode localparams, the field slices and every case arm's control outputs; (3) the golden model
ASIC/scripts/isa.py: opcode numbers and its encoders; (4) the [profiles] sizes against gpu_pkg.sv;
(5) ISA.md is up to date.
"""
import os, re, sys
HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.environ.get('MAHI_REPO') or os.path.normpath(os.path.join(HERE, '..', '..'))
sys.path.insert(0, HERE)
from mahi_isa import ISA, TOKEN_FIELDS

errors = []
def err(m): errors.append(m)
def read(p): return open(p, encoding='utf-8').read()

DECODERS = ['ASIC/src/rtl/decoder.sv', 'FPGA/src/rtl/decoder.sv']
RTL_NAME = {'BRnzp': 'BR', 'RET_FN': 'RET'}


# ---------------------------------------------------------------- (1) the spec itself
def check_spec():
    seen = {}
    for i in ISA.instrs:
        if i.opcode in seen: err(f'spec: opcode {i.opcode} used by {seen[i.opcode]} and {i.name}')
        seen[i.opcode] = i.name
        if not 0 <= i.opcode < (1 << ISA.width('op')): err(f'spec: {i.name} opcode {i.opcode} does not fit')
        for pattern in [i.syntax] + i.legacy:
            used = [f for t in pattern for f in TOKEN_FIELDS.get(t, [])]
            bad = [t for t in pattern if t not in TOKEN_FIELDS and not re.fullmatch(r'-?\d+', t)]
            if bad: err(f'spec: {i.name} syntax token(s) {bad} unknown')
            if sorted(used) != sorted(i.fields):
                err(f'spec: {i.name} syntax {pattern} uses fields {sorted(used)}, format {i.format} has {sorted(i.fields)}')
        c, roles = i.ctrl, i.reg_roles()
        want = {'rs_read_enable': 'rs' in roles,
                'rt_read_enable': 'rt' in roles or roles.get('rd') == 'rv',
                'rd_read_enable': roles.get('rd') == 'rc',
                'reg_write_enable': roles.get('rd') in ('rd', 'rc')}
        for k, v in want.items():
            if bool(c.get(k, 0)) != v: err(f'spec: {i.name} operand roles {roles} imply {k}={int(v)}, ctrl says {c.get(k, 0)}')


# ---------------------------------------------------------------- (2) decoder.sv
def sv_value(s):
    s = s.strip()
    m = re.fullmatch(r"(\d+)?'([bdh])([0-9a-fA-F_]+)", s)
    if m: return int(m.group(3).replace('_', ''), {'b': 2, 'd': 10, 'h': 16}[m.group(2)])
    if re.fullmatch(r'\d+', s): return int(s)
    return None


def parse_decoder(src):
    body = src[src.index('localparam NOP'):src.index('always_comb')]
    ops = {RTL_NAME.get(n, n): int(v) for n, v in re.findall(r"(\w+)\s*=\s*6'd(\d+)", body)}
    case = src[src.index('case (instruction[31:26])'):src.index('endcase')]
    arms = {}
    for m in re.finditer(r'^\s*(\w+)\s*:\s*(begin(.*?)\bend\b|([^;\n]*;))', case, re.S | re.M):
        name = RTL_NAME.get(m.group(1), m.group(1))
        if name == 'default': continue
        text = m.group(3) if m.group(3) is not None else m.group(4)
        sig = {}
        for k, v in re.findall(r'decoded_(\w+)\s*=\s*([^;]+);', text):
            val = sv_value(v)
            sig[k] = val if val is not None else v.strip()
        arms[name] = sig
    return ops, arms, src


def check_decoder(path):
    ops, arms, src = parse_decoder(read(os.path.join(REPO, path)))
    spec_ops = {i.name: i.opcode for i in ISA.instrs}
    if ops != spec_ops:
        for n in sorted(set(ops) | set(spec_ops)):
            if ops.get(n) != spec_ops.get(n): err(f'{path}: opcode {n} = {ops.get(n)}, mahi.toml says {spec_ops.get(n)}')
    for f, rtl in (('rd', 'decoded_rd_address'), ('rs', 'decoded_rs_address'), ('nzp', 'decoded_nzp')):
        msb, lsb = ISA.field_bits[f]
        if not re.search(rf'{rtl}\s*=\s*instruction\[{msb}:{lsb}\]', src): err(f'{path}: {rtl} is not instruction[{msb}:{lsb}]')
    msb, lsb = ISA.field_bits['rt']
    if not re.search(rf'decoded_rt_address\s*=\s*instruction\[{msb}:{lsb}\]', src): err(f'{path}: rt field is not [{msb}:{lsb}]')
    rd_msb, rd_lsb = ISA.field_bits['rd']
    m = re.search(r'if \(instruction\[31:26\] == (\w+) \|\| instruction\[31:26\] == (\w+)\) begin\s*'
                  rf'decoded_rt_address = instruction\[{rd_msb}:{rd_lsb}\]', src)
    remap = sorted(RTL_NAME.get(x, x) for x in m.groups()) if m else []
    spec_remap = sorted(i.name for i in ISA.instrs if i.reg_roles().get('rd') == 'rv')
    if remap != spec_remap: err(f'{path}: rt<-rd remap for {remap}, mahi.toml has rv operands on {spec_remap}')
    msb, lsb = ISA.field_bits['imm16']
    if not re.search(rf'decoded_immediate\s*=\s*\{{\{{ \(DATA_BITS-16\)\{{instruction\[{msb}\]\}} \}}, instruction\[{msb}:{lsb}\]\}}', src):
        err(f'{path}: decoded_immediate is not sext(instruction[{msb}:{lsb}])')
    msb, lsb = ISA.field_bits['imm20']
    lui = arms.get('LUI', {}).get('immediate', '')
    if lui != f"{{instruction[{msb}:{lsb}], 12'b0}}": err(f'{path}: LUI immediate is {lui!r}, expected instruction[{msb}:{lsb}] << 12')
    for i in ISA.instrs:
        rtl = {k: v for k, v in arms.get(i.name, {}).items() if k != 'immediate' and v != 0}
        spec = {k: v for k, v in i.ctrl.items() if v != 0}
        if i.name not in arms and i.name != 'NOP': err(f'{path}: no case arm for {i.name}')
        if rtl != spec:
            diff = sorted(set(rtl.items()) ^ set(spec.items()))
            err(f'{path}: {i.name} control differs from mahi.toml ctrl: rtl {rtl} vs spec {spec} (diff {diff})')
    extra = set(arms) - {i.name for i in ISA.instrs}
    if extra: err(f'{path}: case arms for opcodes not in mahi.toml: {sorted(extra)}')


# ---------------------------------------------------------------- (3) golden model
def check_golden():
    sys.path.insert(0, os.path.join(REPO, 'ASIC', 'scripts'))
    import isa as g
    spec_ops = {i.name: i.opcode for i in ISA.instrs}
    if g.OP != spec_ops: err(f'ASIC/scripts/isa.py OP differs: {sorted(set(g.OP.items()) ^ set(spec_ops.items()))}')
    for n in g.UNOPS:
        if ISA.by_name[n].format != 'R2': err(f'isa.py UNOPS has {n}, which is format {ISA.by_name[n].format}')
    for n in g.BINOPS + g.FPOPS:
        if ISA.by_name[n].format != 'R3': err(f'isa.py BINOPS/FPOPS has {n}, which is format {ISA.by_name[n].format}')
    cases = [(g.enc_R('ADD', 1, 2, 3), ISA.encode('ADD', rd=1, rs=2, rt=3)),
             (g.enc_I('LDR', 4, 5, -2), ISA.encode('LDR', rd=4, rs=5, imm16=-2)),
             (g.enc_I('CONST', 6, 0, 0x7FFF), ISA.encode('CONST', rd=6, imm16=0x7FFF)),
             (g.enc_BR(5, 77), ISA.encode('BR', nzp=5, imm16=77)),
             (g.enc_CALL(300), ISA.encode('CALL', imm16=300)),
             (g.enc_RET(), ISA.encode('RET')), (g.enc_EXIT(), ISA.encode('EXIT')),
             (g.enc_LUI(7, 0xABCDE), ISA.encode('LUI', rd=7, imm20=0xABCDE))]
    for a, b in cases:
        if a != b: err(f'isa.py encoder gives {a:#010x}, mahi.toml gives {b:#010x}')


# ---------------------------------------------------------------- (4) profiles
def pkg_params(defines):
    """CFG_* localparams of gpu_pkg.sv with the given `defines set (a minimal `ifdef evaluator)."""
    out, stack = {}, []                    # stack of (taking, any_branch_taken)
    for line in read(os.path.join(REPO, 'FPGA/src/rtl/include/gpu_pkg.sv')).splitlines():
        s = line.strip()
        on = all(t for t, _ in stack)
        m = re.match(r'`(ifdef|ifndef|elsif)\s+(\w+)', s)
        if m and m.group(1) in ('ifdef', 'ifndef'):
            t = (m.group(2) in defines) == (m.group(1) == 'ifdef'); stack.append((t, t)); continue
        if m:
            _, taken = stack.pop(); t = not taken and m.group(2) in defines; stack.append((t, taken or t)); continue
        if s.startswith('`else'):
            _, taken = stack.pop(); stack.append((not taken, True)); continue
        if s.startswith('`endif'): stack.pop(); continue
        m = re.match(r'localparam int (CFG_\w+)\s*=\s*(\d+);', s)
        if m and on: out[m.group(1)] = int(m.group(2))
    return out


PROFILE_DEFINES = {'asic_mini': {'TARGET_ASIC', 'TARGET_ASIC_MINI'}, 'asic': {'TARGET_ASIC'}, 'fpga': {'TARGET_FPGA'}, 'sim': set()}
PROFILE_KEYS = {'cores': 'CFG_NUM_CORES', 'warps': 'CFG_NUM_WARPS', 'lanes': 'CFG_THREADS_PER_BLOCK',
                'pmem_addr_bits': 'CFG_PMEM_ADDR_BITS', 'dmem_addr_bits': 'CFG_DMEM_ADDR_BITS', 'shared_words': 'CFG_SHARED_MEM_SIZE'}


def check_profiles():
    if set(ISA.profiles) != set(PROFILE_DEFINES): err(f'mahi.toml profiles {sorted(ISA.profiles)} != {sorted(PROFILE_DEFINES)}')
    for name, defs in PROFILE_DEFINES.items():
        p, pkg = ISA.profiles.get(name, {}), pkg_params(defs)
        for k, cfg in PROFILE_KEYS.items():
            if p.get(k) != pkg.get(cfg): err(f'mahi.toml profile {name}.{k} = {p.get(k)}, gpu_pkg.sv {cfg} = {pkg.get(cfg)}')
    # chip-backed memory: gpu_mem_subsys.sv keeps a 7-bit block index (4 words per block) for each SRAM
    src = read(os.path.join(REPO, 'ASIC/src/rtl/gpu_mem_subsys.sv'))
    for key, rtl in (('chip_pmem_words', r'p_blk <= pm_ra\[(\d+):0\]'), ('chip_dmem_words', r'd_blk <= dm_ra\[(\d+):0\]')):
        m = re.search(rtl, src)
        words = 4 << (int(m.group(1)) + 1) if m else None
        if ISA.profiles['asic_mini'].get(key) != words: err(f'mahi.toml asic_mini.{key} = {ISA.profiles["asic_mini"].get(key)}, gpu_mem_subsys.sv backs {words}')


# ---------------------------------------------------------------- (5) ISA.md
def render_md():
    s, L = ISA.spec, []
    L += ['# mahi ISA reference', '',
          '<!-- GENERATED by sw/isa/check.py --update from sw/isa/mahi.toml. Do not edit; edit mahi.toml. -->', '',
          f'Version {ISA.version}. 32-bit instructions; program counters, branch targets and data addresses count 32-bit',
          'words. The version-0 table describes the hardware as built, quirks included; open design questions are listed at the end.', '',
          '## Fields', '', '| Field | Bits | Width |', '|---|---|---|']
    for f, (msb, lsb) in ISA.field_bits.items(): L.append(f'| `{f}` | [{msb}:{lsb}] | {msb - lsb + 1} |')
    L += ['', '## Formats', '', '| Format | Fields used |', '|---|---|']
    for k, v in ISA.formats.items(): L.append(f'| {k} | {", ".join(f"`{x}`" for x in v) or "(none)"} |')
    L += ['', '## Registers', '',
          f'{s["registers"]["count"]} registers `r0`..`r{s["registers"]["count"] - 1}` per thread, 32 bits. '
          f'Writes to {", ".join(f"`r{r}`" for r in sorted(ISA.read_only))} are discarded.', '',
          '| Register | Alias | Meaning |', '|---|---|---|']
    for k, v in s['registers']['special'].items(): L.append(f'| `r{k}` | `{v["alias"]}` | {v["meaning"]} |')
    L += ['', 'Condition codes `nzp` (per warp, reset to 0, written only by `CMP`): ' +
          ', '.join(f'`{k}` = {v}' for k, v in ISA.nzp_bits.items()) + '.', '',
          '## Operand notation', '',
          '`rd` destination; `rc` read and written (rd field); `rv` value to store (rd field, read only); `rs`, `rt` sources;',
          '`imm` signed 16-bit; `uimm20` unsigned 20-bit; `target` program word address; `[rs+imm]` = rs + sext(imm16); `[rs]` = rs.', '',
          '## Instructions', '', '| Op | Mnemonic | Format | Syntax | Unit | Semantics |', '|---|---|---|---|---|---|']
    for i in sorted(ISA.instrs, key=lambda i: i.opcode):
        syn = ', '.join(i.syntax) or ''
        if i.name == 'BR': syn = 'BR{n,z,p} target  (or BR nzp, target)'
        else: syn = f'{i.name} {syn}'.strip()
        L.append(f'| {i.opcode} | `{i.name}` | {i.format} | `{syn}` | {i.unit} | {i.sem.replace("|", chr(92) + "|")} |')
    L += ['', 'Accepted older operand forms (assembler/assembler.py syntax):', '']
    for i in ISA.instrs:
        if i.legacy: L.append(f'- `{i.name}`: ' + '; '.join(f'`{i.name} {", ".join(p)}`' for p in i.legacy))
    L += ['', '## Pseudo-instructions', '', '| Pseudo | Expansion |', '|---|---|']
    for p in s.get('pseudo', []):
        exp = '; '.join(f'`{e}`' for e in p.get('expand', [])) or p.get('note', '')
        if p.get('expand') and p.get('note'): exp += f' ({p["note"]})'
        L.append(f'| `{p["name"]} {p["syntax"]}` | {exp} |')
    L += ['', '## Profiles', '', '| Profile | Cores | Warps | Lanes | Threads/block | PMEM addr bits | DMEM addr bits | Shared words | Backed memory (chip) |',
          '|---|---|---|---|---|---|---|---|---|']
    for n, p in ISA.profiles.items():
        chip = f'{p["chip_pmem_words"]} + {p["chip_dmem_words"]} words' if 'chip_pmem_words' in p else '-'
        L.append(f'| {n} | {p["cores"]} | {p["warps"]} | {p["lanes"]} | {p["warps"] * p["lanes"]} | {p["pmem_addr_bits"]} | {p["dmem_addr_bits"]} | {p["shared_words"]} | {chip} |')
    L += ['', '## Open questions before version 1', '', '| ID | Topic | Question |', '|---|---|---|']
    for q in s.get('open', []): L.append(f'| {q["id"]} | {q["topic"]} | {q["text"]} |')
    return '\n'.join(L) + '\n'


def main():
    md_path = os.path.join(HERE, 'ISA.md')
    if '--update' in sys.argv:
        with open(md_path, 'w', encoding='utf-8', newline='\n') as f: f.write(render_md())
    check_spec()
    for d in DECODERS: check_decoder(d)
    check_golden()
    check_profiles()
    if not os.path.exists(md_path) or read(md_path) != render_md(): err('sw/isa/ISA.md is stale: run python sw/isa/check.py --update')
    for e in errors: print('ERROR', e)
    print(f'isa check: {len(ISA.instrs)} instructions, {len(DECODERS)} decoders, golden model, {len(ISA.profiles)} profiles: '
          + ('OK' if not errors else f'{len(errors)} error(s)'))
    return 1 if errors else 0


if __name__ == '__main__':
    sys.exit(main())
