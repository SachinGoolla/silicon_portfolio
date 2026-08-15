"""FPU sequences — directed and random stimulus generators."""
from pyuvm import uvm_sequence
from fpu_seq_item import (
    FPUSeqItem,
    OP_FCLASS, OP_FSGNJ, OP_FSGNJN, OP_FSGNJX,
    OP_FEQ, OP_FLT, OP_FLE, OP_FMIN, OP_FMAX,
    OP_FADD, OP_FSUB, OP_FMUL, OP_FMADD,
    OP_FDIV, OP_FSQRT,
    RM_RNE, RM_RTZ,
    FP32_POS_ZERO, FP32_NEG_ZERO, FP32_POS_INF, FP32_NEG_INF,
    FP32_QNAN, FP32_POS_ONE, FP32_NEG_ONE, FP32_POS_PI, FP32_NEG_PI,
)


async def _send(seq, op, a=0, b=0, c=0, int_src=0, rm=RM_RNE):
    item = FPUSeqItem(f"item_{op:02X}")
    item.op      = op
    item.src_a   = a
    item.src_b   = b
    item.src_c   = c
    item.int_src = int_src
    item.rm      = rm
    await seq.start_item(item)
    await seq.finish_item(item)


class FPUNoncompSeq(uvm_sequence):
    """All 9 NONCOMP operations with corner-case operands."""

    async def body(self):
        # FCLASS — all classes of FP32 numbers
        for val in [FP32_POS_ZERO, FP32_NEG_ZERO, FP32_POS_INF, FP32_NEG_INF,
                    FP32_QNAN, 0x7F800001, FP32_POS_ONE, FP32_NEG_ONE,
                    0x00000001, 0x80000001]:   # subnormals
            await _send(self, OP_FCLASS, a=val)

        # FSGNJ / FSGNJN / FSGNJX
        for op in [OP_FSGNJ, OP_FSGNJN, OP_FSGNJX]:
            await _send(self, op, a=FP32_POS_ONE, b=FP32_NEG_ONE)
            await _send(self, op, a=FP32_NEG_PI,  b=FP32_POS_INF)
            await _send(self, op, a=FP32_QNAN,    b=FP32_NEG_ZERO)

        # FEQ / FLT / FLE
        pairs = [
            (FP32_POS_ONE, FP32_POS_ONE),
            (FP32_POS_ONE, FP32_NEG_ONE),
            (FP32_POS_INF, FP32_POS_INF),
            (FP32_QNAN,    FP32_POS_ONE),
            (0x7F800001,   FP32_POS_ONE),   # sNaN triggers NV
            (FP32_POS_ZERO, FP32_NEG_ZERO),
        ]
        for op in [OP_FEQ, OP_FLT, OP_FLE]:
            for a, b in pairs:
                await _send(self, op, a=a, b=b)

        # FMIN / FMAX
        for op in [OP_FMIN, OP_FMAX]:
            for a, b in pairs:
                await _send(self, op, a=a, b=b)


class FPUArithSeq(uvm_sequence):
    """Basic arithmetic (FMA unit) corner cases."""

    async def body(self):
        # FADD: normals, inf, NaN
        for a, b in [
            (FP32_POS_ONE, FP32_POS_ONE),
            (FP32_POS_INF, FP32_NEG_INF),
            (FP32_QNAN,    FP32_POS_ONE),
            (FP32_POS_ZERO, FP32_NEG_ZERO),
        ]:
            await _send(self, OP_FADD, a=a, b=b, rm=RM_RNE)

        # FSUB
        await _send(self, OP_FSUB, a=FP32_POS_PI, b=FP32_POS_ONE, rm=RM_RNE)
        await _send(self, OP_FSUB, a=FP32_POS_INF, b=FP32_POS_INF, rm=RM_RNE)

        # FMUL
        await _send(self, OP_FMUL, a=FP32_POS_ONE, b=FP32_NEG_ONE, rm=RM_RNE)
        await _send(self, OP_FMUL, a=FP32_POS_ZERO, b=FP32_POS_INF, rm=RM_RNE)

        # FMADD: a*b+c
        await _send(self, OP_FMADD,
                    a=FP32_POS_ONE, b=FP32_POS_ONE, c=FP32_POS_ONE, rm=RM_RNE)
        await _send(self, OP_FMADD,
                    a=FP32_POS_PI, b=FP32_POS_ONE, c=FP32_NEG_ONE, rm=RM_RTZ)


class FPUDivSqrtSeq(uvm_sequence):
    """FDIV and FSQRT basics (each takes up to 30 sim cycles)."""

    async def body(self):
        # FDIV
        await _send(self, OP_FDIV, a=FP32_POS_ONE, b=FP32_POS_ONE, rm=RM_RNE)
        await _send(self, OP_FDIV, a=FP32_POS_PI,  b=FP32_POS_ONE, rm=RM_RNE)
        await _send(self, OP_FDIV, a=FP32_POS_ONE, b=FP32_POS_ZERO, rm=RM_RNE)  # /0 = +inf
        await _send(self, OP_FDIV, a=FP32_POS_ZERO, b=FP32_POS_ZERO, rm=RM_RNE)  # 0/0 = NaN

        # FSQRT
        await _send(self, OP_FSQRT, a=FP32_POS_ONE,  rm=RM_RNE)
        await _send(self, OP_FSQRT, a=FP32_POS_ZERO, rm=RM_RNE)
        await _send(self, OP_FSQRT, a=FP32_NEG_ONE,  rm=RM_RNE)   # sqrt(-1) = NaN


class FPURandomSeq(uvm_sequence):
    """Constrained-random transactions across all functional units."""

    def __init__(self, name="fpu_random_seq", count=40):
        super().__init__(name)
        self.count = count

    async def body(self):
        item = FPUSeqItem()
        for _ in range(self.count):
            item.randomize_any()
            new = FPUSeqItem(f"rand_{_}")
            new.op = item.op; new.src_a = item.src_a; new.src_b = item.src_b
            new.src_c = item.src_c; new.int_src = item.int_src; new.rm = item.rm
            await self.start_item(new)
            await self.finish_item(new)
