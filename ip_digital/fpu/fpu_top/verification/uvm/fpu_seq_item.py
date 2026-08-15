"""FPUSeqItem — transaction object for fpu_top."""
import random
from pyuvm import uvm_sequence_item

# op_i[5:4] unit select
UNIT_FMA     = 0b00
UNIT_DIVSQRT = 0b01
UNIT_CVT     = 0b10
UNIT_NONCOMP = 0b11

# Full 6-bit opcodes
OP_FADD   = (UNIT_FMA     << 4) | 0x0   # 0x00
OP_FSUB   = (UNIT_FMA     << 4) | 0x1   # 0x01
OP_FMUL   = (UNIT_FMA     << 4) | 0x2   # 0x02
OP_FMADD  = (UNIT_FMA     << 4) | 0x3   # 0x03
OP_FMSUB  = (UNIT_FMA     << 4) | 0x4   # 0x04
OP_FNMADD = (UNIT_FMA     << 4) | 0x5   # 0x05
OP_FNMSUB = (UNIT_FMA     << 4) | 0x6   # 0x06
OP_FDIV   = (UNIT_DIVSQRT << 4) | 0x0   # 0x10
OP_FSQRT  = (UNIT_DIVSQRT << 4) | 0x1   # 0x11
OP_FCLASS = (UNIT_NONCOMP << 4) | 0x0   # 0x30
OP_FSGNJ  = (UNIT_NONCOMP << 4) | 0x1   # 0x31
OP_FSGNJN = (UNIT_NONCOMP << 4) | 0x2   # 0x32
OP_FSGNJX = (UNIT_NONCOMP << 4) | 0x3   # 0x33
OP_FEQ    = (UNIT_NONCOMP << 4) | 0x4   # 0x34
OP_FLT    = (UNIT_NONCOMP << 4) | 0x5   # 0x35
OP_FLE    = (UNIT_NONCOMP << 4) | 0x6   # 0x36
OP_FMIN   = (UNIT_NONCOMP << 4) | 0x7   # 0x37
OP_FMAX   = (UNIT_NONCOMP << 4) | 0x8   # 0x38

# Rounding modes (rm_i[2:0])
RM_RNE = 0   # round to nearest, ties to even
RM_RTZ = 1   # round toward zero
RM_RDN = 2   # round toward -infinity
RM_RUP = 3   # round toward +infinity
RM_RMM = 4   # round to nearest, ties away from zero

# Special FP32 bit patterns
FP32_POS_ZERO = 0x00000000
FP32_NEG_ZERO = 0x80000000
FP32_POS_INF  = 0x7F800000
FP32_NEG_INF  = 0xFF800000
FP32_QNAN     = 0x7FC00000
FP32_POS_ONE  = 0x3F800000
FP32_NEG_ONE  = 0xBF800000
FP32_POS_PI   = 0x40490FDB
FP32_NEG_PI   = 0xC0490FDB   # −π ≈ −3.14159


class FPUSeqItem(uvm_sequence_item):
    """
    Transaction representing one FPU operation request.

    Fields:
        op      : 6-bit opcode  (op_i[5:4] = unit, op_i[3:0] = sub-op)
        src_a   : FP32 operand A  (src_a_i)
        src_b   : FP32 operand B  (src_b_i)
        src_c   : FP32 operand C  (src_c_i, used by FMA)
        int_src : integer operand (int_src_i, used by CVT)
        rm      : rounding mode   (rm_i[2:0])
    """

    def __init__(self, name="fpu_seq_item"):
        super().__init__(name)
        self.op      = OP_FCLASS
        self.src_a   = FP32_POS_ZERO
        self.src_b   = FP32_POS_ZERO
        self.src_c   = FP32_POS_ZERO
        self.int_src = 0
        self.rm      = RM_RNE

    @property
    def unit(self) -> int:
        return (self.op >> 4) & 0x3

    def randomize_noncomp(self):
        self.op    = (UNIT_NONCOMP << 4) | random.randint(0, 8)
        self.src_a = random.getrandbits(32)
        self.src_b = random.getrandbits(32)
        self.rm    = 0

    def randomize_fma(self):
        self.op    = (UNIT_FMA << 4) | random.randint(0, 6)
        self.src_a = random.getrandbits(32)
        self.src_b = random.getrandbits(32)
        self.src_c = random.getrandbits(32)
        self.rm    = random.randint(0, 4)

    def randomize_divsqrt(self):
        self.op    = (UNIT_DIVSQRT << 4) | random.randint(0, 1)
        self.src_a = random.getrandbits(32)
        self.src_b = random.getrandbits(32)
        self.rm    = random.randint(0, 4)

    def randomize_any(self):
        unit = random.choice([UNIT_FMA, UNIT_DIVSQRT, UNIT_NONCOMP])
        if unit == UNIT_FMA:
            self.randomize_fma()
        elif unit == UNIT_DIVSQRT:
            self.randomize_divsqrt()
        else:
            self.randomize_noncomp()

    def convert2string(self):
        return (f"FPUSeqItem op=0x{self.op:02X} "
                f"a=0x{self.src_a:08X} b=0x{self.src_b:08X} rm={self.rm}")
