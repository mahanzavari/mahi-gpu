#!/usr/bin/env python3
"""Colour-by-block die map of a placed/routed design (like the annotated die shots in vendor whitepapers).

  die_map.py --def RUN/31-openroad-detailedrouting/gpu_asic_top.def \
             --netlist RUN/06-yosys-synthesis/gpu_asic_top.nl.v --lef <std-cell.lef> <macro.lef> \
             --out docs/figures/die_map.png --regions-out docs/figures/die_regions.png

Two pictures: the per-cell map (every standard cell coloured by block) and a flat region map (majority block
per 12 um bin, smoothed, outlined) in the style of marketing die shots.

The synthesized netlist is flat, so the RTL block of a standard cell is *inferred*:
  1. every flip-flop (and any cell driving a named net) is seeded from the hierarchical net name Yosys kept
     (e.g. gpu_inst.core_block.core_inst.threads.reg_inst... -> "Register files");
  2. all other cells take the majority label of their netlist neighbours (iterated; clock/reset/enable nets
     with large fanout are ignored);
  3. cells added after synthesis (timing-repair buffers, clock tree, antenna diodes, taps) are drawn in grey tones.
Combinational-only blocks (ALU, decoder) have no registers to seed them and are absorbed by their neighbours,
so treat the map as "where the logic around each block's registers sits", not as a floorplan of the ALU itself.
"""
import argparse, collections, os, re, sys
import numpy as np
from PIL import Image, ImageDraw, ImageFont

HIER = [  # (regex on the dotted net name with [n] removed, label); first match wins
    (r'core_inst\.threads\.reg_inst', 'Register files'),
    (r'core_inst\.threads\.fpu_inst', 'FP32 FMA units'),
    (r'core_inst\.threads\.pc_inst', 'PC / call stacks'),
    (r'core_inst\.threads\.alu', 'ALUs'),
    (r'core_inst\.shared_mem', 'Shared memory'),
    (r'core_inst\.lsu', 'Load/store unit'),
    (r'core_inst\.(scheduler|fp_scoreboard)', 'Scheduler'),
    (r'core_inst\.fetcher', 'Fetcher'),
    (r'core_inst\.', 'Core pipeline / control'),
    (r'dcache_inst', 'D-cache (L1)'),
    (r'icache_inst', 'I-cache (L1)'),
    (r'unified_cache\.vwb', 'L2 victim write buffer'),
    (r'unified_cache\.data_eng', 'L2 data engine'),
    (r'unified_cache\.', 'L2 control / tags'),
    (r'(data_memory_controller|program_memory_controller|program_mem_|data_mem_)', 'Memory controllers'),
    (r'dispatch|dcr_instance', 'Dispatch / DCR'),
    (r'^mem_inst\.', 'Host memory glue (Wishbone window)'),
]
HIER_LABELS = {lab for _, lab in HIER}
PALETTE = {
    'Register files': (230, 57, 70), 'FP32 FMA units': (244, 162, 97), 'PC / call stacks': (233, 196, 106),
    'ALUs': (255, 214, 10), 'Shared memory': (42, 157, 143), 'Load/store unit': (38, 70, 83),
    'Scheduler': (131, 56, 236), 'Fetcher': (255, 0, 110), 'Core pipeline / control': (160, 108, 213),
    'D-cache (L1)': (58, 134, 255), 'I-cache (L1)': (0, 180, 216), 'L2 victim write buffer': (144, 224, 239),
    'L2 data engine': (6, 214, 160), 'L2 control / tags': (17, 138, 178), 'Memory controllers': (188, 108, 37),
    'Dispatch / DCR': (200, 200, 120), 'Host memory glue (Wishbone window)': (120, 190, 80),
    'Unattributed logic': (110, 110, 120),
    'Timing-repair buffers': (170, 170, 170), 'Clock tree': (255, 255, 255), 'Antenna diodes': (80, 80, 80),
    'Tap cells': (45, 45, 50),
}
MACRO_COL = (30, 30, 36)
MACRO_NAMES = {'pmem': 'PMEM SRAM', 'dmem': 'DMEM SRAM', 'sram': 'L2 data SRAM'}


