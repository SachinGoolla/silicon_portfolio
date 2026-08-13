"""Regression + oracle tests for scripts/rv32i_asm.py.

Encodings are cross-checked against ip_digital/rv32i_core/verification/
decode_check.py -- an independently-implemented decoder (string-slicing
based, not shift/mask, validated separately by actually executing decoded
programs on formally-verified rv32i_core RTL) -- rather than hand-computed
here a second time, for the same reason gen_test_program.py's own oracle
tests exist: hand-deriving RV32I encodings is exactly the class of mistake
(B-type/J-type bit scrambling) that has already produced one real bug in
this build. Where decode_check.py can't help (immediate-range validation,
pseudo-op expansion correctness, error handling), expected values are
computed independently in each test, not copied from rv32i_asm.py's own
logic.
"""
import shutil
import subprocess
import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parent.parent.parent /
                       "ip_digital" / "rv32i_core" / "verification"))
from decode_check import decode  # noqa: E402

import rv32i_asm
from rv32i_asm import assemble, AssemblerError


def _one(src):
    """Assembles a single-line-equivalent snippet and returns its first word."""
    return assemble(src)[0]


def _decoded(src, idx=0):
    words = assemble(src)
    return decode(words[idx], idx * 4)


# ── R-type / I-type ALU, cross-checked via decode_check.py ──────────────

@pytest.mark.parametrize("mnemonic,expect_substr", [
    ("add", "ADD x3, x1, x2"), ("sub", "SUB x3, x1, x2"), ("sll", "SLL x3, x1, x2"),
    ("slt", "SLT x3, x1, x2"), ("sltu", "SLTU x3, x1, x2"), ("xor", "XOR x3, x1, x2"),
    ("srl", "SRL x3, x1, x2"), ("sra", "SRA x3, x1, x2"), ("or", "OR x3, x1, x2"),
    ("and", "AND x3, x1, x2"),
])
def test_rtype_alu_ops(mnemonic, expect_substr):
    assert _decoded(f"{mnemonic} x3, x1, x2") == expect_substr


def test_abi_register_names_encode_identically_to_x_names():
    assert assemble("add a0, a1, a2") == assemble("add x10, x11, x12")
    assert assemble("addi sp, sp, -16") == assemble("addi x2, x2, -16")
    assert assemble("mv s0, a0") == assemble("mv x8, x10")


def test_negative_immediate_two_complement_encoding():
    # addi x1, x0, -1 -> imm field must be 0xFFF (12-bit two's complement)
    word = _one("addi x1, x0, -1")
    imm12 = (word >> 20) & 0xFFF
    assert imm12 == 0xFFF


@pytest.mark.parametrize("imm", [2047, -2048])
def test_i12_boundary_valid(imm):
    assemble(f"addi x1, x0, {imm}")  # must not raise


@pytest.mark.parametrize("imm", [2048, -2049])
def test_i12_boundary_invalid_raises(imm):
    with pytest.raises(AssemblerError):
        assemble(f"addi x1, x0, {imm}")


@pytest.mark.parametrize("shamt", [0, 31])
def test_shamt_boundary_valid(shamt):
    assemble(f"slli x1, x2, {shamt}")


def test_shamt_32_raises():
    with pytest.raises(AssemblerError):
        assemble("slli x1, x2, 32")


def test_write_to_x0_encodes_literally():
    # The assembler doesn't special-case x0 as a destination -- rd=0 is
    # encoded exactly like any other register number (matching real
    # assemblers; the regfile's own x0-hardwired-zero behavior is a
    # hardware property, not something the assembler should silently
    # rewrite or reject).
    word = _one("addi x0, x1, 5")
    rd = (word >> 7) & 0x1F
    assert rd == 0


# ── Loads / stores, offset(reg) syntax ───────────────────────────────────

