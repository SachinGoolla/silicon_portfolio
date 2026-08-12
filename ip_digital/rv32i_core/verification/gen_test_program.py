#!/usr/bin/env python3
"""Two-pass RV32I encoder for rv32i_core's standalone test program.

Not scripts/rv32i_asm.py (that's Step 3 of the roadmap, a real
general-purpose assembler) -- this is a small, purpose-built encoder for
exactly the instructions this IP's own testbench needs, with a label pass
so branch/jump offsets are computed, not hand-derived. Hand-deriving a
B-type/J-type immediate already produced one real bug earlier in this same
build (rv32i_imm_gen.sv's SW oracle, caught via a similar cross-check
script) -- this generator exists specifically to not repeat that mistake
at CPU-program scale, where there are far more offsets to get right.

Run: python3 gen_test_program.py
Prints a SystemVerilog `unique case` ROM body to stdout.
"""

PROGRAM = []          # list of (mnemonic, operands, label_or_None)
LABELS = {}           # label -> word index

def emit(mnemonic, *operands, label=None):
    if label is not None:
        LABELS[label] = len(PROGRAM)
    PROGRAM.append((mnemonic, operands))


def u(val, bits):
    return val & ((1 << bits) - 1)


def r_type(funct7, rs2, rs1, funct3, rd, opcode):
    return (funct7 << 25) | (rs2 << 20) | (rs1 << 15) | (funct3 << 12) | (rd << 7) | opcode

def i_type(imm, rs1, funct3, rd, opcode):
    return (u(imm, 12) << 20) | (rs1 << 15) | (funct3 << 12) | (rd << 7) | opcode

def s_type(imm, rs2, rs1, funct3, opcode):
    imm = u(imm, 12)
    return ((imm >> 5) << 25) | (rs2 << 20) | (rs1 << 15) | (funct3 << 12) | ((imm & 0x1F) << 7) | opcode

def b_type(imm, rs2, rs1, funct3, opcode):
    # imm is a byte offset, bit0 always 0 (not encoded).
    imm = u(imm, 13)
    bit12   = (imm >> 12) & 1
    bit11   = (imm >> 11) & 1
    bits10_5 = (imm >> 5) & 0x3F
    bits4_1  = (imm >> 1) & 0xF
    return (bit12 << 31) | (bits10_5 << 25) | (rs2 << 20) | (rs1 << 15) | (funct3 << 12) | \
           (bits4_1 << 8) | (bit11 << 7) | opcode

def u_type(imm20, rd, opcode):
    return (u(imm20, 20) << 12) | (rd << 7) | opcode

def j_type(imm, rd, opcode):
    imm = u(imm, 21)
    bit20    = (imm >> 20) & 1
    bits10_1 = (imm >> 1) & 0x3FF
    bit11    = (imm >> 11) & 1
    bits19_12 = (imm >> 12) & 0xFF
    return (bit20 << 31) | (bits10_1 << 21) | (bit11 << 20) | (bits19_12 << 12) | (rd << 7) | opcode


OP = {
    'RTYPE': 0b0110011, 'ITYPE': 0b0010011, 'LOAD': 0b0000011, 'STORE': 0b0100011,
    'BRANCH': 0b1100011, 'JAL': 0b1101111, 'JALR': 0b1100111,
    'LUI': 0b0110111, 'AUIPC': 0b0010111,
}

