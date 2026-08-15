"""mac_cluster functional coverage groups -- same hand-rolled CoverPoint
shape as ip_digital/fpu/fpu_top/verification/uvm/fpu_coverage.py (a dict-
of-bins counter with .sample()/.coverage/.report()), not cocotb-coverage's
decorator API. See the Phase 4 plan §2 for why: this repo already has a
working, zero-dependency precedent for exactly this problem, found by
reading fpu_coverage.py's actual source rather than assuming from its
directory listing.

Checkpoint 6 adds the two grafted, highest-value race-adjacent bins:
cp_ingress_mux_contention (sampled from the hierarchical monitor -- zero-
covered by every existing directed test, since producer/consumer tiles are
always disjoint there) and cp_poll_to_transition_offset (sampled from the
driver's own poll-timing observations -- {-1,0,+1} is Bug 4's actual
danger zone).

cp_poll_to_transition_offset's negative buckets ("<=-3","-2","-1") are
STRUCTURALLY UNREACHABLE as currently wired, not just empirically hard to
hit -- found by an adversarial review, confirmed by re-reading the actual
computation: _do_poll_exit (mac_cluster_driver.py) only ever samples an
offset AFTER observing EXIT_VALID=1, i.e. at-or-after the real toggle
already happened (hier_mon.last_toggle_time_ns[tile] only ever records a
PAST toggle -- mac_cluster_monitor.py's run_phase only assigns it when
exit_seq_q has already changed). Since simulation time is monotonically
non-decreasing, `now_ns - last_toggle_time_ns[tile]` can never be
negative from this specific computation -- "how long AFTER the transition
did this poll first see it" cannot express "before." Closing this for real
would need the driver to also record and retroactively bucket poll
ATTEMPTS that observed EXIT_VALID=0 relative to the transition that
follows them (not yet built -- a real, scoped-out redesign, not a
tuning problem). Documented here rather than left as a misleading "just
needs more/better-randomized traffic" claim, which an earlier version of
this docstring made.
"""
from pyuvm import uvm_component, uvm_analysis_export

from mac_cluster_seq_item import (
    OP_WEIGHT_LOAD, OP_ENTRY_PUSH, OP_POLL_EXIT, OP_RAW_CSR_WRITE, OP_RAW_CSR_READ,
    WEIGHT_CLASSES,
)
from mac_cluster_ref import golden_matmul, golden_requant, tile_of


class _AnalysisImp(uvm_analysis_export):
    """A real uvm_analysis_export forwarding write() to a callback -- the
    exact pattern pyuvm's own uvm_subscriber.analysis_export uses
    internally (pyuvm.s13_predefined_component_classes.uvm_subscriber's
    nested uvm_AnalysisImp), copied here because uvm_subscriber only
    exposes ONE built-in analysis_export and this component needs two
    independent input channels (op-level and entry-level events).
    connect() enforces isinstance(export, uvm_export_base) -- a plain
    duck-typed write()-having object, tried first, is rejected."""

    def __init__(self, name, parent, write_fn):
        super().__init__(name, parent)
        self.write_fn = write_fn

    def write(self, item):
        self.write_fn(item)


class CoverPoint:
    """Simple bin-based coverage counter -- same shape as fpu_coverage.py's
    own CoverPoint, reused verbatim rather than reinvented."""

    def __init__(self, name: str, bins: dict):
        self.name = name
        self.bins = {k: 0 for k in bins}
        self._keys = bins

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
            lines.append(f"    [{label}]: {self.bins[key]} hits")
        return "\n".join(lines)


OPS = [OP_WEIGHT_LOAD, OP_ENTRY_PUSH, OP_POLL_EXIT, OP_RAW_CSR_WRITE, OP_RAW_CSR_READ]
TILES = [0, 1, 2, 3]

REQ_POS_SAT, REQ_NEG_SAT, REQ_POS_INRANGE, REQ_NEG_INRANGE, REQ_ZERO = (
    "pos_sat", "neg_sat", "pos_inrange", "neg_inrange", "zero")

RELOAD_DROPPED, RELOAD_APPLIED = "attempted_dropped", "attempted_applied"

CONTENTION_SEEN, CONTENTION_NOT_SEEN = "contention_seen", "no_contention"

OFFSET_BUCKETS = ["<=-3", "-2", "-1", "0", "+1", "+2", ">=+3"]


def _bucket_offset(cycles):
    if cycles <= -3: return "<=-3"
    if cycles >= 3:  return ">=+3"
    return {-2: "-2", -1: "-1", 0: "0", 1: "+1", 2: "+2"}[cycles]