@pytest.mark.parametrize("mnemonic,expect_substr", [
    ("lb", "LB x1, 4(x2)"), ("lh", "LH x1, 4(x2)"), ("lw", "LW x1, 4(x2)"),
    ("lbu", "LBU x1, 4(x2)"), ("lhu", "LHU x1, 4(x2)"),
])
def test_load_ops(mnemonic, expect_substr):
    assert _decoded(f"{mnemonic} x1, 4(x2)") == expect_substr


@pytest.mark.parametrize("mnemonic,expect_substr", [
    ("sb", "SB x1, 4(x2)"), ("sh", "SH x1, 4(x2)"), ("sw", "SW x1, 4(x2)"),
])
def test_store_ops(mnemonic, expect_substr):
    assert _decoded(f"{mnemonic} x1, 4(x2)") == expect_substr


def test_negative_offset_load_store():
    assert _decoded("lw x1, -4(x2)") == "LW x1, -4(x2)"
    assert _decoded("sw x1, -4(x2)") == "SW x1, -4(x2)"


def test_store_negative_offset_s_type_split_field():
    # S-type splits the immediate across bits[31:25] and bits[11:7] -- not
    # a contiguous field like I-type. Verify a negative offset survives
    # that split correctly by round-tripping through the independent
    # decoder rather than re-deriving the split by hand here.
    assert _decoded("sw x3, -8(x1)") == "SW x3, -8(x1)"


@pytest.mark.parametrize("imm", [2047, -2048])
def test_load_store_i12_boundary_valid(imm):
    assemble(f"lw x1, {imm}(x2)")
    assemble(f"sw x1, {imm}(x2)")


@pytest.mark.parametrize("imm", [2048, -2049])
def test_load_store_i12_boundary_invalid(imm):
    with pytest.raises(AssemblerError):
        assemble(f"lw x1, {imm}(x2)")
    with pytest.raises(AssemblerError):
        assemble(f"sw x1, {imm}(x2)")


# ── Branches / jumps: label resolution is the highest-risk area ─────────

@pytest.mark.parametrize("mnemonic", ["beq", "bne", "blt", "bge", "bltu", "bgeu"])
def test_branch_forward_reference(mnemonic):
    src = f"{mnemonic} x1, x2, target\nnop\ntarget:\nnop\n"
    words = assemble(src)
    # branch is word 0, target is word 2 -> offset +8
    assert decode(words[0], 0).endswith("(offset +8)")


@pytest.mark.parametrize("mnemonic", ["beq", "bne", "blt", "bge", "bltu", "bgeu"])
def test_branch_backward_reference(mnemonic):
    src = f"loop:\nnop\nnop\n{mnemonic} x1, x2, loop\n"
    words = assemble(src)
    # branch is word 2, loop is word 0 -> offset -8
    assert decode(words[2], 8).endswith("(offset -8)")


def test_jal_forward_and_backward():
    fwd = assemble("jal x1, target\nnop\ntarget:\nnop\n")
    assert decode(fwd[0], 0).endswith("(offset +8)")
    bwd = assemble("loop:\nnop\nnop\njal x1, loop\n")
    assert decode(bwd[2], 8).endswith("(offset -8)")


def test_jalr_immediate_is_literal_not_label():
    word = _one("jalr x1, x2, 100")
    imm12 = (word >> 20) & 0xFFF
    assert imm12 == 100


def test_undefined_label_raises():
    with pytest.raises(AssemblerError):
        assemble("beq x1, x2, nowhere\n")


def test_branch_offset_range_exceeded_raises():
    # B-type offset is a 13-bit signed field (~-4096..+4094). Pad with
    # enough NOPs to genuinely exceed it, not just reason about it.
    padding = "nop\n" * 2049  # 2049*4 = 8196 bytes > 4094 max positive offset
    src = f"beq x1, x2, target\n{padding}target:\nnop\n"
    with pytest.raises(AssemblerError):
        assemble(src)


# ── LUI / AUIPC / la / call / li: pc-relative pairs ──────────────────────

def test_lui_auipc_plain():
    assert _decoded("lui x1, 0x12345") == "LUI x1, 0x12345"
    assert _decoded("auipc x1, 0x12345") == "AUIPC x1, 0x12345"


