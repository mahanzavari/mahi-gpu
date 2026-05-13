import sys
import re

# Opcode Mapping (decoder.sv)
OPCODES = {
    'NOP': 0,
    'BR': 1,
    'CMP': 2,
    'ADD': 3,
    'SUB': 4,
    'MUL': 5, 
    'DIV': 6, 
    'LDR': 7, 
    'STR': 8, 
    'CONST': 9,
    'SYNC': 10, 
    'LDSH': 11, 
    'STSH': 12, 
    'CALL': 13, 
    'RET': 14,
    'EXIT': 15, 
    'ATOM_ADD': 16, 
    'AND': 17, 
    'OR': 18, 
    'XOR': 19,
    'SHL': 20, 
    'SHR': 21, 
    'MOD': 22, 
    'MIN': 23, 
    'MAX': 24,
    'ABS': 25, 
    'NEG': 26, 
    'MAC': 27, 
    'ATOM_CAS': 28
}

def parse_reg(reg_str):
    """Converts 'r5' to integer 5"""
    return int(reg_str.replace('r', '').strip())

def parse_imm(imm_str, labels):
    """Parses integers or label addresses"""
    if imm_str in labels:
        return labels[imm_str]
    # Handle hex (0x) or base 10
    return int(imm_str, 0) & 0xFFFF

def assemble(input_file, output_file):
    with open(input_file, 'r') as f:
        lines = f.readlines()

    # Clean up lines: remove comments and empty lines
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
        # Replace commas with spaces, then split by whitespace
        parts = re.split(r'[\s,]+', line)
        mnem = parts[0].upper()
        
        # Default binary fields
        opcode = OPCODES.get(mnem, 0)
        rd = 0
        rs = 0
        rt = 0
        imm = 0
        nzp = 0
        
        try:
            # 1. R-Type (e.g. ADD rd, rs, rt)
            if mnem in ['ADD','SUB','MUL','DIV','AND','OR','XOR','SHL','SHR','MOD','MIN','MAX','MAC']:
                rd = parse_reg(parts[1])
                rs = parse_reg(parts[2])
                rt = parse_reg(parts[3])
                
            # 2. Memory LDR/LDSH (e.g. LDR rd, rs, offset)
            elif mnem in ['LDR', 'LDSH', 'ATOM_ADD']:
                rd = parse_reg(parts[1])
                rs = parse_reg(parts[2])
                imm = parse_imm(parts[3], labels)
                
            # 3. Memory STR/STSH (e.g. STR rt, rs, offset)
            elif mnem in ['STR', 'STSH']:
                # FIX: Hardware decoder maps 'rt' to [25:21] (which is the 'rd' slot in python)
                rd = parse_reg(parts[1]) 
                rs = parse_reg(parts[2])
                imm = parse_imm(parts[3], labels)
                
            # 4. Immediate (e.g. CONST rd, imm)
            elif mnem == 'CONST':
                rd = parse_reg(parts[1])
                imm = parse_imm(parts[2], labels)
                
            # 5. Branch (e.g. BR nzp, target)
            elif mnem == 'BR':
                # e.g., BR 7, loop_start (7 = 111 in binary = Any NZP condition)
                nzp = int(parts[1]) & 0x7
                imm = parse_imm(parts[2], labels)
                rd = nzp # In decoder, nzp uses the rd bits [25:23]
                rd = rd << 2 # shift to align with [25:23]
                
            # 6. Compare (e.g. CMP rs, rt)
            elif mnem == 'CMP':
                rs = parse_reg(parts[1])
                rt = parse_reg(parts[2])
                
            # 7. No args (EXIT, SYNC, RET)
            elif mnem in ['EXIT', 'SYNC', 'RET', 'NOP']:
                pass
                
        except Exception as e:
            print(f"Error assembling line {pc}: '{line}' -> {e}")
            sys.exit(1)

        # Build 32-bit instruction
        # Format: Opcode[31:26] | rd[25:21] | rs[20:16] | rt[15:11] | imm[15:0]
        inst_32 = (opcode << 26) | (rd << 21) | (rs << 16) | (rt << 11) | (imm & 0xFFFF)
        
        # Format as 8-character hex string (e.g. "0C400000")
        machine_code.append(f"{inst_32:08X}")

    # Write to output file
    with open(output_file, 'w') as f:
        for hex_str in machine_code:
            f.write(hex_str + '\n')
            
    print(f"Successfully assembled {len(machine_code)} instructions to {output_file}")

if __name__ == "__main__":
    if len(sys.argv) != 3:
        print("Usage: python assembler.py input.asm output.hex")
    else:
        assemble(sys.argv[1], sys.argv[2])