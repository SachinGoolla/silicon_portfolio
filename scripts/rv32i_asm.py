#!/usr/bin/env python3
"""rv32i_asm.py — a real, general-purpose RV32I assembler.

Step 3 of the RISC-V SoC roadmap. No RV32I cross-compiler toolchain is
installed on this host; rather than `apt-get`-installing one (a system
change, and against this repo's own-tooling narrative), this assembles a
real `.s` text source directly. `ip_digital/rv32i_core/verification/
gen_test_program.py` (Step 2's own test-program generator) is NOT this --
that script emits one hardcoded program via direct Python calls, no text
parsing, no pseudo-instructions, no CLI. This is the general tool Step 4
(`rv32i_soc`) needs to assemble a real program as its own P3/P4 test
vector, and that any later program for this core should go through.

The six bit-field encoders below (`r_type`/`i_type`/`s_type`/`b_type`/
`u_type`/`j_type`) are reused verbatim from `gen_test_program.py` --
not reinvented, and not blindly trusted either: that script's encoder
assembled rv32i_core's own standalone test program, which then executed
correctly on formally-checkpointed RTL under two independent simulators
(Icarus via tb_rv32i_core.sv, cocotb via test_rv32i_core.py, each with an
independently-computed golden-value table). Actual correct execution on
verified hardware is the strongest validation available short of a real
RV32I toolchain cross-check -- reusing that exact logic here is not
"copy-paste minus scrutiny," it inherits that validation directly.

Supports the full RV32I base ISA, common pseudo-instructions (relaxed at
assemble time, not via multi-pass size estimation -- `li`'s 1-vs-2-
instruction expansion depends only on its own literal immediate, known
immediately at parse time; every other pseudo-op has a fixed expansion
size regardless of its label target, so there is no forward-reference
sizing ambiguity to resolve), and a `.word` directive for embedding raw
data. Two-pass: pass 1 expands pseudo-instructions into real ones and
resolves label addresses; pass 2 encodes using the complete label table
-- the same discipline `gen_test_program.py` already established, now
driven by text instead of direct calls.
"""
import argparse
import re
import sys


class AssemblerError(Exception):
    def __init__(self, message, line_no=None, line_text=None):
        self.message = message
        self.line_no = line_no
        self.line_text = line_text
        loc = f"line {line_no}: " if line_no else ""
        src = f" ({line_text.strip()!r})" if line_text else ""
        super().__init__(f"{loc}{message}{src}")


# ---------------------------------------------------------------------------
# Registers -- both x<N> and ABI names, matching every real RISC-V assembler.
# ---------------------------------------------------------------------------
ABI_NAMES = {
    'zero': 0, 'ra': 1, 'sp': 2, 'gp': 3, 'tp': 4,
    't0': 5, 't1': 6, 't2': 7,
    's0': 8, 'fp': 8, 's1': 9,
    'a0': 10, 'a1': 11, 'a2': 12, 'a3': 13, 'a4': 14, 'a5': 15, 'a6': 16, 'a7': 17,
    's2': 18, 's3': 19, 's4': 20, 's5': 21, 's6': 22, 's7': 23,
    's8': 24, 's9': 25, 's10': 26, 's11': 27,
    't3': 28, 't4': 29, 't5': 30, 't6': 31,
}


def reg(tok, line_no=None, line_text=None):
    t = tok.strip().lower()
    if t in ABI_NAMES:
        return ABI_NAMES[t]
    m = re.fullmatch(r'x(\d+)', t)
    if m:
        n = int(m.group(1))
        if 0 <= n <= 31:
            return n
    raise AssemblerError(f"unknown register '{tok}'", line_no, line_text)


def is_register_token(tok):
    """True if tok syntactically names a register (x0-x31 or an ABI name)
    -- used to disambiguate jalr's two valid operand orderings (see
    encode_instr's jalr branch) without raising on a non-register token."""
    t = tok.strip().lower()
    if t in ABI_NAMES:
        return True
    m = re.fullmatch(r'x(\d+)', t)
    return bool(m and 0 <= int(m.group(1)) <= 31)