def test_li_short_form_no_lui():
    words = assemble("li x1, 100")
    assert len(words) == 1  # fits in 12 bits -> single addi, no lui


def test_li_long_form_uses_lui_addi():
    words = assemble("li x1, 0x12345678")
    assert len(words) == 2
    assert decode(words[0], 0) == "LUI x1, 0x12345"


def test_li_boundary_switches_expansion_strategy():
    assert len(assemble("li x1, 2047")) == 1
    assert len(assemble("li x1, 2048")) == 2
    assert len(assemble("li x1, -2048")) == 1
    assert len(assemble("li x1, -2049")) == 2


def test_li_long_form_reconstructs_exact_value():
    for imm in (0x12345678, -1, -100000, 0x7FFFFFFF, -0x80000000, 0xDEADBEEF):
        words = assemble(f"li x1, {imm}")
        if len(words) == 1:
            val = (words[0] >> 20) & 0xFFF
            if val & 0x800:
                val -= 0x1000
            assert val == imm
        else:
            hi20 = (words[0] >> 12) & 0xFFFFF
            lo12 = (words[1] >> 20) & 0xFFF
            if lo12 & 0x800:
                lo12 -= 0x1000
            assert (hi20 << 12) + lo12 == rv32i_asm.u(imm, 32)


def test_la_forward_reference_reconstructs_target_address():
    # Regression test for a real bug: la's second instruction (ADDI) used
    # to split its pc-relative offset using its OWN pc instead of the
    # preceding AUIPC's pc, silently producing a target address off by
    # exactly the distance between the two instructions. Fixed by reusing
    # the AUIPC's own address as the pc-relative base for both halves.
    src = "la x6, data\nnop\nnop\ndata:\n.word 0xCAFEBABE\n"
    words = assemble(src)
    auipc_pc = 0 * 4
    hi20 = (words[0] >> 12) & 0xFFFFF
    lo12 = (words[1] >> 20) & 0xFFF
    if lo12 & 0x800:
        lo12 -= 0x1000
    final_addr = auipc_pc + (hi20 << 12) + lo12
    data_addr = 4 * 4  # la expands to 2 words (0,1), nop=2, nop=3, data:=4
    assert final_addr == data_addr


def test_la_backward_reference_reconstructs_target_address():
    src = "data:\n.word 0xCAFEBABE\nnop\nnop\nla x6, data\n"
    words = assemble(src)
    auipc_idx = 3
    auipc_pc = auipc_idx * 4
    hi20 = (words[auipc_idx] >> 12) & 0xFFFFF
    lo12 = (words[auipc_idx + 1] >> 20) & 0xFFF
    if lo12 & 0x800:
        lo12 -= 0x1000
    final_addr = auipc_pc + (hi20 << 12) + lo12
    assert final_addr == 0


def test_call_reconstructs_target_address_and_uses_ra():
    src = "call func\nnop\nnop\nfunc:\nnop\n"
    words = assemble(src)
    # rd must be x1 (ra) for both halves of call
    assert (words[0] >> 7) & 0x1F == 1
    assert (words[1] >> 7) & 0x1F == 1
    auipc_pc = 0
    hi20 = (words[0] >> 12) & 0xFFFFF
    lo12 = (words[1] >> 20) & 0xFFF
    if lo12 & 0x800:
        lo12 -= 0x1000
    final_addr = auipc_pc + (hi20 << 12) + lo12
    assert final_addr == 4 * 4  # call expands to 2 words (0,1), nop=2, nop=3, func:=4


# ── Other pseudo-instructions ─────────────────────────────────────────────

def test_nop_is_addi_x0_x0_0():
    assert _one("nop") == 0x00000013


def test_mv():
    assert _decoded("mv x3, x1") == "ADDI x3, x1, 0"


def test_not_is_xori_minus_1():
    word = _one("not x3, x1")
    imm12 = (word >> 20) & 0xFFF
    assert imm12 == 0xFFF  # -1 two's complement
    assert decode(word, 0) == "XORI x3, x1, -1"


