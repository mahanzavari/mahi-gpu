#!/usr/bin/env python3
"""Timing and electrical-violation maps of a routed run, from an OpenSTA dump (scripts/sta_dump.tcl).

  timing_map.py --sta-dir DIR --def RUN/final/def/gpu_asic_top.def --lef <std-cell.lef> <macro.lef> \
                [--netlist RUN/06-yosys-synthesis/gpu_asic_top.nl.v] --out-slack slack.png --out-viol violators.png

slack.png      worst setup slack per 50 um bin (where on the die timing is tight), the worst paths drawn through the
               cells they pass, and a histogram of every endpoint's slack.
violators.png  every max-slew / max-capacitance / max-fanout violator at the pin's cell, by type, with counts per
               block (block labels inferred as in die_map.py when --netlist is given) and per cause.
"""
import argparse, collections, os, re, sys
import numpy as np
from PIL import Image, ImageDraw

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import die_map as dm

RAMP = ['#0d366b', '#184f95', '#256abf', '#3987e5', '#6da7ec', '#9ec5f4', '#cde2fb', '#eef4fc']  # tight -> relaxed
CRIT = (208, 59, 59)                                                                              # negative slack
TYPES = {'max slew': (42, 120, 214), 'max capacitance': (235, 104, 52), 'max fanout': (27, 175, 122)}
INK, MUTED, SURFACE, EMPTY = (26, 26, 25), (110, 110, 105), (252, 252, 250), (244, 244, 240)


def hex2rgb(h):
    return tuple(int(h[i:i + 2], 16) for i in (1, 3, 5))


def ramp(t):
    t = min(max(t, 0.0), 1.0) * (len(RAMP) - 1); i = min(int(t), len(RAMP) - 2); f = t - i
    a, b = hex2rgb(RAMP[i]), hex2rgb(RAMP[i + 1])
    return tuple(round(a[k] + (b[k] - a[k]) * f) for k in range(3))


def norm(n):
    return n.lstrip('\\').replace('\\', '').strip()


def inst_of(pin):
    return norm(pin.rsplit('/', 1)[0]) if '/' in pin else None


def parse_paths(path):
    """[(slack, start, end, [instance, ...] along the data path)]"""
    out = []
    for blk in open(path).read().split('Startpoint: ')[1:]:
        start = blk.split()[0]; end = re.search(r'Endpoint: (\S+)', blk).group(1)
        sl = re.search(r'(-?[\d.]+)\s+slack', blk)
        if not sl: continue
        data = blk.split('data arrival time')[0]
        seq = []
        for m in re.finditer(r'\s([^\s()]+/[^\s()]+) \((\w+)\)', data):
            i = inst_of(m.group(1))
            if i and (not seq or seq[-1] != i): seq.append(i)
        s0 = norm(start)                                       # drop the launch clock network before the startpoint
        if s0 in seq: seq = seq[seq.index(s0):]
        out.append((float(sl.group(1)), norm(start), norm(end), seq))
    return out


def parse_endpoints(path):
    eps = []
    for l in open(path):
        p = l.split()
        if len(p) >= 4 and '/' in p[0] and p[-1] in ('(MET)', '(VIOLATED)'):
            eps.append((inst_of(p[0]), float(p[-2])))
    return eps


def parse_violators(path):
    """[(type, pin, limit, value, slack)]"""
    out, typ = [], None
    for l in open(path):
        h = re.match(r'\s*(max slew|max capacitance|max fanout)', l)
        if h: typ = h.group(1); continue
        p = l.split()
        if typ and len(p) >= 4 and p[-1] in ('(VIOLATED)', '(MET)'):          # pins, and top-level ports
            v = [float(x) for x in p[1:-1]]                              # slack column is blank for -1 fanout
            out.append((typ, p[0], v[0], v[1], v[2] if len(v) > 2 else v[0] - v[1]))
    return out


