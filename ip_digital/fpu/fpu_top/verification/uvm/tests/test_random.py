"""
test_random.py — constrained-random pyuvm test for fpu_top.

Sends 60 randomized transactions across all four functional units.
The scoreboard performs exact checking for NONCOMP and structural
(NaN/Inf/Zero class) checking for FMA/DIV/SQRT.
"""
import cocotb
from cocotb.clock import Clock
from cocotb.triggers import Timer
from pyuvm import uvm_test, uvm_root, ConfigDB

from fpu_env       import FPUEnv
from fpu_sequences import FPURandomSeq


class FPURandomTest(uvm_test):
    def build_phase(self):
        self.env = FPUEnv.create("env", self)

    async def run_phase(self):
        self.raise_objection()
        seq = FPURandomSeq("random_seq", count=60)
        await seq.start(self.env.sequencer)
        await Timer(2000, unit="ns")   # generous drain for slow DIVSQRT
        self.drop_objection()

    def report_phase(self):
        sb = self.env.scoreboard
        cov = self.env.coverage
        self.logger.info(
            f"Random test: {sb.passed} passed, {sb.failed} failed | "
            f"unit coverage: {cov.cp_unit.coverage:.0f}% | "
            f"rm coverage: {cov.cp_rm.coverage:.0f}%"
        )
        if sb.failed:
            self.logger.critical(
                f"FPURandomTest FAILED: {sb.failed} scoreboard mismatches"
            )
            assert False, f"{sb.failed} scoreboard mismatches"


@cocotb.test()
async def test_random(dut):
    """Constrained-random stimulus across all functional units."""
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())

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

    ConfigDB().set(None, "*", "DUT", dut)
    await uvm_root().run_test("FPURandomTest", keep_singletons=True)
