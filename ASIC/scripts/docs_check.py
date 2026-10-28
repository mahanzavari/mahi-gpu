#!/usr/bin/env python3
"""Keeps ASIC/docs honest.

  docs_check.py            check: fail on drift
  docs_check.py --update   rewrite the GENERATED blocks from the code, then check

Checks: (1) generated tables (profile params from gpu_pkg.sv, opcodes from decoder.sv vs isa.py, flow config),
(2) every `file.ext:line` citation points at an existing file with enough lines,
(3) static facts the limitation register relies on (regex anchors in the RTL),
(4) relative markdown links and #anchors resolve, (5) informational: header commit vs HEAD.
"""
import os, re, subprocess, sys
HERE = os.path.dirname(os.path.abspath(__file__))
ASIC = os.path.dirname(HERE)
REPO = os.path.dirname(ASIC)
DOCS = os.path.join(ASIC, 'docs')
sys.path.insert(0, HERE)
errors, notes = [], []

def read(p): return open(p, encoding='utf-8', errors='replace').read()
def err(m): errors.append(m)

# ------------------------------------------------------------ generated blocks
def full_profile_pkg(text):
    """gpu_pkg.sv without the TARGET_ASIC_MINI overlay (the docs describe the full ASIC profile)."""
    return re.sub(r'`ifdef TARGET_ASIC_MINI\n.*?`else\n(.*?)`endif\n', r'\1', text, flags=re.S)

def profile_table():
    prof, vals, order = None, {'asic': {}, 'fpga': {}, 'sim': {}}, []
    for line in full_profile_pkg(read(f'{ASIC}/src/rtl/include/gpu_pkg.sv')).splitlines():
        s = line.strip()
        if s.startswith('`ifdef TARGET_ASIC'): prof = 'asic'
        elif s.startswith('`elsif TARGET_FPGA'): prof = 'fpga'
        elif s.startswith('`else') and prof: prof = 'sim'
        elif s.startswith('`endif'): prof = None
        m = re.match(r'localparam int (CFG_\w+)\s*=\s*(\d+);', s)
        if m and prof:
            vals[prof][m.group(1)] = m.group(2)
            if m.group(1) not in order: order.append(m.group(1))
    rows = ['| Parameter (`gpu_pkg.sv`) | ASIC | FPGA | sim (default) |', '|---|---|---|---|']
    for k in order: rows.append(f"| `{k}` | {vals['asic'].get(k,'-')} | {vals['fpga'].get(k,'-')} | {vals['sim'].get(k,'-')} |")
    return '\n'.join(rows)

ALIAS = {'BRnzp': 'BR', 'RET_FN': 'RET', 'EXIT': 'EXIT'}
def opcode_line():
    src = read(f'{ASIC}/src/rtl/decoder.sv')
    body = src[src.index('localparam NOP'):src.index('always_comb')]
    pairs = re.findall(r'(\w+)\s*=\s*6\'d(\d+)', body)
    import isa
    for n, v in pairs:
        isa_name = ALIAS.get(n, n)
        if isa.OP.get(isa_name) != int(v): err(f'opcode mismatch decoder.sv {n}={v} vs scripts/isa.py {isa.OP.get(isa_name)}')
    missing = set(isa.OP) - {ALIAS.get(n, n) for n, _ in pairs}
    if missing: err(f'opcodes in isa.py but not decoder.sv: {sorted(missing)}')
    return ' '.join(f'{n}={v}' for n, v in pairs)

