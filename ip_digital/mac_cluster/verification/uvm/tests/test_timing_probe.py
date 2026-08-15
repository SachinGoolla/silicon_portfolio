"""test_timing_probe.py -- checkpoint 3: measures real wall-clock cost of
MacClusterBasicRandomSeq at a small, fixed iteration count, so the Phase 4
plan's closure-run budget (checkpoint 7) is derived from an actual number
instead of a guess -- both competing architecture proposals guessed (300-500
iterations / cross-seed merged runs) and this repo's own recent history
(a GLS run burning 10 minutes of CPU for zero output) is reason enough not
to repeat that pattern here. Timed externally via the shell `time` command
around the pillar invocation, not in-sim -- simplest, most direct measure
of what a real closure run would actually cost end to end.
"""
import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, Timer
from pyuvm import uvm_test, uvm_root, ConfigDB

from mac_cluster_env import MacClusterEnv
from mac_cluster_sequences import MacClusterBasicRandomSeq

TIMING_PROBE_ITERATIONS = 20


async def _reset(dut):
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    dut.rst_n.value = 0
    dut.awvalid_i.value = 0
    dut.wvalid_i.value = 0
    dut.bready_i.value = 0
    dut.arvalid_i.value = 0
    dut.rready_i.value = 0
    for _ in range(5):
        await RisingEdge(dut.clk)
    dut.rst_n.value = 1
    await RisingEdge(dut.clk)


class MacClusterTimingProbeTest(uvm_test):
    def build_phase(self):
        self.env = MacClusterEnv.create("env", self)

    async def run_phase(self):
        self.raise_objection()
        seq = MacClusterBasicRandomSeq("timing_probe_seq", iterations=TIMING_PROBE_ITERATIONS,
                                        scoreboard=self.env.scoreboard, coverage=self.env.coverage)
        await seq.start(self.env.sequencer)
        await Timer(100, unit="ns")   # let the scoreboard's two drain loops settle
        self.drop_objection()
        self._pushed = seq.pushed

    def report_phase(self):
        sb = self.env.scoreboard
        self.logger.info(
            f"MacClusterTimingProbeTest: {TIMING_PROBE_ITERATIONS} push+poll "
            f"iterations completed, {len(self._pushed)} entries pushed, "
            f"{sb.matched} scoreboard matches, {sb.failed} scoreboard failures."
        )
        if sb.failed:
            self.logger.critical(f"MacClusterTimingProbeTest FAILED: {sb.failed} scoreboard mismatches")
            assert False, f"{sb.failed} scoreboard mismatches"


@cocotb.test()
async def test_timing_probe(dut):
    """20 randomized push+poll iterations -- measure this externally
    (`time` around the pillar invocation) to derive the real closure
    budget, per the Phase 4 plan's checkpoint 3/§7."""
    await _reset(dut)
    ConfigDB().set(None, "*", "DUT", dut)
    await uvm_root().run_test("MacClusterTimingProbeTest", keep_singletons=True)