def encode(mnemonic, ops, pc, labels):
    if mnemonic in ('ADD', 'SUB', 'AND', 'OR', 'XOR', 'SLL', 'SRL', 'SRA', 'SLT', 'SLTU'):
        rd, rs1, rs2 = ops
        f7f3 = {
            'ADD': (0, 0), 'SUB': (0x20, 0), 'SLL': (0, 1), 'SLT': (0, 2), 'SLTU': (0, 3),
            'XOR': (0, 4), 'SRL': (0, 5), 'SRA': (0x20, 5), 'OR': (0, 6), 'AND': (0, 7),
        }[mnemonic]
        return r_type(f7f3[0], rs2, rs1, f7f3[1], rd, OP['RTYPE'])
    if mnemonic in ('ADDI', 'ANDI', 'ORI', 'XORI', 'SLTI', 'SLTIU'):
        rd, rs1, imm = ops
        f3 = {'ADDI': 0, 'SLTI': 2, 'SLTIU': 3, 'XORI': 4, 'ORI': 6, 'ANDI': 7}[mnemonic]
        return i_type(imm, rs1, f3, rd, OP['ITYPE'])
    if mnemonic in ('SLLI', 'SRLI', 'SRAI'):
        rd, rs1, shamt = ops
        f7 = {'SLLI': 0, 'SRLI': 0, 'SRAI': 0x20}[mnemonic]
        f3 = {'SLLI': 1, 'SRLI': 5, 'SRAI': 5}[mnemonic]
        return i_type((f7 << 5) | shamt, rs1, f3, rd, OP['ITYPE'])
    if mnemonic in ('LW', 'LH', 'LHU', 'LB', 'LBU'):
        rd, imm, rs1 = ops
        f3 = {'LB': 0, 'LH': 1, 'LW': 2, 'LBU': 4, 'LHU': 5}[mnemonic]
        return i_type(imm, rs1, f3, rd, OP['LOAD'])
    if mnemonic in ('SW', 'SH', 'SB'):
        rs2, imm, rs1 = ops
        f3 = {'SB': 0, 'SH': 1, 'SW': 2}[mnemonic]
        return s_type(imm, rs2, rs1, f3, OP['STORE'])
    if mnemonic in ('BEQ', 'BNE', 'BLT', 'BGE', 'BLTU', 'BGEU'):
        rs1, rs2, target = ops
        f3 = {'BEQ': 0, 'BNE': 1, 'BLT': 4, 'BGE': 5, 'BLTU': 6, 'BGEU': 7}[mnemonic]
        offset = (labels[target] - pc // 4) * 4
        return b_type(offset, rs2, rs1, f3, OP['BRANCH'])
    if mnemonic == 'JAL':
        rd, target = ops
        offset = (labels[target] - pc // 4) * 4
        return j_type(offset, rd, OP['JAL'])
    if mnemonic == 'JALR':
        rd, rs1, imm = ops
        return i_type(imm, rs1, 0, rd, OP['JALR'])
    if mnemonic == 'LUI':
        rd, imm20 = ops
        return u_type(imm20, rd, OP['LUI'])
    if mnemonic == 'AUIPC':
        rd, imm20 = ops
        return u_type(imm20, rd, OP['AUIPC'])
    if mnemonic == 'NOP':
        return 0x00000013
    raise ValueError(f"unknown mnemonic {mnemonic}")


def build_program():
    global PROGRAM, LABELS
    PROGRAM, LABELS = [], {}

    emit('ADDI', 1, 0, 0)                 # x1 = 0   (memory base pointer)
    emit('ADDI', 2, 0, 5)                 # x2 = 5
    emit('ADDI', 3, 0, 7)                 # x3 = 7
    emit('ADD',  4, 2, 3)                 # x4 = 12
    emit('SUB',  5, 4, 2)                 # x5 = 7
    emit('AND',  6, 2, 3)                 # x6 = 5
    emit('OR',   7, 2, 3)                 # x7 = 7
    emit('XOR',  8, 2, 3)                 # x8 = 2
    emit('SLLI', 9, 2, 1)                 # x9 = 10
    emit('SRLI', 10, 4, 2)                # x10 = 3
    emit('ADDI', 11, 0, -8)               # x11 = -8
    emit('SRAI', 12, 11, 1)               # x12 = -4 (arithmetic)
    emit('SLT',  13, 2, 3)                # x13 = 1  (5 < 7)
    emit('SLTU', 14, 3, 2)                # x14 = 0  (7 < 5 unsigned false)
    emit('SLTI', 15, 2, 10)               # x15 = 1  (5 < 10)
    emit('ANDI', 16, 3, 3)                # x16 = 3  (7 & 3)
    emit('ORI',  17, 2, 8)                # x17 = 13 (5 | 8)
    emit('XORI', 18, 3, 1)                # x18 = 6  (7 ^ 1)
    emit('LUI',  19, 0x12345)             # x19 = 0x12345000
    emit('AUIPC', 20, 0)                  # x20 = pc of this instruction (0x04c)

    # Stores (word/half/byte -- exercise WSTRB positioning) into the AXI
    # BFM's memory at word offsets 0/4/8/12 from x1.
    emit('SW', 4, 0, 1)                   # mem[0]  = x4  = 12
    emit('SW', 9, 4, 1)                   # mem[4]  = x9  = 10
    emit('SH', 6, 8, 1)                   # mem[8]  = x6  = 5   (halfword)
    emit('SB', 8, 12, 1)                  # mem[12] = x8  = 2   (byte)
    emit('SW', 19, 32, 1)                 # mem[32] = x19 = 0x12345000 (verifies LUI, not just exercised)
    emit('SW', 20, 36, 1)                 # mem[36] = x20 = AUIPC's own pc (verifies AUIPC, not just exercised)

    # Load-use hazard: LW immediately followed by a dependent use. The
    # very next instruction needs x21 before the LSU's AXI transaction can
    # possibly have completed -- rv32i_hazard_unit must stall one cycle
    # AND the LSU's own busy_o race fix (this checkpoint's real bug) must
    # hold the pipeline frozen for the whole multi-cycle AXI transaction,
    # not just the first cycle.
    emit('LW',  21, 0, 1)                 # x21 = mem[0] = 12
    emit('ADD', 22, 21, 21)               # x22 = 24 (load-use dependent)
    emit('SW',  22, 16, 1)                # mem[16] = 24

    # Branches -- each skips one "poison" instruction (ADDI to a sentinel
    # register that later stores get checked NEVER see) if taken. Every
    # one of these is a real BMC-adjacent bit-scrambling risk if hand-
    # encoded; the label pass below removes that risk entirely.
    emit('BEQ', 2, 2, 'skip_beq')         # 5==5, always taken
    emit('ADDI', 23, 0, 0x7FF)            # poison (skipped)
    emit('NOP', label='skip_beq')
    emit('BNE', 2, 3, 'skip_bne')         # 5!=7, taken
    emit('ADDI', 23, 0, 0x7FE)            # poison (skipped)
    emit('NOP', label='skip_bne')
    emit('BLT', 2, 3, 'skip_blt')         # 5<7, taken
    emit('ADDI', 23, 0, 0x7FD)            # poison (skipped)
    emit('NOP', label='skip_blt')
    emit('BGE', 3, 2, 'skip_bge')         # 7>=5, taken
    emit('ADDI', 23, 0, 0x7FC)            # poison (skipped)
    emit('NOP', label='skip_bge')
    emit('BLTU', 2, 3, 'skip_bltu')       # 5<7 unsigned, taken
    emit('ADDI', 23, 0, 0x7FB)            # poison (skipped)
    emit('NOP', label='skip_bltu')
    emit('BGEU', 3, 2, 'skip_bgeu')       # 7>=5 unsigned, taken
    emit('ADDI', 23, 0, 0x7FA)            # poison (skipped)
    emit('NOP', label='skip_bgeu')
    emit('ADDI', 23, 0, 99)               # x23 = 99 (proves no poison landed)
    emit('SW', 23, 20, 1)                 # mem[20] = 99

    # JAL -- lands past a poison store, x25 gets the return address.
    emit('JAL', 25, 'after_jal')
    emit('SW', 0, 24, 1)                  # poison (skipped): mem[24] = 0
    emit('NOP', label='after_jal')
    emit('SW', 25, 24, 1)                 # mem[24] = return addr (proves JAL landed + link correct)

    # JALR -- compute an absolute target via AUIPC+ADDI into x26, jump
    # through it, land past a poison store.
    emit('AUIPC', 26, 0)                  # x26 = pc of this instruction
    emit('ADDI', 26, 26, ('jalr_target_offset',))  # placeholder, fixed below
    emit('JALR', 27, 26, 0)
    emit('SW', 0, 28, 1)                  # poison (skipped): mem[28] = 0
    emit('NOP', label='jalr_target')
    emit('SW', 27, 28, 1)                 # mem[28] = return addr (proves JALR landed + link correct)

    # Done sentinel -- testbench polls this address for a nonzero write.
    emit('ADDI', 31, 0, 1)
    emit('SW', 31, 100, 1)                # mem[100] = 1  (DONE)

    # Tail NOPs so the pipeline drains the last real instruction cleanly.
    for _ in range(4):
        emit('NOP')


def resolve_jalr_offset():
    # AUIPC x26,0 is immediately followed by the ADDI placeholder; the
    # JALR target is 'jalr_target', 3 words after the AUIPC (AUIPC, ADDI,
    # JALR all before it -- resolved by index arithmetic once labels are
    # known, same two-pass discipline as everything else here).
    auipc_idx = next(i for i, (m, ops) in enumerate(PROGRAM) if m == 'AUIPC' and ops[0] == 26)
    target_idx = LABELS['jalr_target']
    offset = (target_idx - auipc_idx) * 4
    m, ops = PROGRAM[auipc_idx + 1]
    assert m == 'ADDI' and ops[0] == 26
    PROGRAM[auipc_idx + 1] = ('ADDI', (26, 26, offset))


def get_words():
    """Returns the encoded program as a list of 32-bit ints. Importable by
    test_rv32i_core.py (cocotb) so the instruction stream is defined in
    exactly one place, not duplicated between the SV ROM and the Python
    testbench's imem model."""
    build_program()
    resolve_jalr_offset()
    words = []
    for idx, (mnemonic, ops) in enumerate(PROGRAM):
        pc = idx * 4
        words.append(encode(mnemonic, ops, pc, LABELS))
    return words


def main():
    words = get_words()

    print("// Auto-generated by gen_test_program.py -- do not hand-edit.")
    print("unique case (addr_i[%d:2])" % ((len(words) - 1).bit_length() + 1))
    for idx, w in enumerate(words):
        print(f"    {idx:0d}: rdata_o = 32'h{w:08X};")
    print("    default: rdata_o = 32'h00000013;  // NOP past the program end")
    print("endcase")
    print()
    print(f"// program length: {len(words)} words ({len(words)*4} bytes)")
    print(f"// labels: {LABELS}")


if __name__ == '__main__':
    main()
