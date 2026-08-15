"""FPU functional coverage groups."""
from pyuvm import uvm_subscriber, uvm_analysis_port, ConfigDB
from fpu_seq_item import (
    UNIT_FMA, UNIT_DIVSQRT, UNIT_CVT, UNIT_NONCOMP,
    RM_RNE, RM_RTZ, RM_RDN, RM_RUP, RM_RMM,
)
from fpu_ref import is_nan, is_inf, is_zero, is_snan


class CoverPoint:
    """Simple bin-based coverage counter."""

    def __init__(self, name: str, bins: dict):
        self.name = name
        self.bins = {k: 0 for k in bins}
        self._keys = bins   # key → label

    def sample(self, value):
        if value in self.bins:
            self.bins[value] += 1

    @property
    def coverage(self) -> float:
        hit = sum(1 for v in self.bins.values() if v > 0)
        return (hit / len(self.bins)) * 100.0 if self.bins else 0.0

    def report(self):
        lines = [f"  {self.name}: {self.coverage:.0f}%"]
        for key, label in self._keys.items():
            count = self.bins[key]
            lines.append(f"    [{label}]: {count} hits")
        return "\n".join(lines)


class FPUCoverage(uvm_subscriber):
    """
    Subscribes to the input monitor's analysis port.
    Tracks: op unit, sub-opcode, rounding mode, special operand classes.
    """

    def build_phase(self):
        self.cp_unit = CoverPoint("Unit", {
            UNIT_FMA:     "FMA",
            UNIT_DIVSQRT: "DIV/SQRT",
            UNIT_CVT:     "CVT",
            UNIT_NONCOMP: "NONCOMP",
        })
        self.cp_rm = CoverPoint("RoundingMode", {
            RM_RNE: "RNE",
            RM_RTZ: "RTZ",
            RM_RDN: "RDN",
            RM_RUP: "RUP",
            RM_RMM: "RMM",
        })
        self.cp_special_a = CoverPoint("SpecialA", {
            "nan":  "NaN input A",
            "inf":  "Inf input A",
            "zero": "Zero input A",
            "norm": "Normal input A",
        })
        self.cp_noncomp_sub = CoverPoint("NoncompSubOp", {
            0x0: "FCLASS",
            0x1: "FSGNJ",
            0x2: "FSGNJN",
            0x3: "FSGNJX",
            0x4: "FEQ",
            0x5: "FLT",
            0x6: "FLE",
            0x7: "FMIN",
            0x8: "FMAX",
        })

    def write(self, inp):
        unit = (inp.op >> 4) & 0x3
        self.cp_unit.sample(unit)
        self.cp_rm.sample(inp.rm)

        a = inp.src_a
        if   is_nan(a):  self.cp_special_a.sample("nan")
        elif is_inf(a):  self.cp_special_a.sample("inf")
        elif is_zero(a): self.cp_special_a.sample("zero")
        else:            self.cp_special_a.sample("norm")

        if unit == UNIT_NONCOMP:
            self.cp_noncomp_sub.sample(inp.op & 0xF)

    def report_phase(self):
        for cp in [self.cp_unit, self.cp_rm, self.cp_special_a, self.cp_noncomp_sub]:
            self.logger.info(cp.report())