class MacClusterCoverage(uvm_component):
    """Four independent analysis exports (op_sink, entry_sink, hier_sink,
    poll_observation_sink) -- the env connects the driver's/hier_mon's
    analysis ports directly to these (mac_cluster_env.py), not through
    uvm_subscriber's single built-in export, since this component needs
    more than one independent input channel."""

    def build_phase(self):
        self.op_sink    = _AnalysisImp("op_sink", self, self._on_op)
        self.entry_sink = _AnalysisImp("entry_sink", self, self._on_entry)
        self.hier_sink  = _AnalysisImp("hier_sink", self, self._on_hier_sample)
        self.poll_observation_sink = _AnalysisImp(
            "poll_observation_sink", self, self._on_poll_observation)
        self.ref_weights = {}   # tile -> weight_rows, kept in sync by the test (same as scoreboard)

        self.cp_tile = CoverPoint("Tile", {t: f"tile{t}" for t in TILES})
        self.cp_op = CoverPoint("Op", {op: op for op in OPS})
        self.cp_weight_class = CoverPoint("WeightClass", {wc: wc for wc in WEIGHT_CLASSES})
        self.cp_reload_while_busy = CoverPoint("ReloadWhileBusy", {
            RELOAD_DROPPED: RELOAD_DROPPED, RELOAD_APPLIED: RELOAD_APPLIED,
        })
        self.cp_requant_outcome = CoverPoint("RequantOutcome", {
            REQ_POS_SAT: REQ_POS_SAT, REQ_NEG_SAT: REQ_NEG_SAT,
            REQ_POS_INRANGE: REQ_POS_INRANGE, REQ_NEG_INRANGE: REQ_NEG_INRANGE,
            REQ_ZERO: REQ_ZERO,
        })
        cross_bins = {}
        for src in TILES:
            for dx in (0, 1):
                for dy in (0, 1):
                    dst = tile_of(dx, dy)
                    label = f"self{src}" if dst == src else f"{src}->{dst}"
                    cross_bins[(src, dst)] = label
        self.cp_src_dst_tile = CoverPoint("SrcDstTile", cross_bins)
        self.cp_ingress_mux_contention = CoverPoint("IngressMuxContention", {
            CONTENTION_SEEN: CONTENTION_SEEN, CONTENTION_NOT_SEEN: CONTENTION_NOT_SEEN,
        })
        self.cp_poll_to_transition_offset = CoverPoint("PollToTransitionOffset", {
            b: b for b in OFFSET_BUCKETS
        })

    def load_weights(self, tile, weight_rows):
        """Same sync contract as MacClusterScoreboard.load_weights -- the
        test calls both after each real WEIGHT_LOAD completes."""
        self.ref_weights[tile] = [row[:] for row in weight_rows]

    # ── op-level sampling ───────────────────────────────────────────────

    def _on_op(self, op_evt):
        self.cp_tile.sample(op_evt.tile)
        self.cp_op.sample(op_evt.op)
        if op_evt.op == OP_WEIGHT_LOAD and op_evt.weight_class is not None:
            self.cp_weight_class.sample(op_evt.weight_class)

    # ── entry-level sampling (cross + requant outcome) ──────────────────

    def _on_entry(self, entry):
        if entry.mesh_egress_en:
            dst = tile_of(entry.dest_x, entry.dest_y)
        else:
            dst = entry.tile
        self.cp_src_dst_tile.sample((entry.tile, dst))

        if entry.mesh_egress_en and entry.tile in self.ref_weights:
            y = golden_matmul(list(entry.act_vec), self.ref_weights[entry.tile])
            rq = golden_requant(y)
            for v, raw in zip(rq, y):
                shifted = raw >> 4
                if shifted > 127:
                    self.cp_requant_outcome.sample(REQ_POS_SAT)
                elif shifted < -128:
                    self.cp_requant_outcome.sample(REQ_NEG_SAT)
                elif v == 0:
                    self.cp_requant_outcome.sample(REQ_ZERO)
                elif v > 0:
                    self.cp_requant_outcome.sample(REQ_POS_INRANGE)
                else:
                    self.cp_requant_outcome.sample(REQ_NEG_INRANGE)

    def sample_reload_while_busy(self, outcome):
        """Called directly by the test after a ReloadWhileBusySeq attempt
        (checkpoint 6) -- not an analysis-port event, since "was this drop
        silent/correct" is a scoreboard-level judgment made by the test,
        not something the driver alone can classify."""
        self.cp_reload_while_busy.sample(outcome)

    # ── grafted race-adjacent sampling (checkpoint 6) ───────────────────

    def _on_hier_sample(self, sample):
        self.cp_ingress_mux_contention.sample(
            CONTENTION_SEEN if sample.ingress_mux_contention else CONTENTION_NOT_SEEN)

    def _on_poll_observation(self, obs):
        self.cp_poll_to_transition_offset.sample(_bucket_offset(obs.offset_cycles))

    @property
    def _all_covergroups(self):
        return (self.cp_tile, self.cp_op, self.cp_weight_class,
                self.cp_reload_while_busy, self.cp_requant_outcome, self.cp_src_dst_tile,
                self.cp_ingress_mux_contention, self.cp_poll_to_transition_offset)

    @property
    def overall_coverage_pct(self):
        # Unweighted mean across covergroups of very different bin
        # cardinality (2 to 16 bins) -- a known, documented limitation, not
        # an oversight: cp_ingress_mux_contention's own CONTENTION_NOT_SEEN
        # bin is trivially hit on essentially the first sampled clock edge
        # of any test (post-reset, before any traffic, entry_pending_q=0
        # and mesh_in_valid_i=0 for every tile), so that 2-bin covergroup's
        # own .coverage can never read below 50% -- guaranteeing this mean
        # a fixed +6.25 percentage-point floor (50% / 8 covergroups)
        # regardless of whether real ingress-mux contention was ever
        # exercised. A bin-count-weighted mean would represent "fraction
        # of the total verification space covered" more faithfully; not
        # changed here to avoid altering what --uvm-coverage-threshold
        # gates on without a full re-validation. Read each covergroup's
        # own .report() line, not just this aggregate, when the actual
        # closure story matters.
        cps = self._all_covergroups
        return sum(cp.coverage for cp in cps) / len(cps)

    def report_phase(self):
        for cp in self._all_covergroups:
            self.logger.info(cp.report())
        self.logger.info(f"  Overall (mean of covergroups): {self.overall_coverage_pct:.1f}%")