def flow_table():
    cfg, in_vf = {}, False
    for l in read(f'{ASIC}/flow/config.yaml').splitlines():
        m = re.match(r'^([A-Z_0-9]+):\s*"?([^"#]*)"?', l)
        if m:
            in_vf = (m.group(1) == 'VERILOG_FILES')
            if m.group(2).strip(): cfg[m.group(1)] = m.group(2).strip()
            continue
        m2 = re.match(r'^\s*-\s*"(.*)"', l)
        if m2 and in_vf: cfg['VERILOG_FILES'] = m2.group(1)
        elif not m2 and l.strip() and not l.lstrip().startswith('#'): in_vf = False
    g = lambda k: cfg.get(k, '?')
    rows = ['| Key | Value |', '|---|---|',
            f"| `DESIGN_NAME` | `{g('DESIGN_NAME')}` |", f"| `VERILOG_FILES` | `{g('VERILOG_FILES')}` |",
            f"| `CLOCK_PORT` / `CLOCK_PERIOD` | `{g('CLOCK_PORT')}` / {g('CLOCK_PERIOD')} ns |",
            f"| `FP_SIZING` / `DIE_AREA` / `CORE_AREA` | {g('FP_SIZING')} / {g('DIE_AREA')} / {g('CORE_AREA')} (the mini profile uses a 2.4 mm die) |",
            f"| `PL_TARGET_DENSITY_PCT` | {g('PL_TARGET_DENSITY_PCT')} |", f"| `PDK` | `{g('PDK')}` |",
            f"| `SYNTH_STRATEGY` | `{g('SYNTH_STRATEGY')}` |",
            f"| `SYNTH_CLK_DRIVING_CELL` | `{g('SYNTH_CLK_DRIVING_CELL')}` |",
            f"| `RUN_POST_GRT_DESIGN_REPAIR` / slew % / cap % / max wire | {g('RUN_POST_GRT_DESIGN_REPAIR')} / {g('GRT_DESIGN_REPAIR_MAX_SLEW_PCT')} / {g('GRT_DESIGN_REPAIR_MAX_CAP_PCT')} / {g('GRT_DESIGN_REPAIR_MAX_WIRE_LENGTH')} um |",
            f"| `PL_RESIZER_HOLD_SLACK_MARGIN` | {g('PL_RESIZER_HOLD_SLACK_MARGIN')} ns |",
            f"| `RUN_POST_GRT_RESIZER_TIMING` / `GRT_RESIZER_HOLD_SLACK_MARGIN` | {g('RUN_POST_GRT_RESIZER_TIMING')} / {g('GRT_RESIZER_HOLD_SLACK_MARGIN')} ns |",
            f"| `DRT_ANTENNA_REPAIR_ITERS` / `…_MARGIN` | {g('DRT_ANTENNA_REPAIR_ITERS')} / {g('DRT_ANTENNA_REPAIR_MARGIN')} % |",
            f"| `KLAYOUT_CONFLICT_RESOLUTION` | `{g('KLAYOUT_CONFLICT_RESOLUTION')}` |",
            f"| `ERROR_ON_MAGIC_DRC` | {g('ERROR_ON_MAGIC_DRC')} |"]
    return '\n'.join(rows)

BLOCKS = {('02-architecture.md', 'profile'): profile_table, ('03-isa.md', 'opcodes'): opcode_line,
          ('07-physical-flow.md', 'flowcfg'): flow_table}

def check_blocks(update):
    for (fn, tag), gen in BLOCKS.items():
        p = f'{DOCS}/{fn}'; s = read(p)
        pat = re.compile(rf'(<!-- BEGIN GENERATED: {tag} -->\n)(.*?)(\n<!-- END GENERATED: {tag} -->)', re.S)
        m = pat.search(s)
        if not m: err(f'{fn}: missing GENERATED block "{tag}"'); continue
        want = gen()
        if m.group(2).strip() != want.strip():
            if update: open(p, 'w').write(s[:m.start(2)] + want + s[m.end(2):]); notes.append(f'updated {fn} [{tag}]')
            else: err(f'{fn}: generated block "{tag}" is stale (run scripts/docs_check.py --update)')

# ------------------------------------------------------------ citations
CIT = re.compile(r'`?([\w./-]+\.(?:sv|v|py|sh|yaml|md|f)):(\d+)(?:-(\d+))?')
def resolve(path):
    cands = [f'{ASIC}/{path}', f'{REPO}/{path}', f'{ASIC}/src/rtl/{path}', f'{ASIC}/scripts/{path}', f'{ASIC}/src/tb/unit/{path}',
             f'{ASIC}/src/rtl/sva/{path}', f'{ASIC}/src/tb/random/{path}', f'{ASIC}/src/rtl/include/{path}', f'{ASIC}/flow/{path}']
    return [c for c in cands if os.path.isfile(c)]

def check_citations():
    n = 0
    for fn in sorted(os.listdir(DOCS)):
        if not fn.endswith('.md'): continue
        for ln, line in enumerate(read(f'{DOCS}/{fn}').splitlines(), 1):
            for m in CIT.finditer(line):
                path, a, b = m.group(1), int(m.group(2)), m.group(3)
                hi = int(b) if b else a
                cands = resolve(path)
                if not cands: err(f'{fn}:{ln}: cited file not found: {path}'); continue
                n += 1
                if not any(len(read(c).splitlines()) >= hi for c in cands):
                    err(f'{fn}:{ln}: {path}:{a} beyond end of file')
    notes.append(f'{n} citations checked')

# ------------------------------------------------------------ static facts
def has(path, rx, want=True, why=''):
    full = path if os.path.isabs(path) else f'{ASIC}/{path}'
    if not os.path.isfile(full): err(f'static: {path} missing'); return
    found = re.search(rx, read(full), re.S) is not None
    if found != want: err(f'static: {path} {"lacks" if want else "unexpectedly has"} /{rx}/  ({why})')

