"""test_race_adjacent.py -- checkpoint 6: exercises the grafted,
race-adjacent additions (ConcurrentEgressReconfigSeq, ReloadWhileBusySeq's
outcome classification, and per-beat randomized backpressure) that the
existing fixed-topology directed test structurally cannot reach.

Not a closure run (that's checkpoint 7/test_coverage_closure.py) -- this is
the sanity check that each grafted piece actually does something
observable: cp_ingress_mux_contention should show at least a chance to
move off its checkpoint-5 baseline (0 hits), cp_reload_while_busy should
gain real samples, and the stale-read detector should run clean throughout.
"""
import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, Timer
from pyuvm import uvm_test, uvm_root, ConfigDB

from mac_cluster_env import MacClusterEnv
from mac_cluster_sequences import (
    WeightLoadSeq, ActivationStreamSeq, ConcurrentEgressReconfigSeq, ReloadWhileBusySeq,
    CsrPollSeq, PRODUCER_TILES, CONSUMER_TILE,
)
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


class MacClusterRaceAdjacentTest(uvm_test):
    RECONFIG_ATTEMPTS = 8
    RELOAD_ATTEMPTS = 5

    def build_phase(self):
        self.env = MacClusterEnv.create("env", self)

    async def run_phase(self):
        self.raise_objection()
        sb, cov = self.env.scoreboard, self.env.coverage
        # Every push in this test is fed through a REAL poll afterward (via
        # CsrPollSeq, which drives _do_poll_exit -> exit_ap) rather than
        # left undrained or drained only via ConcurrentEgressReconfigSeq's
        # own opportunistic raw-CSR ack. Found necessary: an earlier
        # version of this test never issued a single POLL_EXIT anywhere in
        # its call graph, so exit_ap was never fed, MacClusterScoreboard.
        # _on_exit never ran, and stale_read_violations()/sb.unexpected
        # stayed trivially clean regardless of what the DUT actually did --
        # this test's own report_phase claimed those were "the real
        # signals" while they were structurally inert. A poll issued AFTER
        # each racy sequence completes verifies without suppressing the
        # race itself (the race already happened during the sequence; this
        # only checks its outcome), and a generous timeout (500) tolerates
        # the case where the array was mid-recovery from the very
        # buffer-overflow class ConcurrentEgressReconfigSeq's own docstring
        # documents.
        last_seq = {t: 0 for t in range(4)}

        for tile in range(4):
            wc = random.choice(WEIGHT_CLASSES)
            wseq = WeightLoadSeq(f"wload_{tile}", tile=tile, weight_class=wc)
            await wseq.start(self.env.sequencer)
            sb.load_weights(tile, wseq.weight_rows)
            cov.load_weights(tile, wseq.weight_rows)

        self.env.driver.randomize_backpressure = True

        starved = 0
        poll_starved = 0
        for i in range(self.RECONFIG_ATTEMPTS):
            mesh_src = PRODUCER_TILES[i % len(PRODUCER_TILES)]
            seq = ConcurrentEgressReconfigSeq(f"cerc_{i}", mesh_src=mesh_src,
                                               tile=CONSUMER_TILE, timeout=150)
            await seq.start(self.env.sequencer)
            if seq.starved:
                starved += 1

            poll_seq = CsrPollSeq(f"cerc_verify_poll_{i}", tile=CONSUMER_TILE,
                                   last_seq=last_seq[CONSUMER_TILE], timeout=500)
            await poll_seq.start(self.env.sequencer)
            if poll_seq.starved:
                poll_starved += 1
            else:
                last_seq[CONSUMER_TILE] = poll_seq.result_seq

        for i in range(self.RELOAD_ATTEMPTS):
            tile = random.choice(PRODUCER_TILES)
            # Push a real activation on this SAME tile first (local loopback
            # -- cheapest, no mesh timing to reason about) so busy_comb (the
            # systolic array's own multi-cycle pipeline-occupancy signal,
            # longer-lived than entry_pending_q) has a real chance to still
            # be 1 by the time ReloadWhileBusySeq's own probe read lands
            # immediately after.
            await ActivationStreamSeq(f"pre_reload_push_{i}", src=tile,
                                       dest=(0, 0), mesh_egress_en=0).start(self.env.sequencer)
            reload_seq = ReloadWhileBusySeq(f"reload_{i}", tile=tile)
            await reload_seq.start(self.env.sequencer)
            cov.sample_reload_while_busy(
                "attempted_dropped" if reload_seq.observed_busy else "attempted_applied")

            poll_seq = CsrPollSeq(f"reload_verify_poll_{i}", tile=tile,
                                   last_seq=last_seq[tile], timeout=500)
            await poll_seq.start(self.env.sequencer)
            if poll_seq.starved:
                poll_starved += 1
            else:
                last_seq[tile] = poll_seq.result_seq

            # reload_seq above may or may not have actually applied its own
            # weight matrix to the RTL (that ambiguity is the whole point
            # of this loop -- see ReloadWhileBusySeq's own docstring), and
            # this test deliberately does not try to determine which.
            # Found necessary the hard way: leaving the reference model at
            # whatever it was before reload_seq is fine for the push
            # already drained above (it completed and was captured before
            # the reload's own CTRL write could possibly commit), but
            # WRONG for any LATER push to this same tile once a real
            # closure-run-style poll started actually verifying results --
            # a genuinely-applied reload the reference model never learned
            # about produced real scoreboard mismatches on tile 0 the first
            # time this loop's own results were actually checked. Same fix
            # as MacClusterClosureSeq._reload's own docstring: a second,
            # unambiguous weight load now that the tile is definitely idle
            # (confirmed by the poll above having just run), synced for real.
            settle_seq = WeightLoadSeq(f"reload_settle_{i}", tile=tile)
            await settle_seq.start(self.env.sequencer)
            sb.load_weights(tile, settle_seq.weight_rows)
            cov.load_weights(tile, settle_seq.weight_rows)

        self.env.driver.randomize_backpressure = False
        await Timer(200, unit="ns")   # let the two drain loops + hier monitor settle
        self.drop_objection()
        self._starved = starved
        self._poll_starved = poll_starved

    def report_phase(self):
        sb, cov = self.env.scoreboard, self.env.coverage
        leftover = sum(v for v in sb.expected.values() if v > 0)
        violations = sb.stale_read_violations()
        self.logger.info(
            f"MacClusterRaceAdjacentTest: {self.RECONFIG_ATTEMPTS} reconfig attempts "
            f"({self._starved} entry pushes not accepted within timeout -- EXPECTED to be "
            f"nonzero: ConcurrentEgressReconfigSeq's own drain is only a per-iteration, "
            f"partial mitigation of tile 3's 1-slot exit buffer, not a full fix, by design "
            f"-- see that sequence's own docstring), {self.RELOAD_ATTEMPTS} reload-while-busy "
            f"attempts, {self._poll_starved} verification polls that themselves timed out "
            f"(also EXPECTED to be occasionally nonzero -- the array can stay genuinely "
            f"congested across iterations under this test's own deliberately-heavy racing; "
            f"not a failure signal on its own, but it does mean that push's own result "
            f"contributes to leftover below instead of being individually verified), "
            f"scoreboard {sb.matched} matched / {sb.unexpected} unexpected / "
            f"{leftover} never-drained (every racy sequence above is now followed by a real "
            f"CsrPollSeq poll, so this is usually small -- nonzero from poll timeouts above "
            f"and/or two captures landing on the same tile before a single poll could catch "
            f"both; neither alone is a failure signal, unlike unexpected/stale_read_violations "
            f"below, which now ARE real: exit_ap is genuinely exercised by every one of those "
            f"polls, unlike an earlier version of this test where it was never fed at all), "
            f"stale_read_violations={violations}, "
            f"ingress_mux_contention={cov.cp_ingress_mux_contention.coverage:.0f}%, "
            f"reload_while_busy={cov.cp_reload_while_busy.coverage:.0f}%."
        )
        # unexpected/stale-read violations indicate a real DUT or protocol
        # bug; leftover (never-drained) does not, here -- see docstring.
        if sb.unexpected or violations:
            self.logger.critical(
                f"MacClusterRaceAdjacentTest FAILED: {sb.unexpected} unexpected results, "
                f"stale-read violations {violations}")
            assert False, f"{sb.unexpected} unexpected results, stale-read violations {violations}"


@cocotb.test()
async def test_race_adjacent(dut):
    """Exercises ConcurrentEgressReconfigSeq, ReloadWhileBusySeq's outcome
    classification, and randomized backpressure -- the checkpoint-6 grafts
    the fixed-topology directed test structurally cannot reach."""
    await _reset(dut)
    ConfigDB().set(None, "*", "DUT", dut)
    await uvm_root().run_test("MacClusterRaceAdjacentTest", keep_singletons=True)