def test_neg_is_sub_from_x0():
    assert _decoded("neg x3, x1") == "SUB x3, x0, x1"


def test_seqz_is_sltiu_1():
    assert _decoded("seqz x3, x1") == "SLTIU x3, x1, 1"


def test_snez_is_sltu_x0():
    assert _decoded("snez x3, x1") == "SLTU x3, x0, x1"


def test_sltz_is_slt_x0():
    assert _decoded("sltz x3, x1") == "SLT x3, x1, x0"


def test_sgtz_is_slt_x0_reversed():
    assert _decoded("sgtz x3, x1") == "SLT x3, x0, x1"


@pytest.mark.parametrize("pseudo,real_mnemonic,rs1_is_zero", [
    ("beqz", "BEQ", False),
    ("bnez", "BNE", False),
    ("bltz", "BLT", False),
    ("bgtz", "BLT", True),   # bgtz rs,label -> blt x0,rs,label
    ("blez", "BGE", True),   # blez rs,label -> bge x0,rs,label
    ("bgez", "BGE", False),
])
def test_branch_vs_zero_pseudo_ops(pseudo, real_mnemonic, rs1_is_zero):
    words = assemble(f"{pseudo} x5, target\nnop\ntarget:\nnop\n")
    decoded = decode(words[0], 0)
    assert decoded.startswith(real_mnemonic)
    if rs1_is_zero:
        assert f"{real_mnemonic} x0, x5," in decoded
    else:
        assert f"{real_mnemonic} x5, x0," in decoded


def test_j_uses_x0():
    word = _one("j target\ntarget:\nnop\n")
    assert (word >> 7) & 0x1F == 0
    assert decode(word, 0).startswith("JAL x0,")


def test_jal_one_operand_uses_ra():
    word = _one("jal target\ntarget:\nnop\n")
    assert (word >> 7) & 0x1F == 1
    assert decode(word, 0).startswith("JAL x1,")


def test_jr_uses_x0():
    assert _decoded("jr x5") == "JALR x0, x5, 0"


def test_jalr_one_operand_uses_ra():
    assert _decoded("jalr x5") == "JALR x1, x5, 0"


def test_ret_is_jalr_x0_x1_0():
    assert _one("ret") == 0x00008067
    assert _decoded("ret") == "JALR x0, x1, 0"


# ── .word directive ────────────────────────────────────────────────────

def test_word_literal():
    assert assemble(".word 0xCAFEBABE") == [0xCAFEBABE]


def test_word_label_valued():
    words = assemble("data: .word 0xDEAD\nnop\nnop\n.word data\n")
    assert words[3] == 0  # data's own byte address (word index 0 -> byte 0)


# ── Comments, whitespace, label-on-same-line ─────────────────────────────

def test_hash_and_slash_comments_stripped():
    a = assemble("addi x1, x0, 5  # comment\n")
    b = assemble("addi x1, x0, 5  // comment\n")
    c = assemble("addi x1, x0, 5\n")
    assert a == b == c


def test_blank_lines_and_whitespace_ignored():
    assert assemble("\n\n  addi x1, x0, 5  \n\n") == assemble("addi x1, x0, 5")


def test_label_same_line_as_instruction():
    src = "loop: addi x1, x1, 1\nbne x1, x2, loop\n"
    words = assemble(src)
    assert decode(words[1], 4).endswith("(offset -4)")


def test_label_only_line():
    src = "start:\naddi x1, x0, 1\nj start\n"
    words = assemble(src)
    assert decode(words[1], 4).endswith("(offset -4)")


# ── Error handling ─────────────────────────────────────────────────────

def test_unknown_register_raises():
    with pytest.raises(AssemblerError):
        assemble("addi x32, x0, 5")  # only x0-x31 exist
    with pytest.raises(AssemblerError):
        assemble("addi bogus, x0, 5")


def test_unknown_mnemonic_raises():
    with pytest.raises(AssemblerError):
        assemble("frobnicate x1, x2, x3")