def block_of(netname):
    n = re.sub(r'\[\d+\]', '', netname.lstrip('\\')).replace('\\', '')
    if not (n.startswith('gpu_inst') or n.startswith('mem_inst')): return None
    for rx, lab in HIER:
        if re.search(rx, n): return lab
    return None


def parse_netlist(path):
    t = open(path).read()
    inst = {}                     # name -> (type, {pin: net})
    for ty, name, body in re.findall(r'^\s*(sky130_\w+)\s+(\S+)\s*\((.*?)\);', t, re.S | re.M):
        inst[name] = (ty, {p: v.strip() for p, v in re.findall(r'\.(\w+)\(([^)]*)\)', body)})
    return inst


def infer_labels(inst, max_fanout=48, iters=40):
    """Seed from named output nets, then majority-vote over netlist neighbours (seeds stay fixed)."""
    OUT = ('X', 'Y', 'Q', 'HI', 'LO', 'dout0', 'dout1')
    lab, net_cells = {}, collections.defaultdict(list)
    for n, (ty, pins) in inst.items():
        for p, net in pins.items():
            net_cells[net].append(n)
            if p in OUT and n not in lab:
                b = block_of(net)
                if b: lab[n] = b
    fixed = set(lab)
    nbrs = collections.defaultdict(list)          # cell -> [(neighbour, weight)]
    for net, cells in net_cells.items():
        k = len(cells)
        if k < 2 or k > max_fanout: continue
        w = 1.0 / (k - 1)
        for a in cells:
            for b in cells:
                if a != b: nbrs[a].append((b, w))
    for _ in range(iters):
        new = {}
        for n in inst:
            if n in fixed: continue
            votes = collections.Counter()
            for m, w in nbrs.get(n, ()):
                l = lab.get(m)
                if l: votes[l] += w
            if votes:
                best = votes.most_common(1)[0][0]
                if lab.get(n) != best: new[n] = best
        if not new: break
        lab.update(new)
    return lab, len(fixed)


def lef_sizes(files):
    sizes, name = {}, None
    for f in files:
        for l in open(f):
            m = re.match(r'\s*MACRO (\S+)', l)
            if m: name = m.group(1)
            m = re.match(r'\s*SIZE ([\d.]+) BY ([\d.]+)', l)
            if m and name: sizes[name] = (float(m.group(1)), float(m.group(2))); name = None
    return sizes


def parse_def(path):
    txt = open(path).read()
    units = int(re.search(r'UNITS DISTANCE MICRONS (\d+)', txt).group(1))
    m = re.search(r'DIEAREA\s*\(\s*(-?\d+)\s+(-?\d+)\s*\)\s*\(\s*(-?\d+)\s+(-?\d+)\s*\)', txt)
    die = tuple(map(int, m.groups()))
    sec = txt[txt.index('COMPONENTS'):txt.index('END COMPONENTS')]
    comp = re.compile(r'-\s+(\S+)\s+(\S+)\s+(?:\+\s+\S+\s+\S+\s+)*\+\s+(?:PLACED|FIXED)\s+\(\s*(-?\d+)\s+(-?\d+)\s*\)\s+(\w+)', re.S)
    comps = [(m.group(1), m.group(2), int(m.group(3)), int(m.group(4)), m.group(5))
             for m in (comp.match(st.strip()) for st in sec.split(';')[1:]) if m]
    return die, units, comps


def fonts():
    try:
        return (ImageFont.truetype('DejaVuSans-Bold.ttf', 30), ImageFont.truetype('DejaVuSans-Bold.ttf', 22),
                ImageFont.truetype('DejaVuSans.ttf', 16))
    except OSError:
        d = ImageFont.load_default(); return d, d, d


def macro_label(name):
    key = name.split('.')[-2] if name.count('.') >= 2 else name
    return MACRO_NAMES.get(key, key)