def check_static():
    R = 'src/rtl'
    has(f'{R}/gpu_asic_top.sv', r"gpu_mem_subsys mem_inst", why='L3 resolved: memory attached')
    has(f'{R}/gpu_asic_top.sv', r"\.program_mem_read_ready\(pm_rr\)", why='L3 resolved')
    has(f'{R}/gpu_mem_subsys.sv', r"\|dm_ra\[13:7\]", why='L15 out-of-range data blocks')
    has(f'{R}/gpu_asic_top.sv', r"rst_cnt\s*<=\s*4'd8", why='L16 soft reset')
    t = read(f'{ASIC}/{R}/gpu_asic_top.sv')
    assigns = set(re.findall(r'dcr_addr\s*<=\s*([^;]+);', t))
    if not assigns <= {"8'd0", "8'h00"}: err(f'static: gpu_asic_top dcr_addr assigned from {assigns} (L13 says always 0)')
    has(f'{R}/l2_cache.sv', r"assign ev_read_acc\s*=\s*1'b0", why='L4')
    has(f'{R}/alu.sv', r"`ifdef USE_COMB_DIV", why='L2')
    has(f'{R}/alu.sv', r"\(rs < rt\), \(rs == rt\), \(rs > rt\)", why='L5 unsigned CMP')
    has(f'{R}/pc.sv', r"localparam STACK_DEPTH = 8", why='L6'); has(f'{R}/pc.sv', r"reg \[\$clog2\(STACK_DEPTH\)-1:0\]\s+stack_ptr", why='L6')
    has(f'{R}/scheduler.sv', r"localparam STACK_DEPTH = 4", why='L7')
    has(f'{R}/scheduler.sv', r"is_reconverge = ", why='L1'); has(f'{R}/scheduler.sv', r"barrier_count >= num_active_warps_comb", why='L1')
    has(f'{R}/gpu.sv', r"\.exception_raised\(core_exc\[i\]\)", why='L12 resolved: faults exported')
    has(f'{R}/gpu_asic_top.sv', r"wb_adr_i\[7:0\] == 8'h08", why='L12 resolved: FAULT_INFO')
    has(f'{R}/core.sv', r"assign ex_has_sync_div = ex_sync", why='L1: SYNC while diverged faults')
    has(f'{R}/core.sv', r"divider #\(", why='L2 resolved: shared divider')
    has(f'{R}/lsu.sv', r"rs\[i\]\[ADDR_BITS-1:0\] \+ ext_addr_offset", why='L14 address truncation')
    has(f'{R}/core.sv', r"MAX_MEM_ADDR\s*=\s*32'h0000_FFFF", why='L14')
    # fixes present in ASIC
    has(f'{R}/l2_cache.sv', r"vwb_can_push = vwb_push_ready && !vwb_push_valid", why='B4')
    has(f'{R}/core.sv', r"if_instruction_valid = if_instruction_valid_raw && \(if_fetched_pc == if_pc\)", why='B3')
    has(f'{R}/fetcher.sv', r"current_pc != fetch_pc", why='B3')
    has(f'{R}/core.sv', r"flush_warp_mask\[id_warp_id\] && !\(valid_issue && if_instruction_valid\)", why='B2')
    has(f'{R}/pc.sv', r"nzp\[warp_id\] <= alu_out\[2:0\]", why='B1')
    # L10: generic design still lacks the fixes
    g = f'{REPO}/src/rtl'
    has(f'{g}/l2_cache.sv', r"vwb_can_push", want=False, why='L10: src/rtl not fixed (update L10 if you ported it)')
    has(f'{g}/core.sv', r"if_fetched_pc", want=False, why='L10'); has(f'{g}/fetcher.sv', r"fetched_pc", want=False, why='L10')
    has(f'{g}/core.sv', r"flush_warp_mask\[id_warp_id\] \|\| \(valid_issue", why='L10 buggy ID latch still in src/rtl')
    for f in ('controller.sv', 'core_pmu.sv', 'dcr.sv', 'axi4_adaptor.sv', 'axi_ram.v'):      # claims in 01-overview
        a, b = f'{g}/{f}', f'{ASIC}/{R}/{f}'
        if read(a) != read(b): err(f'static: {f} no longer identical to src/rtl (01-overview says "=")')
    # physical-flow page, only if the run is present
    run = f'{ASIC}/flow/runs/RUN_2026-10-19_14-54-17'
    if os.path.isdir(run):
        if os.path.isdir(f'{run}/final'): err('static: run RUN_2026-10-19_14-54-17 now has final/ — update 07-physical-flow')
        st = f'{run}/06-yosys-synthesis/reports/stat.rpt'
        if os.path.isfile(st) and not re.search(r'\b854\b.*dfxtp', read(st)): err('static: flop count in stat.rpt no longer 854 — update 07')
    else: notes.append('flow run directory absent: physical-flow facts not re-checked')