def test_error_includes_line_number():
    with pytest.raises(AssemblerError) as exc_info:
        assemble("addi x1, x0, 5\naddi x1, x0, 9999\n")
    assert "line 2" in str(exc_info.value)


# ── ecall / ebreak / fence: fixed encodings ──────────────────────────────

def test_ecall_ebreak_fence_fixed_encodings():
    assert _one("ecall") == 0x00000073
    assert _one("ebreak") == 0x00100073
    assert _one("fence") == 0x0FF0000F


# ── Regression tests for 10 real bugs found by an adversarial multi-agent
#    verification pass (5 independent reviewers, each designing test cases
#    and hand-deriving expected encodings from the RV32I spec directly,
#    followed by 3-way adversarial re-verification of every finding before
#    it was trusted). All 10 confirmed real and fixed the same session. ──

@pytest.mark.parametrize("snippet,mnemonic", [
    ("add x1, x2", "add"),                    # too few R-type operands
    ("add x1, x2, x3, x4", "add"),             # too many R-type operands
    ("addi x1, x2, 4(x3)", "addi"),            # mem-operand on an ALU imm
    ("beq x1, x2", "beq"),                     # missing branch operand
    ("slli x1, x2", "slli"),                   # missing I-type-shift operand
])
def test_wrong_arity_raises_assembler_error_not_valueerror(snippet, mnemonic):
    """Every one of these used to bypass AssemblerError entirely and crash
    with a raw, uncaught Python ValueError from an unchecked tuple unpack
    (`rd, rs1, rs2 = ops`) in encode_instr -- violating this module's own
    documented 'always AssemblerError with a line number' contract."""
    with pytest.raises(AssemblerError) as exc_info:
        assemble(snippet)
    assert mnemonic in str(exc_info.value)
    assert "operand" in str(exc_info.value)


@pytest.mark.parametrize("snippet,mnemonic", [
    ("mv x1", "mv"), ("not x1, x2, x3", "not"), ("beqz x1", "beqz"),
    ("jal target, x1\ntarget:\nnop\n", "jal"),
])
def test_pseudo_op_wrong_arity_raises_assembler_error(snippet, mnemonic):
    with pytest.raises(AssemblerError):
        assemble(snippet)


def test_zero_operand_mnemonics_reject_extra_operands():
    """nop/ret/ecall/ebreak/fence used to silently DISCARD extra/bogus
    operands instead of erroring -- e.g. `ret x5, x6, x7` assembled to a
    plain ret with the operands thrown away and zero diagnostic. In a
    portfolio whose stated purpose is producing real ROM test vectors for
    RTL sign-off, a silently-wrong assembled instruction stream is worse
    than a crash."""
    for snippet in ("nop x1, x2", "ret x5, x6, x7", "ecall x1, x2",
                     "ebreak x1", "fence 1, 2"):
        with pytest.raises(AssemblerError):
            assemble(snippet)


def test_load_store_offset_optional_defaults_to_zero():
    # 'lw x1, (x2)' (offset omitted) is a valid real-assembler idiom,
    # semantically identical to 'lw x1, 0(x2)'.
    assert assemble("lw x1, (x2)") == assemble("lw x1, 0(x2)")
    assert assemble("sw x1, (x2)") == assemble("sw x1, 0(x2)")


def test_load_store_offset_accepts_leading_plus_and_whitespace():
    assert assemble("lw x1, +4(x2)") == assemble("lw x1, 4(x2)")
    assert assemble("lw x1, 4( x2 )") == assemble("lw x1, 4(x2)")
    assert assemble("lw x1,4(x2)") == assemble("lw x1, 4(x2)")