# ---------------------------------------------------------------------------
# Bit-field encoders -- RV32I formats, spec section 2.2/2.3. Reused verbatim
# from gen_test_program.py (see module docstring for why that's legitimate
# reuse, not blind copying).
# ---------------------------------------------------------------------------
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
    imm = u(imm, 13)
    bit12 = (imm >> 12) & 1
    bit11 = (imm >> 11) & 1
    bits10_5 = (imm >> 5) & 0x3F
    bits4_1 = (imm >> 1) & 0xF
    return (bit12 << 31) | (bits10_5 << 25) | (rs2 << 20) | (rs1 << 15) | (funct3 << 12) | \
           (bits4_1 << 8) | (bit11 << 7) | opcode


def u_type(imm20, rd, opcode):
    return (u(imm20, 20) << 12) | (rd << 7) | opcode


def j_type(imm, rd, opcode):
    imm = u(imm, 21)
    bit20 = (imm >> 20) & 1
    bits10_1 = (imm >> 1) & 0x3FF
    bit11 = (imm >> 11) & 1
    bits19_12 = (imm >> 12) & 0xFF
    return (bit20 << 31) | (bits10_1 << 21) | (bit11 << 20) | (bits19_12 << 12) | (rd << 7) | opcode


OP = {
    'RTYPE': 0b0110011, 'ITYPE': 0b0010011, 'LOAD': 0b0000011, 'STORE': 0b0100011,
    'BRANCH': 0b1100011, 'JAL': 0b1101111, 'JALR': 0b1100111,
    'LUI': 0b0110111, 'AUIPC': 0b0010111, 'SYSTEM': 0b1110011, 'FENCE': 0b0001111,
}

R_TYPE_OPS = {
    'add': (0x00, 0), 'sub': (0x20, 0), 'sll': (0x00, 1), 'slt': (0x00, 2), 'sltu': (0x00, 3),
    'xor': (0x00, 4), 'srl': (0x00, 5), 'sra': (0x20, 5), 'or': (0x00, 6), 'and': (0x00, 7),
}
I_TYPE_ALU_OPS = {'addi': 0, 'slti': 2, 'sltiu': 3, 'xori': 4, 'ori': 6, 'andi': 7}
I_TYPE_SHIFT_OPS = {'slli': (0x00, 1), 'srli': (0x00, 5), 'srai': (0x20, 5)}
LOAD_OPS = {'lb': 0, 'lh': 1, 'lw': 2, 'lbu': 4, 'lhu': 5}
STORE_OPS = {'sb': 0, 'sh': 1, 'sw': 2}
BRANCH_OPS = {'beq': 0, 'bne': 1, 'blt': 4, 'bge': 5, 'bltu': 6, 'bgeu': 7}

# funct3==0 branches (BEQ/BNE) compare zero_o directly; the rest compare
# alu_result[0] (SLT/SLTU) -- matches rv32i_ctrl_decode.sv's own encoding
# exactly, not a coincidence: both this assembler and that RTL implement
# the same ISA-defined funct3 assignment independently.
IMM_RANGES = {
    'i12': (-2048, 2047), 's12': (-2048, 2047), 'b13': (-4096, 4094),
    'shamt5': (0, 31), 'u20': (0, 0xFFFFF), 'j21': (-1048576, 1048574),
}


def check_range(name, val, line_no, line_text):
    lo, hi = IMM_RANGES[name]
    if not (lo <= val <= hi):
        raise AssemblerError(
            f"immediate {val} out of range for {name} (must be {lo}..{hi})", line_no, line_text)


def expect_operands(ops, valid_counts, mnemonic, line_no, line_text):
    """Raises AssemblerError with a clear message if len(ops) isn't one of
    valid_counts (an int or a container of ints). Every real-instruction
    and pseudo-instruction operand list is unpacked via bare tuple
    assignment (`rd, rs1, rs2 = ops`) -- Python raises a raw, uncaught
    ValueError on a count mismatch there, bypassing this module's own
    documented 'always AssemblerError with a line number' contract
    entirely (confirmed as a real, systemic bug across every single
    unpacking site by an adversarial multi-agent verification pass, not
    just one). Call this before every such unpacking, real or pseudo."""
    if isinstance(valid_counts, int):
        valid_counts = (valid_counts,)
    if len(ops) not in valid_counts:
        expected = " or ".join(str(n) for n in sorted(valid_counts))
        raise AssemblerError(
            f"'{mnemonic}' expects {expected} operand(s), got {len(ops)}", line_no, line_text)


