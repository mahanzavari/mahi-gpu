import sys
import re

# Opcode Mapping (decoder.sv)
OPCODES = {
    'NOP': 0, 'BR': 1, 'CMP': 2, 'ADD': 3, 'SUB': 4,
    'MUL': 5, 'DIV': 6, 'LDR': 7, 'STR': 8, 'CONST': 9,
    'SYNC': 10, 'LDSH': 11, 'STSH': 12, 'CALL': 13, 'RET': 14,
    'EXIT': 15, 'ATOM_ADD': 16, 'AND': 17, 'OR': 18, 'XOR': 19,
    'SHL': 20, 'SHR': 21, 'MOD': 22, 'MIN': 23, 'MAX': 24,
    'ABS': 25, 'NEG': 26, 'MAC': 27, 'ATOM_CAS': 28,
    'LUI': 29, 'POPCNT': 30, 'CLZ': 31, 'BREV': 32
}

def parse_reg(reg_str):
    """Converts 'r5' to integer 5"""
    return int(reg_str.replace('r', '').strip())

def parse_imm(imm_str, labels):
    """Parses integers or label addresses"""
    if imm_str in labels:
        return labels[imm_str]
    return int(imm_str, 0)

def assemble(input_file, output_file):
    with open(input_file, 'r') as f:
        lines = f.readlines()

    clean_lines = []
    for line in lines:
        line = line.split('//')[0].strip() # Strip comments
        if line:
            clean_lines.append(line)

    # --- PASS 1: Find Labels ---
    labels = {}
    instructions = []
    pc = 0
    for line in clean_lines:
        if line.endswith(':'):
            label_name = line[:-1]
            labels[label_name] = pc
        else:
            instructions.append(line)
            pc += 1

    # --- PASS 2: Assemble to Machine Code ---
    machine_code = []
    
    for pc, line in enumerate(instructions):
        parts = re.split(r'[\s,]+', line)
        mnem = parts[0].upper()
        
        opcode = OPCODES.get(mnem, 0)
        rd = 0; rs = 0; rt = 0; imm = 0; nzp = 0
        is_lui = False
        
        try:
            # 1. R-Type (e.g. ADD rd, rs, rt)
            if mnem in ['ADD','SUB','MUL','DIV','AND','OR','XOR','SHL','SHR','MOD','MIN','MAX','MAC']:
                rd = parse_reg(parts[1])
                rs = parse_reg(parts[2])
                rt = parse_reg(parts[3])
                
            # 2. Unary R-Type (POPCNT, CLZ, BREV)
            elif mnem in ['POPCNT', 'CLZ', 'BREV']:
                rd = parse_reg(parts[1])
                rs = parse_reg(parts[2])
                
            # 3. LUI (Load Upper Immediate - 20 bits)
            elif mnem == 'LUI':
                rd = parse_reg(parts[1])
                imm = parse_imm(parts[2], labels) & 0xFFFFF
                is_lui = True
                
            # 4. Memory LDR/LDSH/ATOM_ADD (e.g. LDR rd, rs, offset)
            elif mnem in ['LDR', 'LDSH', 'ATOM_ADD']:
                rd = parse_reg(parts[1])
                rs = parse_reg(parts[2])
                imm = parse_imm(parts[3], labels)
                
            # 5. Memory STR/STSH (e.g. STR rt, rs, offset)
            elif mnem in ['STR', 'STSH']:
                rd = parse_reg(parts[1]) 
                rs = parse_reg(parts[2])
                imm = parse_imm(parts[3], labels)
                
            # 6. Immediate (e.g. CONST rd, imm)
            elif mnem == 'CONST':
                rd = parse_reg(parts[1])
                imm = parse_imm(parts[2], labels)
                
            # 7. Branch (e.g. BR nzp, target)
            elif mnem == 'BR':
                nzp = int(parts[1]) & 0x7
                imm = parse_imm(parts[2], labels)
                rd = nzp << 2 
                
            # 8. Compare (e.g. CMP rs, rt)
            elif mnem == 'CMP':
                rs = parse_reg(parts[1])
                rt = parse_reg(parts[2])
                
            # 9. No args (EXIT, SYNC, RET)
            elif mnem in ['EXIT', 'SYNC', 'RET', 'NOP']:
                pass
                
        except Exception as e:
            print(f"Error assembling line {pc}: '{line}' -> {e}")
            sys.exit(1)

        if is_lui:
            # LUI formatting: Opcode[31:26] | rd[25:21] | imm[20:1] | 0[0]
            inst_32 = (opcode << 26) | (rd << 21) | (imm << 1)
        else:
            # Standard formatting: Opcode[31:26] | rd[25:21] | rs[20:16] | rt[15:11] | imm[15:0]
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