def largest_component(mask):
    """4-connected components on a small grid; returns the cells of the biggest one."""
    seen = np.zeros_like(mask, bool); best = []
    for sy, sx in zip(*np.nonzero(mask)):
        if seen[sy, sx]: continue
        comp, stack = [], [(sy, sx)]; seen[sy, sx] = True
        while stack:
            cy, cx = stack.pop(); comp.append((cy, cx))
            for ny, nx in ((cy + 1, cx), (cy - 1, cx), (cy, cx + 1), (cy, cx - 1)):
                if 0 <= ny < mask.shape[0] and 0 <= nx < mask.shape[1] and mask[ny, nx] and not seen[ny, nx]:
                    seen[ny, nx] = True; stack.append((ny, nx))
        if len(comp) > len(best): best = comp
    return best


def legend(d, x0, y, rows, f, f_s, macros_n, scale, extra_note, with_counts):
    """rows: [(label, colour, cells, area_pct)]"""
    d.text((x0, y), 'Block (inferred)', fill=(20, 20, 20), font=f)
    if with_counts: d.text((x0 + 410, y), 'cells   area', fill=(20, 20, 20), font=f)
    y += 40
    for lab, col, n, pct in rows:
        d.rectangle([x0, y, x0 + 24, y + 22], fill=col, outline=(0, 0, 0)); d.text((x0 + 36, y + 2), lab, fill=(20, 20, 20), font=f_s)
        if with_counts: d.text((x0 + 410, y + 2), f'{n:6d} {pct:5.1f}%', fill=(20, 20, 20), font=f_s)
        y += 30
    d.rectangle([x0, y, x0 + 24, y + 22], fill=MACRO_COL, outline=(0, 0, 0))
    d.text((x0 + 36, y + 2), f'SRAM macros ({macros_n} x 2 KB OpenRAM)', fill=(20, 20, 20), font=f_s); y += 50
    d.line([x0, y, x0 + 500 * scale, y], fill=(0, 0, 0), width=4); d.text((x0, y + 8), '500 um', fill=(0, 0, 0), font=f_s); y += 50
    d.multiline_text((x0, y), extra_note, fill=(70, 70, 70), font=f_s)


def new_canvas(img, title, legend_w=640):
    H, W = img.shape[:2]
    canvas = Image.new('RGB', (W + legend_w + 60, H + 140), (250, 250, 250)); canvas.paste(Image.fromarray(img), (30, 90))
    d = ImageDraw.Draw(canvas); f_big, f, f_s = fonts()
    d.text((30, 24), title, fill=(20, 20, 20), font=f_big); d.rectangle([29, 89, 30 + W, 90 + H], outline=(0, 0, 0), width=2)
    return canvas, d, f, f_s