def split_hi_lo(offset):
    """Splits a 32-bit signed pc-relative offset into (hi20, lo12) such
    that (hi20 << 12) + sext12(lo12) == offset -- the standard %hi/%lo
    relocation split every RISC-V assembler uses for AUIPC+ADDI/JALR
    pairs. lo12 is rounded toward the nearest multiple of 0x1000 (adding
    0x800 before the shift) so lo12 always lands in ADDI/JALR's signed
    12-bit range."""
    hi20 = (offset + 0x800) >> 12
    lo12 = offset - (hi20 << 12)
    return hi20, lo12


# ---------------------------------------------------------------------------
# Parsing
# ---------------------------------------------------------------------------
INT_LITERAL_RE = r'[+-]?(?:0[xX][0-9a-fA-F]+|0[bB][01]+|\d+)'
# Offset is optional -- 'lw x1, (x2)' is a valid real-assembler idiom for
# offset 0, identical to 'lw x1, 0(x2)'. Whitespace around the register
# name and a leading '+' on the offset are tolerated (cosmetic, not
# semantic) -- an earlier version of this regex rejected all three,
# taking down assemble() with a raw ValueError from the resulting
# operand-count mismatch instead of either accepting them or raising a
# clear diagnostic (found by adversarial verification).
MEM_OPERAND_RE = re.compile(r'^(' + INT_LITERAL_RE + r')?\s*\(\s*([a-zA-Z][a-zA-Z0-9]*)\s*\)$')
LABEL_DEF_RE = re.compile(r'^([a-zA-Z_.][a-zA-Z0-9_.]*):(.*)$')


def strip_comment(line):
    for marker in ('#', '//'):
        idx = line.find(marker)
        if idx != -1:
            line = line[:idx]
    return line.strip()


def split_operands(text):
    text = text.strip()
    if not text:
        return []
    parts = [p.strip() for p in text.split(',')]
    # offset(reg) is one syntactic operand but two semantic fields --
    # expand it into two operands (offset, reg) for loads/stores. An
    # omitted offset ('(x2)') defaults to 0, matching real assemblers.
    if parts and MEM_OPERAND_RE.match(parts[-1]):
        mo = MEM_OPERAND_RE.match(parts.pop())
        parts.append(mo.group(1) if mo.group(1) else '0')
        parts.append(mo.group(2))
    return parts


def parse_int(text, line_no, line_text):
    try:
        return int(text.strip(), 0)  # handles 0x/0b/decimal/negative
    except ValueError:
        raise AssemblerError(f"not a valid integer: '{text}'", line_no, line_text)


class Instr:
    """One real (non-pseudo) instruction awaiting pass-2 encoding."""
    __slots__ = ('mnemonic', 'operands', 'line_no', 'line_text', 'word_idx')

    def __init__(self, mnemonic, operands, line_no, line_text, word_idx):
        self.mnemonic = mnemonic
        self.operands = operands
        self.line_no = line_no
        self.line_text = line_text
        self.word_idx = word_idx


class Word:
    """One raw 32-bit data word from a .word directive."""
    __slots__ = ('value', 'label', 'line_no', 'line_text', 'word_idx')

    def __init__(self, value, label, line_no, line_text, word_idx):
        self.value = value
        self.label = label
        self.line_no = line_no
        self.line_text = line_text
        self.word_idx = word_idx