# ------------------------------------------------------------ links and anchors
def slug(h):
    h = re.sub(r'[`*_]', '', h.strip().lower()); h = re.sub(r'[^\w\- ]', '', h); return h.replace(' ', '-')
def check_links():
    anchors = {}
    for fn in os.listdir(DOCS):
        if fn.endswith('.md'):
            anchors[fn] = {slug(m.group(1)) for m in re.finditer(r'^#{1,6}\s+(.*)$', read(f'{DOCS}/{fn}'), re.M)}
    for fn in sorted(anchors):
        for m in re.finditer(r'\]\(([^)\s]+)\)', read(f'{DOCS}/{fn}')):
            tgt = m.group(1)
            if tgt.startswith(('http', 'mailto')): continue
            path, _, frag = tgt.partition('#')
            if path:
                full = os.path.normpath(os.path.join(DOCS, path))
                if not os.path.exists(full): err(f'{fn}: broken link {tgt}'); continue
                if frag and path.endswith('.md') and slug(frag) not in anchors.get(os.path.basename(path), set()):
                    err(f'{fn}: anchor #{frag} not found in {path}')
            elif frag and frag not in anchors[fn]: err(f'{fn}: anchor #{frag} not found')

def check_headers():
    try: head = subprocess.check_output(['git', '-C', REPO, 'rev-parse', '--short', 'HEAD'], text=True).strip()
    except Exception: return
    stale = [fn for fn in sorted(os.listdir(DOCS)) if fn.endswith('.md') and (m := re.search(r'Verified against commit `(\w+)`', read(f'{DOCS}/{fn}'))) and m.group(1) != head]
    if stale: notes.append(f'INFO: pages verified against an older commit than HEAD ({head}): {", ".join(stale)}')

def check_datasheet():
    p = f'{DOCS}/datasheet/mahi-gpu-datasheet.tex'
    if not os.path.isfile(p): err('datasheet .tex missing'); return
    t = read(p)
    pkg = full_profile_pkg(read(f'{ASIC}/src/rtl/include/gpu_pkg.sv'))
    asic = pkg[pkg.index('`ifdef TARGET_ASIC'):pkg.index('`elsif TARGET_FPGA')]
    def cfg(k): return int(re.search(rf'{k}\s*=\s*(\d+)', asic).group(1))
    facts = {  # (description, value that must appear in the datasheet text)
        'shared memory words': f"\\textbf{{{cfg('CFG_SHARED_MEM_SIZE')} words}}",
        'warps/lanes': f"{cfg('CFG_NUM_WARPS')} warps",
        'L2 lines': f"{cfg('CFG_L2_CACHE_LINES')} lines",
        'VWB depth': f"{cfg('CFG_VWB_DEPTH')}-entry",
    }
    for what, needle in facts.items():
        if needle not in t: err(f'datasheet: expected "{needle}" for {what} (gpu_pkg.sv changed?)')
    # pin count from the module header of gpu_asic_top
    top = read(f'{ASIC}/src/rtl/gpu_asic_top.sv'); hdr = top[:top.index(');')]
    pins = 0
    for m in re.finditer(r'(input|output)\s+(?:wire|reg)?\s*(?:\[(\d+):0\])?\s*\w+', hdr):
        pins += int(m.group(2)) + 1 if m.group(2) else 1
    if f'{pins} signal pins' not in t: err(f'datasheet: pin count {pins} not stated as "{pins} signal pins"')
    nop = len(re.findall(r"=\s*6'd\d+", read(f'{ASIC}/src/rtl/decoder.sv').split('always_comb')[0]))
    if f'{nop} opcodes defined' not in t: err(f'datasheet: opcode count {nop} not stated')
    for cmd in re.findall(r'make (limits|docs-check|verify|datasheet)', t): pass
    notes.append(f'datasheet cross-checked (pins={pins}, opcodes={nop})')

if __name__ == '__main__':
    update = '--update' in sys.argv
    check_blocks(update); check_citations(); check_static(); check_links(); check_datasheet(); check_headers()
    for n in notes: print('note:', n)
    if errors:
        print('\n'.join('FAIL: ' + e for e in errors)); print(f'docs-check: {len(errors)} problem(s)'); sys.exit(1)
    print('docs-check: OK')
