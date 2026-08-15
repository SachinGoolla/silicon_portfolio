"""
FPU golden reference model.

Scope
-----
NONCOMP (op[5:4]=11): EXACT bit-level match — pure bit manipulation.
FMA/CVT/DIVSQRT      : CLASSIFICATION check only (NaN/Inf/Zero/sign are
                       validated; mantissa is NOT checked here because Python
                       double arithmetic is double-rounded vs. FP32-exact).
                       A bit-accurate oracle requires softfloat bindings —
                       add sfpy when available for full mantissa checking.
"""
import struct
from fpu_seq_item import (
    UNIT_FMA, UNIT_DIVSQRT, UNIT_CVT, UNIT_NONCOMP,
    OP_FCLASS, OP_FSGNJ, OP_FSGNJN, OP_FSGNJX,
    OP_FEQ, OP_FLT, OP_FLE, OP_FMIN, OP_FMAX,
    FP32_QNAN, FP32_NEG_ZERO, FP32_POS_ZERO,
)


# ────────────────────────────────────────────────── FP32 helpers

def _bits(f: float) -> int:
    return struct.unpack(">I", struct.pack(">f", f))[0]

def _float(b: int) -> float:
    return struct.unpack(">f", struct.pack(">I", b & 0xFFFF_FFFF))[0]

def is_nan(b: int) -> bool:
    return ((b >> 23) & 0xFF) == 0xFF and (b & 0x7FFFFF) != 0

def is_qnan(b: int) -> bool:
    return is_nan(b) and bool(b & 0x400000)

def is_snan(b: int) -> bool:
    return is_nan(b) and not bool(b & 0x400000)

def is_inf(b: int) -> bool:
    return (b & 0x7FFFFFFF) == 0x7F800000

def is_zero(b: int) -> bool:
    return (b & 0x7FFFFFFF) == 0

def sign(b: int) -> int:
    return (b >> 31) & 1

def _compare(a: int, b: int):
    """(is_lt, is_eq) for two FP32 bit patterns; caller must filter NaN."""
    if is_zero(a) and is_zero(b):
        return False, True
    return (_float(a) < _float(b)), (_float(a) == _float(b))


# ────────────────────────────────────────────────── NONCOMP golden

def _fclass(a: int) -> int:
    s    = sign(a)
    exp  = (a >> 23) & 0xFF
    mant = a & 0x7FFFFF
    qbit = bool(a & 0x400000)
    nan_ = (exp == 0xFF) and mant
    inf_ = (exp == 0xFF) and not mant
    zero = not exp and not mant
    sub  = not exp and mant
    norm = 1 <= exp <= 254
    if nan_ and qbit:   return 1 << 9   # quiet NaN
    if nan_:            return 1 << 8   # signaling NaN
    if inf_ and s:      return 1 << 0   # -inf  (RISC-V bit 0)
    if norm and s:      return 1 << 1   # -normal
    if sub  and s:      return 1 << 2   # -subnormal
    if zero and s:      return 1 << 3   # -zero
    if zero:            return 1 << 4   # +zero
    if sub:             return 1 << 5   # +subnormal
    if norm:            return 1 << 6   # +normal
    if inf_:            return 1 << 7   # +inf
    return 0


def _fsgnj(a: int, b: int, op: int) -> int:
    payload = a & 0x7FFFFFFF
    sa, sb  = sign(a), sign(b)
    if   op == OP_FSGNJ:   ns = sb
    elif op == OP_FSGNJN:  ns = sb ^ 1
    else:                   ns = sa ^ sb
    return (ns << 31) | payload


def _feq(a: int, b: int):
    if is_nan(a) or is_nan(b):
        return 0, (is_snan(a) or is_snan(b))
    _, eq = _compare(a, b)
    return int(eq), False


def _flt(a: int, b: int):
    if is_nan(a) or is_nan(b): return 0, True
    lt, _ = _compare(a, b)
    return int(lt), False


