#!/usr/bin/env python3
"""Independent disassembler/cross-checker for gen_test_program.py's output.

Deliberately does NOT import anything from gen_test_program.py -- bit
extraction here is written from the RV32I spec directly (string-slicing
the binary representation, not shift/mask arithmetic), so an encoder bug
and a checker bug sharing the same wrong formula is structurally unlikely.
This is the same oracle-cross-check discipline rv32i_imm_gen.sv's own
formal comments describe using, applied at whole-program scale.
"""
import re
import subprocess

OPCODES = {
    '0110011': 'RTYPE', '0010011': 'ITYPE', '0000011': 'LOAD', '0100011': 'STORE',
    '1100011': 'BRANCH', '1101111': 'JAL', '1100111': 'JALR',
    '0110111': 'LUI', '0010111': 'AUIPC',
}

R_F7F3 = {
    (0, 0): 'ADD', (0x20, 0): 'SUB', (0, 1): 'SLL', (0, 2): 'SLT', (0, 3): 'SLTU',
    (0, 4): 'XOR', (0, 5): 'SRL', (0x20, 5): 'SRA', (0, 6): 'OR', (0, 7): 'AND',
}
I_F3 = {0: 'ADDI', 2: 'SLTI', 3: 'SLTIU', 4: 'XORI', 6: 'ORI', 7: 'ANDI'}
LOAD_F3 = {0: 'LB', 1: 'LH', 2: 'LW', 4: 'LBU', 5: 'LHU'}
STORE_F3 = {0: 'SB', 1: 'SH', 2: 'SW'}
BRANCH_F3 = {0: 'BEQ', 1: 'BNE', 4: 'BLT', 5: 'BGE', 6: 'BLTU', 7: 'BGEU'}


def sext(bits_str):
    val = int(bits_str, 2)
    if bits_str[0] == '1':
        val -= (1 << len(bits_str))
    return val


def decode(word, pc):
    b = format(word, '032b')
    opcode_bits = b[25:32]
    opcode = OPCODES.get(opcode_bits, '???')
    rd = int(b[20:25], 2)
    funct3 = int(b[17:20], 2)
    rs1 = int(b[12:17], 2)
    rs2 = int(b[7:12], 2)
    funct7 = int(b[0:7], 2)

    if opcode == 'RTYPE':
        mnem = R_F7F3.get((funct7, funct3), f'R?({funct7},{funct3})')
        return f"{mnem} x{rd}, x{rs1}, x{rs2}"
    if opcode == 'ITYPE':
        imm = sext(b[0:12])
        if funct3 == 1:
            return f"SLLI x{rd}, x{rs1}, {rs2}"
        if funct3 == 5:
            variant = 'SRAI' if funct7 == 0x20 else 'SRLI'
            return f"{variant} x{rd}, x{rs1}, {rs2}"
        mnem = I_F3.get(funct3, f'I?({funct3})')
        return f"{mnem} x{rd}, x{rs1}, {imm}"
    if opcode == 'LOAD':
        imm = sext(b[0:12])
        mnem = LOAD_F3.get(funct3, f'L?({funct3})')
        return f"{mnem} x{rd}, {imm}(x{rs1})"
    if opcode == 'STORE':
        imm = sext(b[0:7] + b[20:25])
        mnem = STORE_F3.get(funct3, f'S?({funct3})')
        return f"{mnem} x{rs2}, {imm}(x{rs1})"
    if opcode == 'BRANCH':
        imm_bits = b[0] + b[24] + b[1:7] + b[20:24] + '0'
        imm = sext(imm_bits)
        mnem = BRANCH_F3.get(funct3, f'B?({funct3})')
        return f"{mnem} x{rs1}, x{rs2}, pc=0x{pc + imm:03x} (offset {imm:+d})"
    if opcode == 'JAL':
        imm_bits = b[0] + b[12:20] + b[11] + b[1:11] + '0'
        imm = sext(imm_bits)
        return f"JAL x{rd}, pc=0x{pc + imm:03x} (offset {imm:+d})"
    if opcode == 'JALR':
        imm = sext(b[0:12])
        return f"JALR x{rd}, x{rs1}, {imm}"
    if opcode == 'LUI':
        imm20 = int(b[0:20], 2)
        return f"LUI x{rd}, 0x{imm20:05x}"
    if opcode == 'AUIPC':
        imm20 = int(b[0:20], 2)
        return f"AUIPC x{rd}, 0x{imm20:05x}"
    return f"??? word=0x{word:08x}"


def main():
    out = subprocess.run(['python3', 'gen_test_program.py'], capture_output=True, text=True, check=True).stdout
    lines = re.findall(r"(\d+): rdata_o = 32'h([0-9A-Fa-f]{8});", out)
    for idx_s, hex_s in lines:
        idx = int(idx_s)
        word = int(hex_s, 16)
        pc = idx * 4
        print(f"{idx:3d} (pc=0x{pc:03x}): 0x{word:08X}  {decode(word, pc)}")


if __name__ == '__main__':
    main()