def test_jalr_offset_rs1_syntax():
    """Regression test for a real bug: split_operands() expands
    'offset(reg)' into (offset, reg) order for every instruction with a
    memory-style operand -- exactly what loads/stores need -- but jalr's
    own encode_instr branch used to unpack unconditionally as (rd, rs1,
    imm), the OPPOSITE order, so the standard 'jalr rd, offset(rs1)'
    syntax (valid, common RISC-V assembly, GNU-as accepts it identically
    to 'jalr rd, rs1, offset') silently misparsed with a confusing 'not a
    valid integer: x2' error instead of encoding correctly."""
    assert assemble("jalr x1, 8(x2)") == assemble("jalr x1, x2, 8")
    assert decode(_one("jalr x1, 8(x2)"), 0) == "JALR x1, x2, 8"


def test_duplicate_label_raises():
    """Regression test for a real bug: a duplicate label definition used
    to silently overwrite the earlier one in the labels dict, with no
    error -- any reference already resolved against the first definition
    (a backward branch closing a loop) would then resolve against the
    LAST definition instead, silently rewiring e.g. a decrement loop's
    back-edge from a backward branch into a forward jump past the loop
    body, with zero diagnostic."""
    src = "loop:\naddi x1, x1, -1\nbne x1, x0, loop\nnop\nloop:\nnop\n"
    with pytest.raises(AssemblerError) as exc_info:
        assemble(src)
    assert "duplicate label" in str(exc_info.value)
    assert "loop" in str(exc_info.value)


def test_word_directive_accepts_binary_literal():
    """Regression test for a real bug: .word's literal-vs-label detection
    regex omitted the 0b binary-literal form that parse_int()/li already
    supported elsewhere in this same file (both use Python's int(x, 0)),
    so '.word 0b1010' was misdiagnosed as an undefined label named
    '0b1010' instead of parsed as the literal 10."""
    assert assemble(".word 0b1010") == [10]
    assert assemble(".word 0xA") == assemble(".word 0b1010")


def test_format_rom_compiles_under_iverilog(tmp_path):
    """Regression test for a real bug (found in RISC-V SoC roadmap Step 4,
    the format's first real user): format_rom() emitted 'unique case
    (addr_i[N:2])' -- a part-select used directly as a case expression --
    which Icarus rejects ('sorry: constant selects in always_* processes
    are not currently supported'), a class of bug the 102 encoding-oracle
    tests above can't catch since they only check the returned word list,
    never that the --format rom output actually compiles. The hand-written
    ip_digital/rv32i_core/verification/imem_stub.sv this format is meant
    to replace already worked around it with an intermediate wire (see
    rom_idx there) -- format_rom() now does the same."""
    if shutil.which("iverilog") is None:
        pytest.skip("iverilog not on PATH")
    words = assemble("li x1, 5\nli x2, 10\nadd x3, x1, x2\n")
    sv = rv32i_asm.format_rom(words, "tiny_rom")
    src = tmp_path / "tiny_rom.sv"
    src.write_text(sv)
    result = subprocess.run(
        ["iverilog", "-g2012", "-o", str(tmp_path / "tiny_rom.vvp"), str(src)],
        capture_output=True, text=True, timeout=30,
    )
    assert result.returncode == 0, result.stderr
    assert "constant selects" not in result.stderr


def test_format_rom_lints_clean_under_verilator(tmp_path):
    """Companion to test_format_rom_compiles_under_iverilog: format_rom()'s
    generated module also needs the imem_stub.sv-style _unused_addr catch
    for the non-indexing address bits, or Verilator's -Wall (the exact
    flags scripts/pillars/p1_lint.py runs with -- no -Wno-fatal) turns the
    UNUSEDSIGNAL warning into a fatal lint error."""
    if shutil.which("verilator") is None:
        pytest.skip("verilator not on PATH")
    words = assemble("li x1, 5\nli x2, 10\nadd x3, x1, x2\n")
    sv = rv32i_asm.format_rom(words, "tiny_rom")
    src = tmp_path / "tiny_rom.sv"
    src.write_text(sv)
    result = subprocess.run(
        ["verilator", "--lint-only", "-Wall", str(src)],
        capture_output=True, text=True, timeout=30, cwd=str(tmp_path),
    )
    assert result.returncode == 0, result.stderr