# ---------------------------------------------------------------------------
# Pseudo-instruction expansion -- each returns a list of (mnemonic, operand
# text-list) tuples in real-instruction form. Fixed expansion count per
# pseudo-op (except `li`, sized from its own literal immediate, never a
# label) -- see module docstring for why that avoids relaxation entirely.
# ---------------------------------------------------------------------------
def expand_pseudo(mnemonic, ops, line_no, line_text):
    m = mnemonic.lower()

    # Every branch below used to unpack `ops` via bare tuple assignment
    # (`rd, rs = ops`) with no prior length check -- a wrong operand
    # count on ANY of these raised a raw, uncaught Python ValueError
    # instead of this module's own documented AssemblerError-with-line-
    # number contract (found systemically by adversarial verification,
    # not as one isolated case). expect_operands() below is called before
    # every unpacking now, real-instruction and pseudo-instruction sites
    # alike (see encode_instr for the real-instruction side of this fix).

    if m == 'nop':
        expect_operands(ops, 0, m, line_no, line_text)
        return [('addi', ['x0', 'x0', '0'])]
    if m == 'mv':
        expect_operands(ops, 2, m, line_no, line_text)
        rd, rs = ops
        return [('addi', [rd, rs, '0'])]
    if m == 'not':
        expect_operands(ops, 2, m, line_no, line_text)
        rd, rs = ops
        return [('xori', [rd, rs, '-1'])]
    if m == 'neg':
        expect_operands(ops, 2, m, line_no, line_text)
        rd, rs = ops
        return [('sub', [rd, 'x0', rs])]
    if m == 'seqz':
        expect_operands(ops, 2, m, line_no, line_text)
        rd, rs = ops
        return [('sltiu', [rd, rs, '1'])]
    if m == 'snez':
        expect_operands(ops, 2, m, line_no, line_text)
        rd, rs = ops
        return [('sltu', [rd, 'x0', rs])]
    if m == 'sltz':
        expect_operands(ops, 2, m, line_no, line_text)
        rd, rs = ops
        return [('slt', [rd, rs, 'x0'])]
    if m == 'sgtz':
        expect_operands(ops, 2, m, line_no, line_text)
        rd, rs = ops
        return [('slt', [rd, 'x0', rs])]
    if m in ('beqz', 'bnez', 'blez', 'bgez', 'bltz', 'bgtz'):
        expect_operands(ops, 2, m, line_no, line_text)
        rs, target = ops
        real = {'beqz': ('beq', rs, 'x0'), 'bnez': ('bne', rs, 'x0'),
                'blez': ('bge', 'x0', rs), 'bgez': ('bge', rs, 'x0'),
                'bltz': ('blt', rs, 'x0'), 'bgtz': ('blt', 'x0', rs)}[m]
        return [(real[0], [real[1], real[2], target])]
    if m == 'j':
        expect_operands(ops, 1, m, line_no, line_text)
        (target,) = ops
        return [('jal', ['x0', target])]
    if m == 'jal' and len(ops) == 1:
        (target,) = ops
        return [('jal', ['x1', target])]
    if m == 'jr':
        expect_operands(ops, 1, m, line_no, line_text)
        (rs,) = ops
        return [('jalr', ['x0', rs, '0'])]
    if m == 'jalr' and len(ops) == 1:
        (rs,) = ops
        return [('jalr', ['x1', rs, '0'])]
    if m == 'ret':
        expect_operands(ops, 0, m, line_no, line_text)
        return [('jalr', ['x0', 'x1', '0'])]
    if m == 'call':
        expect_operands(ops, 1, m, line_no, line_text)
        (target,) = ops
        return [('__auipc_pcrel', ['x1', target]), ('__jalr_pcrel', ['x1', 'x1', target])]
    if m == 'la':
        expect_operands(ops, 2, m, line_no, line_text)
        rd, target = ops
        return [('__auipc_pcrel', [rd, target]), ('__addi_pcrel', [rd, rd, target])]
    if m == 'li':
        expect_operands(ops, 2, m, line_no, line_text)
        rd, imm_text = ops
        imm = parse_int(imm_text, line_no, line_text)
        if -2048 <= imm <= 2047:
            return [('addi', [rd, 'x0', str(imm)])]
        if not (-(1 << 31) <= imm <= (1 << 32) - 1):
            raise AssemblerError(f"li immediate {imm} doesn't fit in 32 bits", line_no, line_text)
        hi20, lo12 = split_hi_lo(u(imm, 32))
        return [('lui', [rd, str(u(hi20, 20))]), ('addi', [rd, rd, str(lo12)])]

    return None  # not a pseudo-instruction


# `__auipc_pcrel`/`__jalr_pcrel`/`__addi_pcrel` are internal markers for
# call/la's AUIPC+lo12 pair -- the lo12 half needs the SAME pc-relative
# offset the AUIPC half computed (relative to the AUIPC's own address, not
# its own), so pass 2 resolves both halves of the pair together rather
# than treating the second real-looking mnemonic (`addi`/`jalr`) as an
# ordinary one with the label as a literal immediate (which it is not --
# the operand is a label, not a pre-split lo12 value, until pass 2 knows
# the AUIPC's own address).


