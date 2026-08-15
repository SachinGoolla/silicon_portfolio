"""test_coverage_closure.py -- checkpoint 7: the full pyUVM
constrained-random coverage-closure run for mac_cluster.

Iteration count is derived from a real measurement, not a guess: checkpoint
3's own timing spike (test_timing_probe.py) measured 20 push+poll
iterations at 0.52s real wall-clock time under Icarus (~26ms/iteration).
MacClusterClosureSeq's own iterations are a mix of push+poll (dominant),
occasional weight reloads, and occasional raw CSR ops -- roughly the same
per-iteration cost shape -- so CLOSURE_ITERATIONS=300 budgets to roughly
~8s real time, well inside this shared host's resource-safety discipline
(see project memory feedback_resource_limits) without needing a multi-seed
overlapping-run scheme the way an unmeasured 500-seed sweep would have.

Hard gate, non-negotiable regardless of coverage percentage attained:
zero scoreboard mismatches (sb.failed, which includes leftover -- unlike
test_race_adjacent.py, this sequence's own push-then-poll discipline means
leftover should genuinely be 0 by construction) and zero stale-read
violations. Coverage percentage itself is reported, not gated, unless
--uvm-coverage-threshold is passed (wired in p3_functional.py, mirroring
p5_coverage.py's own --coverage-threshold pattern) -- a bin still open
after this budgeted run is a documented coverage hole for REPORT.md, not a
silently accepted gap.
"""
import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, Timer
from pyuvm import uvm_test, uvm_root, ConfigDB

from mac_cluster_env import MacClusterEnv
from mac_cluster_sequences import MacClusterClosureSeq

CLOSURE_ITERATIONS = 300


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


class MacClusterCoverageClosureTest(uvm_test):
    def build_phase(self):
        self.env = MacClusterEnv.create("env", self)

    async def run_phase(self):
        self.raise_objection()
        sb, cov = self.env.scoreboard, self.env.coverage

        self.env.driver.randomize_backpressure = True
        seq = MacClusterClosureSeq("closure", iterations=CLOSURE_ITERATIONS,
                                    scoreboard=sb, coverage=cov)
        await seq.start(self.env.sequencer)
        self.env.driver.randomize_backpressure = False

        await Timer(200, unit="ns")   # let the drain loops + hier monitor settle
        self.drop_objection()

    def report_phase(self):
        sb, cov = self.env.scoreboard, self.env.coverage
        violations = sb.stale_read_violations()
        self.logger.info(
            f"MacClusterCoverageClosureTest: {CLOSURE_ITERATIONS} iterations, "
            f"scoreboard {sb.matched} matched / {sb.unexpected} unexpected, "
            f"stale_read_violations={violations}, "
            f"overall coverage={cov.overall_coverage_pct:.1f}%"
        )
        for cp in cov._all_covergroups:
            self.logger.info(cp.report())
        if sb.failed:
            self.logger.critical(
                f"MacClusterCoverageClosureTest FAILED: sb.failed={sb.failed} "
                f"({sb.unexpected} unexpected, "
                f"{sum(v for v in sb.expected.values() if v > 0)} leftover, "
                f"{len(violations)} stale-read violations)")
            assert False, f"scoreboard/stale-read failures: sb.failed={sb.failed}"


@cocotb.test()
async def test_coverage_closure(dut):
    """Full constrained-random closure run -- coverage percentages captured
    in the log for pillar integration (checkpoint 8) to read back."""
    await _reset(dut)
    ConfigDB().set(None, "*", "DUT", dut)
    await uvm_root().run_test("MacClusterCoverageClosureTest", keep_singletons=True)
