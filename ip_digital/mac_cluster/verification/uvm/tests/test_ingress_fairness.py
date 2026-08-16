"""test_ingress_fairness.py -- Phase 5 checkpoint A: the load-bearing
empirical check for tile_ni.sv's ingress-mux fairness fix
(entry_starve_cnt_q / FAIRNESS_LIMIT), formally proven bounded by
tile_ni_liveness.sby (entry_starve_cnt_q <= FAIRNESS_LIMIT+1).

Deliberately does NOT reuse ConcurrentEgressReconfigSeq/test_race_adjacent.py
-- that sequence's own docstring identifies its observed starvation as
DOMINATED by an exit-buffer-freeze mechanism (an undrained single-slot exit
register wedging axi4stream_ctrl.sv's array), a different, unfixed-by-this-
checkpoint mechanism. IngressFairnessSeq fully drains every iteration so the
freeze mechanism cannot engage, isolating whatever remains -- which should
now be nothing, per the formal bound.
"""
import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, Timer
from pyuvm import uvm_test, uvm_root, ConfigDB

from mac_cluster_env import MacClusterEnv
from mac_cluster_sequences import WeightLoadSeq, IngressFairnessSeq, PRODUCER_TILES, CONSUMER_TILE
from mac_cluster_seq_item import WEIGHT_CLASSES
import random


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


class MacClusterIngressFairnessTest(uvm_test):
    ITERATIONS = 20

    def build_phase(self):
        self.env = MacClusterEnv.create("env", self)

    async def run_phase(self):
        self.raise_objection()
        sb, cov = self.env.scoreboard, self.env.coverage

        for tile in (PRODUCER_TILES[0], CONSUMER_TILE):
            wc = random.choice(WEIGHT_CLASSES)
            wseq = WeightLoadSeq(f"wload_{tile}", tile=tile, weight_class=wc)
            await wseq.start(self.env.sequencer)
            sb.load_weights(tile, wseq.weight_rows)
            cov.load_weights(tile, wseq.weight_rows)

        seq = IngressFairnessSeq("ingress_fairness", mesh_src=PRODUCER_TILES[0],
                                  tile=CONSUMER_TILE, iterations=self.ITERATIONS)
        await seq.start(self.env.sequencer)

        await Timer(200, unit="ns")   # let scoreboard/hier monitor settle
        self.drop_objection()
        self._starved_count = seq.starved_count
        self._drain_starved_count = seq.drain_starved_count

    def report_phase(self):
        sb = self.env.scoreboard
        violations = sb.stale_read_violations()
        leftover = sum(v for v in sb.expected.values() if v > 0)
        self.logger.info(
            f"MacClusterIngressFairnessTest: {self.ITERATIONS} iterations, "
            f"{self._starved_count} entry pushes starved (load-bearing -- must be 0, "
            f"per tile_ni_liveness.sby's entry_starve_cnt_q <= FAIRNESS_LIMIT+1 bound), "
            f"{self._drain_starved_count} drain polls timed out (informational -- every "
            f"iteration fully drains before the next, so this should also be 0 in "
            f"practice), scoreboard {sb.matched} matched / {sb.unexpected} unexpected / "
            f"{leftover} never-drained, stale_read_violations={violations}."
        )
        if self._starved_count:
            self.logger.critical(
                f"MacClusterIngressFairnessTest FAILED: {self._starved_count} entry "
                f"pushes starved despite the formal fairness bound -- either the bound "
                f"is wrong, or this test's isolation from the freeze mechanism failed.")
            assert False, f"{self._starved_count} entry pushes starved"
        if sb.unexpected or violations:
            self.logger.critical(
                f"MacClusterIngressFairnessTest FAILED: {sb.unexpected} unexpected "
                f"results, stale-read violations {violations}")
            assert False, f"{sb.unexpected} unexpected results, stale-read violations {violations}"


@cocotb.test()
async def test_ingress_fairness(dut):
    """Isolated regression for tile_ni.sv's ingress-mux fairness bound --
    starved_count must be 0 across ITERATIONS iterations."""
    await _reset(dut)
    ConfigDB().set(None, "*", "DUT", dut)
    await uvm_root().run_test("MacClusterIngressFairnessTest", keep_singletons=True)