# ---------------------------------------------------------------------------
# Pass 1: parse source into a flat list of Instr/Word items, expanding
# pseudo-instructions and resolving label -> word-index.
# ---------------------------------------------------------------------------
def assemble_pass1(source_text):
    items = []
    labels = {}

    for line_no, raw_line in enumerate(source_text.splitlines(), start=1):
        line = strip_comment(raw_line)
        if not line:
            continue

        m = LABEL_DEF_RE.match(line)
        while m:
            label_name = m.group(1)
            if label_name in labels:
                # A bare dict assignment here used to silently overwrite
                # the earlier definition -- any reference already resolved
                # against it (a backward branch closing a loop, for
                # instance) would then resolve against the LAST
                # definition instead, silently rewiring e.g. a decrement
                # loop's back-edge into a forward jump past the loop body,
                # with zero diagnostic (found by adversarial verification:
                # a duplicate `loop:` after a real loop retargeted its own
                # `bne ..., loop` from a -8 backward offset to a +8
                # forward one). A duplicate label is inherently an
                # authoring ambiguity -- there is no silently-correct
                # resolution, so raise rather than guess which one was
                # meant.
                raise AssemblerError(f"duplicate label '{label_name}'", line_no, raw_line)
            labels[label_name] = len(items)
            line = m.group(2).strip()
            if not line:
                break
            m = LABEL_DEF_RE.match(line)
        if not line:
            continue

        parts = line.split(None, 1)
        mnemonic = parts[0]
        rest = parts[1] if len(parts) > 1 else ''

        if mnemonic == '.word':
            ops = split_operands(rest)
            if len(ops) != 1:
                raise AssemblerError(".word takes exactly one operand", line_no, raw_line)
            tok = ops[0]
            # Reuses INT_LITERAL_RE (the same literal-recognition pattern
            # MEM_OPERAND_RE and parse_int/int(x,0) already use elsewhere
            # in this file) so '.word' accepts every integer syntax the
            # rest of the tool does -- an earlier version had its own,
            # narrower regex here that omitted the 0b binary-literal form,
            # so '.word 0b1010' was misdiagnosed as an undefined label
            # instead of parsed as the literal 10 (found by adversarial
            # verification).
            if re.fullmatch(INT_LITERAL_RE, tok):
                items.append(Word(parse_int(tok, line_no, raw_line), None, line_no, raw_line, len(items)))
            else:
                items.append(Word(None, tok, line_no, raw_line, len(items)))  # label, resolved pass 2
            continue

        if mnemonic.lower() in ('ecall', 'ebreak', 'fence'):
            ops = split_operands(rest)
            expect_operands(ops, 0, mnemonic.lower(), line_no, raw_line)
            items.append(Instr(mnemonic.lower(), [], line_no, raw_line, len(items)))
            continue

        ops = split_operands(rest)
        expanded = expand_pseudo(mnemonic, ops, line_no, raw_line)
        if expanded is None:
            items.append(Instr(mnemonic.lower(), ops, line_no, raw_line, len(items)))
        else:
            for real_mnemonic, real_ops in expanded:
                items.append(Instr(real_mnemonic, real_ops, line_no, raw_line, len(items)))

    return items, labels


