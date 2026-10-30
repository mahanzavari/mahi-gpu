"""Give every net of a routed netlist that does not exist in the synthesized netlist a private name.

Usage: hide_new_nets.py SYNTH.v ROUTED.v OUT.v
Yosys treats identifiers starting with '$' as internal, so equivalence matching (eqy) only pairs the nets
both netlists share; buffers, clock-tree nets and repair nets added by the flow become anonymous logic.
"""
import re, sys

WIRE = re.compile(r'^\s*(?:wire|input|output|inout)\s+(?:\[[^\]]*\]\s*)?(\\\S+|[A-Za-z_][\w$]*)', re.M)

def names(text):
    return set(WIRE.findall(text))

def main(synth, routed, out):
    old = names(open(synth).read())
    txt = open(routed).read()
    new = names(txt) - old
    def hid(n):
        return '\\$h_' + (n[1:] if n.startswith('\\') else n) + ' '
    tok = re.compile(r'(\\\S+\s|[A-Za-z_][\w$]*)')
    def sub_conn(m):                                   # only inside .PIN( ... ) and wire declarations
        inner = m.group(2)
        inner = tok.sub(lambda t: hid(t.group(1).strip()) if t.group(1).strip() in new else t.group(1), inner)
        return m.group(1) + inner + m.group(3)
    txt = re.sub(r'(\.\w+\()([^()]*)(\))', sub_conn, txt)
    txt = re.sub(r'^(\s*wire\s+(?:\[[^\]]*\]\s*)?)(\\\S+|[A-Za-z_][\w$]*)(\s*;)',
                 lambda m: m.group(1) + (hid(m.group(2)) if m.group(2) in new else m.group(2)) + m.group(3), txt, flags=re.M)
    open(out, 'w').write(txt)
    print(f'{len(new)} of {len(names(open(routed).read()))} routed-netlist nets hidden')

if __name__ == '__main__':
    main(*sys.argv[1:4])