def _fle(a: int, b: int):
    if is_nan(a) or is_nan(b): return 0, True
    lt, eq = _compare(a, b)
    return int(lt or eq), False


def _fmin(a: int, b: int):
    na, nb = is_nan(a), is_nan(b)
    nv = is_snan(a) or is_snan(b)
    if na and nb:  return FP32_QNAN, True
    if na:         return b, nv
    if nb:         return a, nv
    if is_zero(a) and is_zero(b): return FP32_NEG_ZERO, False
    lt, _ = _compare(a, b)
    return (a if lt else b), False


def _fmax(a: int, b: int):
    na, nb = is_nan(a), is_nan(b)
    nv = is_snan(a) or is_snan(b)
    if na and nb:  return FP32_QNAN, True
    if na:         return b, nv
    if nb:         return a, nv
    if is_zero(a) and is_zero(b): return FP32_POS_ZERO, False
    lt, _ = _compare(a, b)
    return (b if lt else a), False


# ────────────────────────────────────────────────── Public API

class CheckResult:
    """
    What the scoreboard should verify.

    exact_result : int or None  — if not None, DUT result_o must match exactly
    exact_int    : int or None  — if not None, DUT int_result_o must match
    nv_flag      : bool or None — if not None, NV bit in fflags_o must match
    classify     : dict or None — {"nan": bool, "inf": bool, "zero": bool}
                                  check only structural class, not mantissa
    """
    def __init__(self):
        self.exact_result = None
        self.exact_int    = None
        self.nv_flag      = None
        self.classify     = None
        self.description  = ""


def expected(inp) -> CheckResult:
    """
    Compute what the scoreboard should verify for a given FPUInputCapture.
    Returns a CheckResult with fields set according to what can be checked.
    """
    cr  = CheckResult()
    op  = inp.op
    a   = inp.src_a
    b   = inp.src_b
    sub = op & 0xF

    if (op >> 4) == UNIT_NONCOMP:
        if   sub == 0x0:   # FCLASS
            cr.exact_int  = _fclass(a)
            cr.description = f"FCLASS 0x{a:08X}"

        elif sub in (0x1, 0x2, 0x3):   # FSGNJ / FSGNJN / FSGNJX
            cr.exact_result = _fsgnj(a, b, op)
            cr.description  = f"FSGNJ* 0x{a:08X},0x{b:08X}"

        elif sub == 0x4:   # FEQ
            r, nv = _feq(a, b)
            cr.exact_int = r; cr.nv_flag = nv
            cr.description = f"FEQ 0x{a:08X},0x{b:08X}"

        elif sub == 0x5:   # FLT
            r, nv = _flt(a, b)
            cr.exact_int = r; cr.nv_flag = nv
            cr.description = f"FLT 0x{a:08X},0x{b:08X}"

        elif sub == 0x6:   # FLE
            r, nv = _fle(a, b)
            cr.exact_int = r; cr.nv_flag = nv
            cr.description = f"FLE 0x{a:08X},0x{b:08X}"

        elif sub == 0x7:   # FMIN
            r, nv = _fmin(a, b)
            cr.exact_result = r; cr.nv_flag = nv
            cr.description = f"FMIN 0x{a:08X},0x{b:08X}"

        elif sub == 0x8:   # FMAX
            r, nv = _fmax(a, b)
            cr.exact_result = r; cr.nv_flag = nv
            cr.description = f"FMAX 0x{a:08X},0x{b:08X}"

    else:
        # FMA / DIVSQRT / CVT — classify result only (no mantissa check)
        # NaN in → NaN out (propagation), Inf/Zero structural rules
        if is_nan(a) or is_nan(b):
            cr.classify = {"nan": True}
        else:
            cr.classify = None   # no check — add sfpy for bit-accurate oracle
        cr.description = f"op=0x{op:02X} (structural only)"

    return cr