def cell_map(a, cells, macros, scale, W, H, dw, dh, title):
    """cells: [(class, x, y, w, h)] in um. Paints every cell."""
    img = np.zeros((H, W, 3), np.uint8); img[:] = (14, 14, 18)

    def paint(x0, y0, w, h, col):
        px0, px1 = int(x0 * scale), max(int((x0 + w) * scale), int(x0 * scale) + 1)
        py0, py1 = int(y0 * scale), max(int((y0 + h) * scale), int(y0 * scale) + 1)
        img[max(H - py1, 0):max(H - py0, 0), max(px0, 0):min(px1, W)] = col

    area, count, cent = collections.Counter(), collections.Counter(), collections.defaultdict(list)
    for cls, x, y, w, h in cells:
        paint(x, y, w, h, PALETTE[cls]); area[cls] += w * h; count[cls] += 1
        if cls in HIER_LABELS: cent[cls].append((x + w / 2, y + h / 2))
    for name, xu, yu, w, h in macros:
        paint(xu, yu, w, h, MACRO_COL)
        paint(xu, yu, w, 1.5, (200, 200, 200)); paint(xu, yu + h - 1.5, w, 1.5, (200, 200, 200))
        paint(xu, yu, 1.5, h, (200, 200, 200)); paint(xu + w - 1.5, yu, 1.5, h, (200, 200, 200))
    canvas, d, f, f_s = new_canvas(img, title)
    for name, xu, yu, w, h in macros:
        d.text((30 + xu * scale + 8, 90 + H - (yu + h) * scale + 6), macro_label(name) + ' (2 KB macro)', fill=(255, 255, 255), font=f)
    total = sum(area.values()) or 1
    for cls, pts in cent.items():                                  # name each big block at the median of its cells
        if area[cls] / total < 0.035: continue
        xs = sorted(p[0] for p in pts); ys = sorted(p[1] for p in pts)
        tx, ty = 30 + xs[len(xs) // 2] * scale, 90 + H - ys[len(ys) // 2] * scale
        d.text((tx + 1, ty + 1), cls, fill=(0, 0, 0), font=f); d.text((tx, ty), cls, fill=(255, 255, 255), font=f)
    rows = [(c, PALETTE[c], count[c], 100 * area[c] / total) for c in sorted(area, key=lambda c: -area[c])]
    note = ('Block labels are inferred from register names plus netlist connectivity;\nALU/decoder logic (no registers) is absorbed by its neighbours.\n'
            f'Die {dw:.0f} x {dh:.0f} um. Shown: standard cells {sum(count.values()):,} (fillers omitted).')
    legend(d, 30 + W + 30, 90, rows, f, f_s, len(macros), scale, note, True)
    os.makedirs(os.path.dirname(os.path.abspath(a.out)), exist_ok=True); canvas.save(a.out)
    print(f'wrote {a.out} ({canvas.size[0]}x{canvas.size[1]})', file=sys.stderr)
    return area, count


def region_map(a, blk_cells, macros, scale, W, H, dw, dh, title):
    """Flat regions: area-weighted vote per 12 um bin, box-smoothed, argmax; outlines where the winner changes."""
    BIN = 12.0; gx, gy = int(dw / BIN) + 1, int(dh / BIN) + 1
    names = sorted({c for c, *_ in blk_cells}); idx = {n: i for i, n in enumerate(names)}
    vote = np.zeros((len(names), gy, gx), np.float32)
    for c, x, y, w, h in blk_cells: vote[idx[c], min(int(y / BIN), gy - 1), min(int(x / BIN), gx - 1)] += w * h
    k = 3                                                       # box smoothing radius in bins
    pad = np.pad(vote, ((0, 0), (k, k), (k, k))); sm = np.zeros_like(vote)
    for dy in range(-k, k + 1):
        for dx in range(-k, k + 1): sm += pad[:, k + dy:k + dy + gy, k + dx:k + dx + gx]
    tot = sm.sum(0); win = np.where(tot > 0.15 * tot[tot > 0].mean() * 0.5, sm.argmax(0), -1)
    for name, xu, yu, w, h in macros:                           # macros override
        win[int(yu / BIN):int((yu + h) / BIN) + 1, int(xu / BIN):int((xu + w) / BIN) + 1] = -2
    ys = np.minimum((np.arange(H)[::-1] / scale / BIN).astype(int), gy - 1); xs = np.minimum((np.arange(W) / scale / BIN).astype(int), gx - 1)
    big = win[np.ix_(ys, xs)]
    img = np.zeros((H, W, 3), np.uint8); img[:] = (14, 14, 18)
    pal = np.array([PALETTE[n] for n in names] + [(0, 0, 0)], np.uint8)
    m = big >= 0; img[m] = (pal[big[m]] * 0.82 + 20).astype(np.uint8)
    img[big == -2] = MACRO_COL
    edge = np.zeros((H, W), bool)
    edge[:, :-1] |= big[:, :-1] != big[:, 1:]; edge[:-1, :] |= big[:-1, :] != big[1:, :]
    edge = edge | np.roll(edge, 1, 0) | np.roll(edge, 1, 1)
    img[edge & (big != -1)] = (245, 245, 245)
    canvas, d, f, f_s = new_canvas(img, title, 560)
    for name, xu, yu, w, h in macros:
        d.text((30 + (xu + w / 2) * scale - 80, 90 + H - (yu + h / 2) * scale - 14), macro_label(name) + '\n2 KB macro', fill=(255, 255, 255), font=f, align='center')
    for n in names:                                              # label inside the block's largest connected region
        comp = largest_component(win == idx[n])
        if len(comp) * BIN * BIN < 0.007 * dw * dh: continue
        cy, cx = np.mean([c[0] for c in comp]), np.mean([c[1] for c in comp])
        cy, cx = min(comp, key=lambda c: (c[0] - cy) ** 2 + (c[1] - cx) ** 2)     # a bin that really belongs to the region
        tx, ty = 30 + (cx + 0.5) * BIN * scale - 5.5 * len(n), 90 + H - (cy + 0.5) * BIN * scale - 12
        d.text((tx + 2, ty + 2), n, fill=(0, 0, 0), font=f); d.text((tx, ty), n, fill=(255, 255, 255), font=f)
    sizes = collections.Counter()
    for c, x, y, w, h in blk_cells: sizes[c] += w * h
    rows = [(n, tuple(int(v * 0.82 + 20) for v in PALETTE[n]), 0, 0.0) for n in sorted(names, key=lambda c: -sizes[c])]
    note = 'Regions = majority block of the standard cells in each\n12 um bin (smoothed). Block membership is inferred from\nregister names + netlist connectivity, not from RTL hierarchy.'
    legend(d, 30 + W + 30, 90, rows, f, f_s, len(macros), scale, note, False)
    os.makedirs(os.path.dirname(os.path.abspath(a.regions_out)), exist_ok=True); canvas.save(a.regions_out)
    print(f'wrote {a.regions_out} ({canvas.size[0]}x{canvas.size[1]})', file=sys.stderr)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--def', dest='deff', required=True); ap.add_argument('--netlist', required=True)
    ap.add_argument('--lef', nargs='+', required=True); ap.add_argument('--out', required=True)
    ap.add_argument('--regions-out', default=None, help='also write the flat block-region map to this PNG')
    ap.add_argument('--px', type=int, default=2600, help='die width in pixels'); ap.add_argument('--title', default='')
    a = ap.parse_args()

    inst = parse_netlist(a.netlist)
    lab, seeds = infer_labels(inst)
    print(f'netlist cells {len(inst)}, seeded {seeds}, labelled {len(lab)}', file=sys.stderr)
    sizes = lef_sizes(a.lef)
    die, units, comps = parse_def(a.deff)
    dw, dh = (die[2] - die[0]) / units, (die[3] - die[1]) / units
    scale = a.px / dw; W, H = a.px, int(dh * scale)

    cells, macros = [], []                                       # cells: (class, x, y, w, h) in um (lower-left)
    for name, ty, x, y, o in comps:
        if ty not in sizes: continue
        w, h = sizes[ty]
        if o in ('E', 'W', 'FE', 'FW'): w, h = h, w
        xu, yu = (x - die[0]) / units, (y - die[1]) / units
        if 'sram' in ty: macros.append((name, xu, yu, w, h)); continue
        if '__fill' in ty or '__decap' in ty: continue
        if '__tap' in ty or name.startswith(('TAP_', 'PHY_')): cls = 'Tap cells'
        elif '__diode' in ty or name.startswith('ANTENNA'): cls = 'Antenna diodes'
        elif name in lab: cls = lab[name]
        elif name in inst: cls = 'Unattributed logic'
        elif 'clkbuf' in ty or 'clkinv' in ty or name.startswith(('clkbuf', 'clkload', 'delaynet')): cls = 'Clock tree'
        else: cls = 'Timing-repair buffers'
        cells.append((cls, xu, yu, w, h))

    title = a.title or 'Die map'
    area, count = cell_map(a, cells, macros, scale, W, H, dw, dh, title)
    if a.regions_out:
        blk = [(c, x + w / 2, y + h / 2, w, h) for c, x, y, w, h in cells if c in HIER_LABELS]
        region_map(a, blk, macros, scale, W, H, dw, dh, title + ' - block regions')
    total = sum(area.values()) or 1
    for cls in sorted(area, key=lambda c: -area[c]): print(f'{count[cls]:7d} cells {100 * area[cls] / total:5.1f}% area  {cls}')


if __name__ == '__main__':
    main()
