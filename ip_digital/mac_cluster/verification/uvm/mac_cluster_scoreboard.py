"""MacClusterScoreboard -- multiset comparison, not FIFO-paired 1:1.

Randomized producers can legitimately produce duplicate result tuples (two
distinct pushes to the same destination can share a golden result), so the
directed test's own `got_a != got_b` idiom does not generalize -- this
scoreboard compares expected vs. observed (dest_tile, result_tuple)
multisets instead, generalizing test_two_producer_chain's own
`seen == {golden_Y3a, golden_Y3b}` pattern from 2 fixed producers to N.

Entries and exits arrive on independent analysis ports and are drained by
two concurrently-running loops (not lockstep FIFO pairing like fpu_top's
own scoreboard uses) -- exit order/count timing relative to entries is not
assumed 1:1 sequential once traffic is randomized.

The independent stale-read detector cross-checks the hierarchical monitor's
RTL-internal ground truth (mac_cluster_monitor.py's toggle_count[tile] --
how many times exit_seq_q genuinely changed) against how many DISTINCT
fresh captures the driver's CPU-visible protocol accepted for that tile.
accepted_count[tile] > toggle_count[tile] would mean the driver's own
exit_seq discriminator was fooled at least once into accepting a repeat --
exactly the Bug-4 class an end-state-only multiset comparison would
silently hide (the multiset could still balance even if two accepted
captures were actually the SAME underlying RTL result counted twice,
provided some other genuinely-distinct result went uncounted to
compensate). This is real ground truth, not a second look at the same
data: toggle_count comes from a monitor that never touches the AXI bus.
"""
import cocotb
from collections import Counter
from pyuvm import uvm_scoreboard, uvm_tlm_analysis_fifo, ConfigDB

from mac_cluster_ref import MacClusterRefModel


class MacClusterScoreboard(uvm_scoreboard):
    def build_phase(self):
        self.entry_fifo = uvm_tlm_analysis_fifo("entry_fifo", self)
        self.exit_fifo  = uvm_tlm_analysis_fifo("exit_fifo", self)
        self.ref_model  = MacClusterRefModel()
        self.hier_mon   = ConfigDB().get(self, "", "HIER_MON", default=None)
        self.expected = Counter()   # (dest_tile, result_tuple) -> outstanding count
        self.accepted_count = Counter()   # tile -> driver-accepted fresh-capture count
        self.matched  = 0
        self.unexpected = 0

    def load_weights(self, tile, weight_rows):
        """Called directly by the test right after a WEIGHT_LOAD completes
        -- configuration, not stream traffic, so it doesn't need an
        analysis-port event of its own; keeps the reference model's
        per-tile state in sync with what was actually loaded."""
        self.ref_model.load_weights(tile, weight_rows)

    async def run_phase(self):
        cocotb.start_soon(self._drain_exits())
        await self._drain_entries()

    async def _drain_entries(self):
        while True:
            entry = await self.entry_fifo.get()
            self._on_entry(entry)

    async def _drain_exits(self):
        while True:
            exit_evt = await self.exit_fifo.get()
            self._on_exit(exit_evt)

    def _on_entry(self, entry):
        if entry.mesh_egress_en:
            result, dest_tile = self.ref_model.expected_forwarded(
                entry.tile, entry.dest_x, entry.dest_y, entry.act_vec)
        else:
            result, dest_tile = self.ref_model.expected_local(entry.tile, entry.act_vec), entry.tile
        self.expected[(dest_tile, tuple(result))] += 1

    def _on_exit(self, exit_evt):
        self.accepted_count[exit_evt.tile] += 1
        key = (exit_evt.tile, tuple(exit_evt.result))
        if self.expected[key] > 0:
            self.expected[key] -= 1
            self.matched += 1
            self.logger.debug(f"OK {key}")
        else:
            self.unexpected += 1
            msg = f"SCOREBOARD FAIL: observed {key} not in expected multiset"
            self.logger.error(msg)
            cocotb.log.error(msg)

    def stale_read_violations(self):
        """tile -> (accepted_count, toggle_count) for every tile where the
        driver accepted MORE fresh captures than the RTL ground truth ever
        produced. Empty dict if hier_mon wasn't wired (e.g. an older test
        still using an env built before checkpoint 6) or if none found."""
        if self.hier_mon is None:
            return {}
        violations = {}
        for tile, accepted in self.accepted_count.items():
            toggles = self.hier_mon.toggle_count.get(tile, 0)
            if accepted > toggles:
                violations[tile] = (accepted, toggles)
        return violations

    def report_phase(self):
        leftover = sum(v for v in self.expected.values() if v > 0)
        self.logger.info(
            f"Scoreboard: {self.matched} matched, {self.unexpected} unexpected, "
            f"{leftover} expected result(s) never arrived"
        )
        violations = self.stale_read_violations()
        if violations:
            self.logger.critical(f"STALE-READ DETECTOR: {violations} -- driver accepted "
                                   f"more fresh captures than exit_seq_q ever toggled")
        if self.unexpected or leftover:
            self.logger.error(
                "SCOREBOARD: mismatches or missing results detected -- "
                "DUT has bugs (or a traffic pattern outside this reference "
                "model's single-hop scope was generated)!"
            )

    @property
    def failed(self):
        return (self.unexpected + sum(v for v in self.expected.values() if v > 0)
                + len(self.stale_read_violations()))
