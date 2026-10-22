import pya, os, re, sys
D = os.environ["RUN"]
DEF = D + "/gpu_asic_top.def"
LEFD = "/home/mahan/.ciel/sky130A/libs.ref/sky130_fd_sc_hd/lef/sky130_fd_sc_hd.lef"
SRAM = os.environ["SRAMLEF"]
# cell sizes from LEFs
sizes = {}
for lef in (LEFD, SRAM):
    name = None
    for l in open(lef):
        m = re.match(r"\s*MACRO (\S+)", l)
        if m: name = m.group(1)
        m = re.match(r"\s*SIZE ([\d.]+) BY ([\d.]+)", l)
        if m and name: sizes[name] = (float(m.group(1)), float(m.group(2))); name = None
ly = pya.Layout(); ly.dbu = 0.001
top = ly.create_cell("top")
L = {k: ly.layer(i, 0) for i, k in enumerate(["die","std","tap","clk","buf","macro","seq"])}
comp = re.compile(r"-\s+(\S+)\s+(\S+)\s+\+\s+(?:\S+\s+)?\(\s*(-?\d+)\s+(-?\d+)\s*\)\s+(\w+)")
inc = False
for l in open(DEF):
    if l.startswith("COMPONENTS"): inc = True; continue
    if l.startswith("END COMPONENTS"): break
    if not inc: continue
    m = comp.search(l)
    if not m: continue
    n, t, x, y, o = m.group(1), m.group(2), int(m.group(3)), int(m.group(4)), m.group(5)
    w, h = sizes[t]; w, h = int(w*1000), int(h*1000)
    if o in ("E","W","FE","FW"): w, h = h, w
    if "sram" in t: k = "macro"
    elif t.startswith("sky130_fd_sc_hd__tap") or n.startswith(("PHY_","TAP_")): k = "tap"
    elif n.startswith(("clkbuf","clkload","delaybuf")) or "clkbuf" in t: k = "clk"
    elif "__df" in t or "__dl" in t or "__sdf" in t: k = "seq"
    elif n.startswith(("hold","fanout","load_slew","wire","max_cap","rebuffer","input","output")): k = "buf"
    else: k = "std"
    top.shapes(L[k]).insert(pya.Box(x, y, x+w, y+h))
top.shapes(L["die"]).insert(pya.Box(0,0,2500000,2500000))
lv = pya.LayoutView(); lv.show_layout(ly, False)
cols = {"die":0x888888,"std":0x3b6fd4,"tap":0x777777,"clk":0xe0a000,"buf":0x2aa84a,"macro":0xd02020,"seq":0x9b30d0}
for k,i in [(k,i) for i,k in enumerate(["die","std","tap","clk","buf","macro","seq"])]:
    p = pya.LayerProperties(); p.source = f"{i}/0@1"; p.name = k
    p.fill_color = p.frame_color = cols[k]
    p.dither_pattern = 0 if k!="die" else 1
    if k=="die": p.fill_color = 0xffffff
    lv.insert_layer(lv.end_layers(), p)
lv.set_config("background-color", "#101418")
lv.max_hier()
lv.zoom_box(pya.DBox(-60, -60, 2560, 2560))
lv.save_image(os.environ["OUT"], 2800, 2800)
print("saved")