# ---------------------------------------------------------------------------
# Pass 2: encode each item using the completed label table.
# ---------------------------------------------------------------------------
def encode_instr(instr, labels):
    m, ops, line_no, line_text, idx = instr.mnemonic, instr.operands, instr.line_no, instr.line_text, instr.word_idx
    pc = idx * 4

    def R(tok):
        return reg(tok, line_no, line_text)

    def I(tok):
        return parse_int(tok, line_no, line_text)

    def target_offset(label_tok):
        if label_tok not in labels:
            raise AssemblerError(f"undefined label '{label_tok}'", line_no, line_text)
        return (labels[label_tok] * 4) - pc

    # Every ops-unpacking site below is preceded by expect_operands() --
    # without it, a wrong operand count raised a raw, uncaught Python
    # ValueError instead of this module's own documented AssemblerError-
    # with-line-number contract (found systemically across every one of
    # these sites by adversarial verification, not as one isolated case;
    # see expand_pseudo's matching fix for the pseudo-instruction side).

    if m in R_TYPE_OPS:
        expect_operands(ops, 3, m, line_no, line_text)
        rd, rs1, rs2 = ops
        funct7, funct3 = R_TYPE_OPS[m]
        return r_type(funct7, R(rs2), R(rs1), funct3, R(rd), OP['RTYPE'])

    if m in I_TYPE_ALU_OPS:
        expect_operands(ops, 3, m, line_no, line_text)
        rd, rs1, imm_tok = ops
        imm = I(imm_tok)
        check_range('i12', imm, line_no, line_text)
        return i_type(imm, R(rs1), I_TYPE_ALU_OPS[m], R(rd), OP['ITYPE'])

    if m in I_TYPE_SHIFT_OPS:
        expect_operands(ops, 3, m, line_no, line_text)
        rd, rs1, shamt_tok = ops
        shamt = I(shamt_tok)
        check_range('shamt5', shamt, line_no, line_text)
        funct7, funct3 = I_TYPE_SHIFT_OPS[m]
        return i_type((funct7 << 5) | shamt, R(rs1), funct3, R(rd), OP['ITYPE'])

    if m in LOAD_OPS:
        expect_operands(ops, 3, m, line_no, line_text)
        rd, imm_tok, rs1 = ops
        imm = I(imm_tok)
        check_range('i12', imm, line_no, line_text)
        return i_type(imm, R(rs1), LOAD_OPS[m], R(rd), OP['LOAD'])

    if m in STORE_OPS:
        expect_operands(ops, 3, m, line_no, line_text)
        rs2, imm_tok, rs1 = ops
        imm = I(imm_tok)
        check_range('s12', imm, line_no, line_text)
        return s_type(imm, R(rs2), R(rs1), STORE_OPS[m], OP['STORE'])

    if m in BRANCH_OPS:
        expect_operands(ops, 3, m, line_no, line_text)
        rs1, rs2, target = ops
        offset = target_offset(target)
        check_range('b13', offset, line_no, line_text)
        if offset % 2 != 0:
            raise AssemblerError(f"branch offset {offset} is not 2-byte aligned", line_no, line_text)
        return b_type(offset, R(rs2), R(rs1), BRANCH_OPS[m], OP['BRANCH'])

    if m == 'jal':
        expect_operands(ops, 2, m, line_no, line_text)
        rd, target = ops
        offset = target_offset(target)
        check_range('j21', offset, line_no, line_text)
        if offset % 2 != 0:
            raise AssemblerError(f"jal offset {offset} is not 2-byte aligned", line_no, line_text)
        return j_type(offset, R(rd), OP['JAL'])

    if m == 'jalr':
        expect_operands(ops, 3, m, line_no, line_text)
        # Two valid real-assembler syntaxes reach here with the SAME
        # 3-element ops length but a DIFFERENT field order, and
        # split_operands() has already erased which one was written:
        #   'jalr rd, rs1, imm'   -> ops = [rd, rs1, imm]   (reg, reg, int)
        #   'jalr rd, imm(rs1)'   -> ops = [rd, imm, rs1]   (reg, int, reg)
        # (the second form is GNU-as-standard syntax, and this file's own
        # split_operands() already expands imm(rs1) into two operands for
        # every OTHER instruction that takes it -- loads/stores rely on
        # exactly that expansion -- so jalr structurally invites the same
        # syntax without previously accepting it.) Disambiguate by
        # checking whether ops[1] is itself a register token: found by
        # adversarial verification that treating it as always (reg, reg,
        # int) silently misparsed the offset(rs1) form with a confusing
        # "not a valid integer: 'x2'" error instead of encoding it or
        # rejecting it clearly.
        rd, second, third = ops
        if is_register_token(second):
            rs1, imm_tok = second, third
        else:
            imm_tok, rs1 = second, third
        imm = I(imm_tok)
        check_range('i12', imm, line_no, line_text)
        return i_type(imm, R(rs1), 0, R(rd), OP['JALR'])

    if m == 'lui':
        expect_operands(ops, 2, m, line_no, line_text)
        rd, imm_tok = ops
        imm20 = I(imm_tok)
        check_range('u20', imm20, line_no, line_text)
        return u_type(imm20, R(rd), OP['LUI'])

    if m == 'auipc':
        expect_operands(ops, 2, m, line_no, line_text)
        rd, imm_tok = ops
        imm20 = I(imm_tok)
        check_range('u20', imm20, line_no, line_text)
        return u_type(imm20, R(rd), OP['AUIPC'])

    if m == '__auipc_pcrel':
        rd, target = ops
        offset = target_offset(target)
        hi20, _ = split_hi_lo(offset)
        return u_type(u(hi20, 20), R(rd), OP['AUIPC'])

    if m in ('__jalr_pcrel', '__addi_pcrel'):
        # The lo12 half of a call/la pair must split the SAME offset the
        # preceding AUIPC computed -- relative to the AUIPC's own address
        # (always idx-1: call/la always expand to exactly this instruction
        # immediately after their own AUIPC half), not this instruction's
        # own pc. Splitting relative to the wrong base silently produces a
        # target off by exactly the AUIPC-to-this-instruction distance --
        # a real bug caught here via a smoke-test cross-check against an
        # independent decoder, before it ever reached formal verification.
        rd, rs1, target = ops
        auipc_pc = (idx - 1) * 4
        offset = labels.get(target)
        if offset is None:
            raise AssemblerError(f"undefined label '{target}'", line_no, line_text)
        offset = (offset * 4) - auipc_pc
        _, lo12 = split_hi_lo(offset)
        opcode = OP['JALR'] if m == '__jalr_pcrel' else OP['ITYPE']
        return i_type(lo12, R(rs1), 0, R(rd), opcode)

    if m == 'ecall':
        return 0x00000073
    if m == 'ebreak':
        return 0x00100073
    if m == 'fence':
        return 0x0FF0000F  # full I/O+memory barrier (pred=succ=iorw), GNU-as default

    raise AssemblerError(f"unknown instruction '{m}'", line_no, line_text)


