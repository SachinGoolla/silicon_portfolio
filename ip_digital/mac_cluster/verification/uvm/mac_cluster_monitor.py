"""MacClusterHierMonitor -- the genuinely passive channel of this env.

Samples RTL-internal state hierarchically through mac_cluster.sv's g_tile[]
generate block every clock, independent of anything the driver does. This
is what makes the stale-read detector (mac_cluster_scoreboard.py) and the
race-adjacent coverage bins (mac_cluster_coverage.py) possible: the
driver's own exit_ap only ever reports what the CPU-visible NI_STATUS
register said, which is exactly the channel Bug 4 (see
mac_cluster/REPORT.md) proved can be stale. Comparing this independent
ground truth against the driver's own view is the actual bug-finding
mechanism, not a redundant second look at the same data.

Hierarchical access through the generate block (dut.g_tile[t].u_ni.*) was
confirmed to work under Icarus/cocotb VPI with a real throwaway test run
against the compiled mac_cluster netlist before this file was written --
see the Phase 4 plan's checkpoint 0.
"""
from cocotb.triggers import RisingEdge
from cocotb.utils import get_sim_time
from pyuvm import uvm_monitor, uvm_analysis_port, ConfigDB

NUM_TILES = 4


class HierSample:
    """One tile's internal state, sampled on one clock edge."""
    __slots__ = ("tile", "sim_time_ns", "exit_seq_q", "exit_valid_q",
                 "mesh_in_valid_i", "entry_pending_q", "entry_starve_cnt_q")

    def __init__(self, tile, sim_time_ns, exit_seq_q, exit_valid_q,
                 mesh_in_valid_i, entry_pending_q, entry_starve_cnt_q):
        self.tile = tile
        self.sim_time_ns = sim_time_ns
        self.exit_seq_q = exit_seq_q
        self.exit_valid_q = exit_valid_q
        self.mesh_in_valid_i = mesh_in_valid_i
        self.entry_pending_q = entry_pending_q
        # Phase 5 checkpoint A telemetry -- tile_ni.sv's own fairness
        # counter, ground-truth read (not the CPU-visible view, which has
        # no CSR mirror for this signal at all). Formally bounded by
        # tile_ni_liveness.sby (<= FAIRNESS_LIMIT+1); this is observed-max
        # telemetry, not an assertion -- see MacClusterHierMonitor's own
        # max_starve_cnt tracking below.
        self.entry_starve_cnt_q = entry_starve_cnt_q

    @property
    def ingress_mux_contention(self):
        """True when the mesh and the CPU-entry path both want this tile's
        ingress mux the same cycle -- tile_ni.sv gives the mesh
        unconditional priority (src_is_mesh_q), so this is the condition
        under which entry_pending_q's own service gets delayed. Zero-
        covered by every existing directed test (producer/consumer tiles
        are always disjoint in test_two_producer_chain)."""
        return bool(self.entry_pending_q and self.mesh_in_valid_i)


class MacClusterHierMonitor(uvm_monitor):
    """In addition to publishing HierSample on every edge, tracks (as
    directly-readable public state, not just analysis-port events) two
    things the stale-read detector and cp_poll_to_transition_offset need:
    toggle_count[tile] (how many times exit_seq_q genuinely changed -- the
    real, ground-truth count of fresh results this tile ever produced) and
    last_toggle_time_ns[tile] (for computing a poll's cycle offset from the
    nearest transition)."""

    def build_phase(self):
        self.dut = ConfigDB().get(self, "", "DUT")
        self.ap = uvm_analysis_port("ap", self)
        self.toggle_count = {t: 0 for t in range(NUM_TILES)}
        self.last_toggle_time_ns = {t: 0.0 for t in range(NUM_TILES)}
        self._prev_exit_seq_q = {t: None for t in range(NUM_TILES)}
        self.max_starve_cnt = {t: 0 for t in range(NUM_TILES)}

    async def run_phase(self):
        while True:
            await RisingEdge(self.dut.clk)
            now_ns = get_sim_time(unit="ns")
            for t in range(NUM_TILES):
                ni = getattr(self.dut, "g_tile")[t].u_ni
                exit_seq_q = int(ni.exit_seq_q.value)
                if self._prev_exit_seq_q[t] is not None and exit_seq_q != self._prev_exit_seq_q[t]:
                    self.toggle_count[t] += 1
                    self.last_toggle_time_ns[t] = now_ns
                self._prev_exit_seq_q[t] = exit_seq_q
                starve_cnt = int(ni.entry_starve_cnt_q.value)
                if starve_cnt > self.max_starve_cnt[t]:
                    self.max_starve_cnt[t] = starve_cnt
                self.ap.write(HierSample(
                    tile=t,
                    sim_time_ns=now_ns,
                    exit_seq_q=exit_seq_q,
                    exit_valid_q=int(ni.exit_valid_q.value),
                    mesh_in_valid_i=int(ni.mesh_in_valid_i.value),
                    entry_pending_q=int(ni.entry_pending_q.value),
                    entry_starve_cnt_q=starve_cnt,
                ))
