"""MacClusterEnv -- top-level environment: wires sequencer, driver, the
hierarchical monitor, scoreboard and coverage.

Component hierarchy
-------------------
MacClusterEnv
├── sequencer      (uvm_sequencer)
├── driver         (MacClusterDriver)    <- pulls from sequencer
│                                        -> entry_ap, exit_ap (CPU-visible view)
├── hier_mon       (MacClusterHierMonitor) -> ap (RTL-internal ground truth)
├── scoreboard     (MacClusterScoreboard)  <- entry_ap, exit_ap
└── coverage       (MacClusterCoverage)    <- op_ap, entry_ap

Checkpoint 6 build: hier_mon registered in ConfigDB (build_phase is top-down
-- the env's own build_phase, including this set() call, fully completes
before the phase traversal descends into any child's build_phase, so the
driver can retrieve it in its own build_phase regardless of construction
order) so the driver's poll-timing observations and the scoreboard's
stale-read cross-check both reach ground truth without a hand-threaded
constructor argument. Coverage also gains a third channel (hier_sink) for
cp_ingress_mux_contention, and a fourth (poll_observation_sink) for
cp_poll_to_transition_offset.
"""
from pyuvm import uvm_env, uvm_sequencer, ConfigDB

from mac_cluster_driver import MacClusterDriver
from mac_cluster_monitor import MacClusterHierMonitor
from mac_cluster_scoreboard import MacClusterScoreboard
from mac_cluster_coverage import MacClusterCoverage


class MacClusterEnv(uvm_env):
    def build_phase(self):
        self.seqr       = uvm_sequencer("sequencer", self)
        self.hier_mon   = MacClusterHierMonitor("hier_mon", self)
        ConfigDB().set(None, "*", "HIER_MON", self.hier_mon)
        self.driver     = MacClusterDriver("driver", self)
        self.scoreboard = MacClusterScoreboard("scoreboard", self)
        self.coverage   = MacClusterCoverage("coverage", self)

    def connect_phase(self):
        self.driver.seq_item_port.connect(self.seqr.seq_item_export)
        self.driver.entry_ap.connect(self.scoreboard.entry_fifo.analysis_export)
        self.driver.exit_ap.connect(self.scoreboard.exit_fifo.analysis_export)
        self.driver.op_ap.connect(self.coverage.op_sink)
        self.driver.entry_ap.connect(self.coverage.entry_sink)
        self.hier_mon.ap.connect(self.coverage.hier_sink)
        self.driver.poll_observation_ap.connect(self.coverage.poll_observation_sink)

    @property
    def sequencer(self):
        return self.seqr