def assemble(source_text):
    """Assembles RV32I source text into a list of 32-bit instruction/data
    words. Raises AssemblerError with the offending line number on any
    parse/encode failure -- never silently truncates or guesses."""
    items, labels = assemble_pass1(source_text)
    words = []
    for item in items:
        if isinstance(item, Word):
            if item.value is not None:
                words.append(u(item.value, 32))
            else:
                if item.label not in labels:
                    raise AssemblerError(f"undefined label '{item.label}'", item.line_no, item.line_text)
                words.append(u(labels[item.label] * 4, 32))
        else:
            words.append(u(encode_instr(item, labels), 32))
    return words


# ---------------------------------------------------------------------------
# Output formats
# ---------------------------------------------------------------------------
def format_words(words):
    return '\n'.join(f'0x{w:08X}' for w in words) + '\n'


def format_rom(words, module_name):
    idx_bits = max(1, (len(words) - 1).bit_length()) + 1
    idx_width = idx_bits - 1  # addr_i[idx_bits:2] is (idx_bits-2+1) = idx_width bits wide
    lines = [
        f"// Auto-generated by scripts/rv32i_asm.py -- do not hand-edit.",
        f"`timescale 1ns/1ps",
        "",
        f"module {module_name} (",
        f"    input  logic [31:0] addr_i,",
        f"    output logic [31:0] rdata_o",
        f");",
        "",
        f"    /* verilator lint_off UNUSEDSIGNAL */",
        f"    logic _unused_addr;",
        f"    assign _unused_addr = ^addr_i;  // only addr_i[{idx_bits}:2] indexes the ROM below",
        f"    /* verilator lint_on UNUSEDSIGNAL */",
        "",
        f"    // Icarus rejects a part-select used directly as a case expression",
        f"    // (\"constant selects in always_* processes are not currently",
        f"    // supported\") -- an explicit intermediate wire avoids it, same fix",
        f"    // as imem_stub.sv's/rv32i_lsu.sv's rom_idx/addr_byte_sel.",
        f"    wire [{idx_width-1}:0] rom_idx = addr_i[{idx_bits}:2];",
        "",
        f"    always_comb begin",
        f"        unique case (rom_idx)",
    ]
    for idx, w in enumerate(words):
        lines.append(f"            {idx}: rdata_o = 32'h{w:08X};")
    lines.append(f"            default: rdata_o = 32'h00000013;  // NOP past the program end")
    lines.append(f"        endcase")
    lines.append(f"    end")
    lines.append("")
    lines.append(f"endmodule")
    return '\n'.join(lines) + '\n'


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument('source', help='RV32I assembly source file (.s)')
    parser.add_argument('-o', '--output', help='output file (default: stdout)')
    parser.add_argument('--format', choices=('words', 'rom'), default='words',
                         help='words: one hex word per line; rom: SV case-statement ROM module')
    parser.add_argument('--module-name', default='rv32i_program_rom',
                         help='module name for --format rom (default: rv32i_program_rom)')
    args = parser.parse_args(argv)

    with open(args.source) as f:
        source_text = f.read()

    try:
        words = assemble(source_text)
    except AssemblerError as e:
        print(f"rv32i_asm.py: {args.source}: {e}", file=sys.stderr)
        return 1

    out = format_rom(words, args.module_name) if args.format == 'rom' else format_words(words)
    if args.output:
        with open(args.output, 'w') as f:
            f.write(out)
    else:
        print(out, end='')
    return 0


if __name__ == '__main__':
    sys.exit(main())
