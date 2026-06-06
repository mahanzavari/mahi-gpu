import sys
import re

# Opcode Mapping (Aligned with decoder.sv)
OPCODES = {
    'NOP': 0, 'BR': 1, 'CMP': 2, 'ADD': 3, 'SUB': 4,
    'MUL': 5, 'DIV': 6, 'LDR': 7, 'STR': 8, 'CONST': 9,
    'SYNC': 10, 'LDSH': 11, 'STSH': 12, 'CALL': 13, 'RET': 14,
    'EXIT': 15, 'ATOM_ADD': 16, 'AND': 17, 'OR': 18, 'XOR': 19,
    'SHL': 20, 'SHR': 21, 'MOD': 22, 'MIN': 23, 'MAX': 24,
    'ABS': 25, 'NEG': 26, 'MAC': 27, 'ATOM_CAS': 28,
    'LUI': 29, 'POPCNT': 30, 'CLZ': 31, 'BREV': 32,
    'FADD': 33, 'FSUB': 34, 'FMUL': 35, 'FMA': 36
}

def parse_reg(reg_str):
    return int(reg_str.replace('r', '').strip())

def parse_imm(imm_str, labels):
    if imm_str in labels: return labels[imm_str]
    return int(imm_str, 0)

def assemble(input_file, output_file):
    with open(input_file, 'r') as f:
        lines = f.readlines()

    clean_lines = []
    for line in lines:
        line = line.split('//')[0].strip()
        if line: clean_lines.append(line)

    # PASS 1: Find Labels
    labels = {}
    instructions = []
    pc = 0
    for line in clean_lines:
        if line.endswith(':'):
            labels[line[:-1]] = pc
        else:
            instructions.append(line)
            pc += 1

    # PASS 2: Assemble to Machine Code
    machine_code = []
    for pc, line in enumerate(instructions):
        parts = re.split(r'[\s,]+', line)
        mnem = parts[0].upper()
        
        opcode = OPCODES.get(mnem, 0)
        rd = 0; rs = 0; rt = 0; imm = 0; nzp = 0
        is_lui = False
        
        try:
            # R-Type (Now includes FPU commands)
            if mnem in ['ADD','SUB','MUL','DIV','AND','OR','XOR','SHL','SHR',
                        'MOD','MIN','MAX','MAC', 'FADD', 'FSUB', 'FMUL', 'FMA']:
                rd = parse_reg(parts[1])
                rs = parse_reg(parts[2])
                rt = parse_reg(parts[3])
                
            elif mnem in ['POPCNT', 'CLZ', 'BREV']:
                rd = parse_reg(parts[1])
                rs = parse_reg(parts[2])
                
            elif mnem == 'LUI':
                rd = parse_reg(parts[1])
                imm = parse_imm(parts[2], labels) & 0xFFFFF
                is_lui = True
                
            elif mnem in ['LDR', 'LDSH', 'ATOM_ADD', 'STR', 'STSH']:
                rd = parse_reg(parts[1])
                rs = parse_reg(parts[2])
                imm = parse_imm(parts[3], labels)
                
            elif mnem == 'CONST':
                rd = parse_reg(parts[1])
                imm = parse_imm(parts[2], labels)
                
            elif mnem == 'BR':
                nzp = int(parts[1]) & 0x7
                imm = parse_imm(parts[2], labels)
                rd = nzp << 2 
                
            elif mnem == 'CMP':
                rs = parse_reg(parts[1])
                rt = parse_reg(parts[2])
                
            elif mnem in ['EXIT', 'SYNC', 'RET', 'NOP']:
                pass
                
        except Exception as e:
            print(f"Error assembling line {pc}: '{line}' -> {e}")
            sys.exit(1)

        if is_lui:
            inst_32 = (opcode << 26) | (rd << 21) | (imm << 1)
        else:
            inst_32 = (opcode << 26) | (rd << 21) | (rs << 16) | (rt << 11) | (imm & 0xFFFF)
        
        machine_code.append(f"{inst_32:08X}")

    with open(output_file, 'w') as f:
        for hex_str in machine_code:
            f.write(hex_str + '\n')
            
    print(f"Successfully assembled {len(machine_code)} instructions to {output_file}")

if __name__ == "__main__":
    if len(sys.argv) != 3:
        print("Usage: python assembler.py input.asm output.hex")
    else:
        assemble(sys.argv[1], sys.argv[2])