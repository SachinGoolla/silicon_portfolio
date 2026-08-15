"""
test_directed.py — pyuvm directed test for fpu_top.

Runs three directed sequences:
  - FPUNoncompTest   : all 9 NONCOMP ops with full scoreboard checking
  - FPUArithTest     : FMA unit corners (special-case classification only)
  - FPUDivSqrtTest   : FDIV/FSQRT basics

The cocotb entry point at the bottom (test_directed) resets the DUT, then
runs each test class in sequence via uvm_root().run_test().
"""
import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, Timer
from pyuvm import uvm_test, uvm_root, ConfigDB

from fpu_env        import FPUEnv
from fpu_sequences  import FPUNoncompSeq, FPUArithSeq, FPUDivSqrtSeq


# ─────────────────────────────────────────── test classes

class FPUNoncompTest(uvm_test):
    def build_phase(self):
        self.env = FPUEnv.create("env", self)

    async def run_phase(self):
        self.raise_objection()
        seq = FPUNoncompSeq("noncomp_seq")
        await seq.start(self.env.sequencer)
        await Timer(50, unit="ns")   # drain pipeline
        self.drop_objection()

    def report_phase(self):
        sb = self.env.scoreboard
        if sb.failed:
            self.logger.critical(
                f"FPUNoncompTest FAILED: {sb.failed} scoreboard mismatches"
            )
            assert False, f"{sb.failed} scoreboard mismatches"


class FPUArithTest(uvm_test):
    def build_phase(self):
        self.env = FPUEnv.create("env", self)

    async def run_phase(self):
        self.raise_objection()
        seq = FPUArithSeq("arith_seq")
        await seq.start(self.env.sequencer)
        await Timer(100, unit="ns")
        self.drop_objection()

    def report_phase(self):
        sb = self.env.scoreboard
        if sb.failed:
            self.logger.critical(
                f"FPUArithTest FAILED: {sb.failed} scoreboard mismatches"
            )
            assert False, f"{sb.failed} scoreboard mismatches"


class FPUDivSqrtTest(uvm_test):
    def build_phase(self):
        self.env = FPUEnv.create("env", self)

    async def run_phase(self):
        self.raise_objection()
        seq = FPUDivSqrtSeq("divsqrt_seq")
        await seq.start(self.env.sequencer)
        await Timer(500, unit="ns")   # FDIV/FSQRT can take up to 30 cycles each
        self.drop_objection()

    def report_phase(self):
        sb = self.env.scoreboard
        if sb.failed:
            self.logger.critical(
                f"FPUDivSqrtTest FAILED: {sb.failed} scoreboard mismatches"
            )
            assert False, f"{sb.failed} scoreboard mismatches"


# ─────────────────────────────────────────── DUT reset helper

async def _reset(dut):
    dut.rst_n.value    = 0
    dut.valid_i.value  = 0
    dut.ready_i.value  = 1
    dut.op_i.value     = 0
    dut.src_a_i.value  = 0
    dut.src_b_i.value  = 0
    dut.src_c_i.value  = 0
    dut.int_src_i.value = 0
    dut.rm_i.value     = 0
    dut.fmt_i.value    = 0
    await Timer(40, unit="ns")
    dut.rst_n.value = 1
    await Timer(10, unit="ns")


# ─────────────────────────────────────────── cocotb entry points

@cocotb.test()
async def test_noncomp(dut):
    """NONCOMP operations — exact scoreboard checking."""
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    await _reset(dut)
    ConfigDB().set(None, "*", "DUT", dut)
    await uvm_root().run_test("FPUNoncompTest", keep_singletons=True)


@cocotb.test()
async def test_arith(dut):
    """FMA unit — special-case classification checking."""
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    await _reset(dut)
    ConfigDB().set(None, "*", "DUT", dut)
    await uvm_root().run_test("FPUArithTest", keep_singletons=True)


@cocotb.test()
async def test_divsqrt(dut):
    """FDIV / FSQRT — special-case classification checking."""
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    await _reset(dut)
    ConfigDB().set(None, "*", "DUT", dut)
    await uvm_root().run_test("FPUDivSqrtTest", keep_singletons=True)