def canvas(die, units, title, f, legend_w=520, px=1500):
    dw, dh = (die[2] - die[0]) / units, (die[3] - die[1]) / units
    s = px / dw; H = int(dh * s); m, tp = 24, 64
    img = Image.new('RGB', (px + 2 * m + legend_w, max(H, 900) + tp + 2 * m), SURFACE)
    d = ImageDraw.Draw(img, 'RGBA')
    X = lambda x: m + x * s; Y = lambda y: tp + H - y * s
    d.rectangle([X(0), Y(dh), X(dw), Y(0)], outline=MUTED, fill=EMPTY)
    d.text((m, 18), title, fill=INK, font=f)
    return img, d, X, Y, s, px + 2 * m, tp


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--sta-dir', required=True); ap.add_argument('--def', dest='deff', required=True)
    ap.add_argument('--lef', nargs='+', required=True); ap.add_argument('--netlist')
    ap.add_argument('--out-slack', required=True); ap.add_argument('--out-viol', required=True)
    ap.add_argument('--paths', type=int, default=100, help='worst paths to draw'); ap.add_argument('--title', default='')
    ap.add_argument('--period', type=float, default=40.0)
    ap.add_argument('--final-netlist', help='final (routed) netlist: group violator pins by net and name the driver')
    a = ap.parse_args()

    sizes = dm.lef_sizes(a.lef); die, units, comps = dm.parse_def(a.deff)
    pos, macros, ctype = {}, [], {}
    for name, ty, x, y, o in comps:
        w, h = sizes.get(ty, (0, 0))
        if o in ('E', 'W', 'FE', 'FW'): w, h = h, w
        k = norm(name); pos[k] = (x / units + w / 2, y / units + h / 2); ctype[k] = ty
        if 'sram' in ty: macros.append((k, x / units, y / units, w, h))
    txt = open(a.deff).read(); sec = txt[txt.index('\nPINS'):txt.index('END PINS')]
    for st in sec.split(';')[1:]:
        mm = re.search(r'-\s+(\S+).*?(?:PLACED|FIXED)\s+\(\s*(-?\d+)\s+(-?\d+)', st, re.S)
        if mm: pos[norm(mm.group(1))] = (int(mm.group(2)) / units, int(mm.group(3)) / units)
    lab = {}
    if a.netlist:
        inst = dm.parse_netlist(a.netlist); l, _ = dm.infer_labels(inst); lab = {norm(k): v for k, v in l.items()}
    f, f_m, f_s = dm.fonts()
    dw, dh = (die[2] - die[0]) / units, (die[3] - die[1]) / units

    def draw_macros(d, X, Y):
        for k, x, y, w, h in macros:
            d.rectangle([X(x), Y(y + h), X(x + w), Y(y)], fill=(60, 60, 66, 255), outline=INK)
            d.text((X(x) + 6, Y(y + h) + 4), dm.macro_label(k), fill=SURFACE, font=f_s)

    # ================= slack map
    eps = [(i, s) for i, s in parse_endpoints(os.path.join(a.sta_dir, 'endpoints_max.rpt')) if i in pos]
    paths = parse_paths(os.path.join(a.sta_dir, 'paths_max.rpt'))
    B = 50; nx, ny = int(dw // B) + 1, int(dh // B) + 1
    worst = np.full((ny, nx), np.inf)
    for i, s in eps:
        x, y = pos[i]; worst[int(y // B), int(x // B)] = min(worst[int(y // B), int(x // B)], s)
    span = a.period / 2
    img, d, X, Y, sc, lx, tp = canvas(die, units, (a.title + ': ' if a.title else '') + 'setup slack (worst per 50 um bin)', f)
    for j in range(ny):
        for i in range(nx):
            v = worst[j, i]
            if np.isfinite(v):
                d.rectangle([X(i * B), Y((j + 1) * B), X((i + 1) * B) - 1, Y(j * B) - 1], fill=CRIT if v < 0 else ramp(v / span))
    draw_macros(d, X, Y)
    shown = sorted(paths)[:a.paths]
    for sl, st, en, seq in reversed(shown):
        pts = [(X(pos[c][0]), Y(pos[c][1])) for c in seq if c in pos]
        if len(pts) > 1: d.line(pts, fill=(250, 180, 30, 200) if sl >= 0 else CRIT + (230,), width=2)
        if pts: d.ellipse([pts[-1][0] - 4, pts[-1][1] - 4, pts[-1][0] + 4, pts[-1][1] + 4], fill=INK)
    ly = tp
    d.text((lx, ly), 'Worst endpoint slack in the bin', fill=INK, font=f_s); ly += 24
    for k in range(260): d.line([lx + k, ly, lx + k, ly + 16], fill=ramp(k / 259))
    d.text((lx, ly + 20), '0 ns (tight)', fill=MUTED, font=f_s); d.text((lx + 260, ly + 20), f'{span:.0f}+ ns', fill=MUTED, font=f_s, anchor='ra')
    ly += 46; d.rectangle([lx, ly, lx + 24, ly + 14], fill=CRIT); d.text((lx + 32, ly - 1), 'negative slack (failing)', fill=INK, font=f_s)
    ly += 22; d.line([lx, ly + 7, lx + 24, ly + 7], fill=(250, 180, 30), width=3)
    d.text((lx + 32, ly - 1), f'{len(shown)} worst paths, through their cells', fill=INK, font=f_s)
    ly += 22; d.ellipse([lx + 8, ly + 3, lx + 16, ly + 11], fill=INK); d.text((lx + 32, ly - 1), 'path endpoint', fill=INK, font=f_s)
    ly += 36
    sl_all = np.array([s for _, s in eps])
    d.text((lx, ly), f'All {len(sl_all)} endpoints: slack histogram (1 ns bins)', fill=INK, font=f_s); ly += 22
    hb = np.arange(np.floor(min(sl_all.min(), 0)), np.ceil(sl_all.max()) + 1, 1.0)
    cnt, _ = np.histogram(sl_all, hb); cm = cnt.max() or 1; bw = 460 / len(cnt); hh = 150
    for k, c in enumerate(cnt):
        h = hh * c / cm; x0 = lx + k * bw
        d.rectangle([x0, ly + hh - h, x0 + max(bw - 2, 1), ly + hh], fill=CRIT if hb[k] < 0 else ramp(hb[k] / span))
    d.line([lx, ly + hh, lx + 460, ly + hh], fill=MUTED)
    d.text((lx, ly + hh + 4), f'{hb[0]:.0f} ns', fill=MUTED, font=f_s); d.text((lx + 460, ly + hh + 4), f'{hb[-1]:.0f} ns', fill=MUTED, font=f_s, anchor='ra')
    d.text((lx + 230, ly + hh + 4), f'tallest bar {cm}', fill=MUTED, font=f_s, anchor='ma')
    ly += hh + 36
    d.text((lx, ly), 'Worst paths (start -> end, slack)', fill=INK, font=f_s); ly += 20
    for sl, st, en, seq in sorted(paths)[:12]:
        sh = lambda b: b.replace('Host memory glue (Wishbone window)', 'Host glue').replace(' / control', '').replace('Memory controllers', 'Mem ctrl')
        bs, be = lab.get(st, dm.macro_label(st) if 'macro' in st else st[:18]), lab.get(en, en[:18])
        d.text((lx, ly), f'{sl:6.2f} ns', fill=INK, font=f_s); d.text((lx + 76, ly), f'{sh(bs)} -> {sh(be)}'[:44], fill=MUTED, font=f_s); ly += 18
    img.save(a.out_slack)

    # ================= violators map
    vio = parse_violators(os.path.join(a.sta_dir, 'violators.rpt'))
    pin_net, net_drv = {}, {}
    if a.final_netlist:                                          # pin -> net, net -> driving (cell, type)
        OUTP = ('X', 'Y', 'Q', 'Q_N', 'HI', 'LO', 'GCLK')
        for ty, name, body in re.findall(r'^\s*(sky130_\w+)\s+(\S+)\s*\((.*?)\);', open(a.final_netlist).read(), re.S | re.M):
            if '__fill' in ty or '__tap' in ty or '__decap' in ty: continue
            for pn, net in re.findall(r'\.(\w+)\(([^)]*)\)', body):
                bits = [(pn, net)]
                if net.strip().startswith('{'):                  # macro bus: concatenation, MSB first
                    parts = [x.strip() for x in net.strip()[1:-1].split(',')]
                    bits = [(f'{pn}[{len(parts) - 1 - i}]', x) for i, x in enumerate(parts)]
                for pb, nb in bits:
                    nn = norm(nb); pin_net[norm(name) + '/' + pb] = nn
                    if pn in OUTP or pn.startswith('dout'): net_drv[nn] = (norm(name), ty)
    img, d, X, Y, sc, lx, tp = canvas(die, units, (a.title + ': ' if a.title else '') + 'max slew / cap / fanout violators', f)
    draw_macros(d, X, Y)
    by_type, by_blk, cause = collections.Counter(), collections.defaultdict(collections.Counter), collections.Counter()
    nets_of = collections.defaultdict(lambda: collections.defaultdict(list))   # type -> net -> [pins]
    for typ, pin, lim, val, sl in vio:
        i = inst_of(pin) or norm(pin)
        by_type[typ] += 1
        nets_of[typ][pin_net.get(norm(pin), norm(pin))].append(pin)
        ty = ctype.get(i, 'port')
        c = ('SRAM macro pin' if 'sram' in ty else 'top-level port' if ty == 'port' else
             'clock tree' if 'clk' in ty else 'buffer (repair-inserted)' if (i not in lab and ('buf' in ty or 'inv' in ty)) else 'logic cell')
        cause[(typ, c)] += 1
        by_blk[lab.get(i, c if c != 'logic cell' else 'unlabelled')][typ] += 1
        if i in pos:
            x, y = pos[i]; col = TYPES[typ]
            d.ellipse([X(x) - 3, Y(y) - 3, X(x) + 3, Y(y) + 3], fill=col + (170,))
    ly = tp
    for t, col in TYPES.items():
        d.ellipse([lx + 6, ly + 3, lx + 16, ly + 13], fill=col)
        d.text((lx + 28, ly - 1), f'{t}: {by_type[t]} pins' + (f' on {len(nets_of[t])} nets' if pin_net else ''), fill=INK, font=f_s); ly += 22
    drv_kind = collections.Counter(); worst_nets = []
    if pin_net:
        for t in TYPES:
            for net, ps in nets_of[t].items():
                dn, dty = net_drv.get(net, (None, 'port'))
                k = ('SRAM macro' if 'sram' in dty else 'top-level port' if dty == 'port' else 'clock tree' if 'clk' in dty
                     else 'repair buffer' if (dn not in lab and ('buf' in dty or 'inv' in dty)) else 'logic cell')
                drv_kind[(t, k)] += 1
                worst_nets.append((len(ps), t, net, dty.replace('sky130_fd_sc_hd__', '').replace('sky130_sram_2kbyte_1rw1r_32x512_8', 'SRAM'), lab.get(dn, k)))
                if dn in pos:
                    x, y = pos[dn]; d.rectangle([X(x) - 5, Y(y) - 5, X(x) + 5, Y(y) + 5], outline=INK, width=2)
        ly += 4; d.rectangle([lx + 5, ly + 2, lx + 17, ly + 14], outline=INK, width=2); d.text((lx + 28, ly - 1), 'driver of a violating net', fill=INK, font=f_s); ly += 22
    if pin_net:
        ly += 10; d.text((lx, ly), 'Violating nets by driver', fill=INK, font=f_s); ly += 20
        for (t, c), v in sorted(drv_kind.items(), key=lambda kv: -kv[1])[:9]:
            d.text((lx, ly), f'{v:6d}', fill=INK, font=f_s); d.text((lx + 62, ly), f'{t.replace("max ", "")} - {c}', fill=MUTED, font=f_s); ly += 18
        ly += 10; d.text((lx, ly), 'Nets with the most violating pins', fill=INK, font=f_s); ly += 20
        for n_, t, net, dty, b in sorted(worst_nets, reverse=True)[:8]:
            d.text((lx, ly), f'{n_:4d}', fill=INK, font=f_s); d.text((lx + 44, ly), f'{t.replace("max ", "")}  {dty}  {b}'[:52], fill=MUTED, font=f_s); ly += 18
    ly += 14; d.text((lx, ly), 'Violating pins by kind of cell', fill=INK, font=f_s); ly += 20
    for (t, c), v in sorted(cause.items(), key=lambda kv: -kv[1])[:8]:
        d.text((lx, ly), f'{v:6d}', fill=INK, font=f_s); d.text((lx + 62, ly), f'{t.replace("max ", "")} - {c}', fill=MUTED, font=f_s); ly += 18
    ly += 14; d.text((lx, ly), 'Violating pins by block (slew / cap / fanout)', fill=INK, font=f_s); ly += 20
    for b, c in sorted(by_blk.items(), key=lambda kv: -sum(kv[1].values()))[:12]:
        d.text((lx, ly), f'{c["max slew"]:5d} {c["max capacitance"]:5d} {c["max fanout"]:4d}', fill=INK, font=f_s)
        d.text((lx + 150, ly), b.replace(' (Wishbone window)', '')[:36], fill=MUTED, font=f_s); ly += 18
    img.save(a.out_viol)
    print(f'endpoints {len(eps)}, worst {sl_all.min():.3f} ns, under 2 ns: {(sl_all < 2).sum()}; paths drawn {len(shown)}; '
          f'violators {dict(by_type)}')
    for (t, c), v in sorted(drv_kind.items(), key=lambda kv: -kv[1])[:10]: print(f'  {v:6d} nets  {t} - driver {c}')
    for n_, t, net, dty, b in sorted(worst_nets, reverse=True)[:12]: print(f'  {n_:4d} pins  {t:16s} {dty:18s} {b:28s} {net}')


if __name__ == '__main__':
    main()
