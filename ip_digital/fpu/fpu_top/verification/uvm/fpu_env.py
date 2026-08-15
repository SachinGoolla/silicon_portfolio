"""FPUEnv — top-level environment: wires sequencer, driver, monitors, scoreboard, coverage."""
from pyuvm import (
    uvm_env, uvm_sequencer, ConfigDB,
)
from fpu_driver     import FPUDriver
from fpu_monitor    import FPUInputMonitor, FPUOutputMonitor
from fpu_scoreboard import FPUScoreboard
from fpu_coverage   import FPUCoverage


class FPUEnv(uvm_env):
    """
    Component hierarchy
    -------------------
    FPUEnv
    ├── sequencer      (uvm_sequencer)
    ├── driver         (FPUDriver)        ← pulls from sequencer
    ├── input_mon      (FPUInputMonitor)  → scoreboard.input_fifo
    │                                    → coverage
    ├── output_mon     (FPUOutputMonitor) → scoreboard.output_fifo
    └── scoreboard     (FPUScoreboard)
    └── coverage       (FPUCoverage)
    """

    def build_phase(self):
        self.seqr       = uvm_sequencer("sequencer",  self)
        self.driver     = FPUDriver("driver",          self)
        self.input_mon  = FPUInputMonitor("input_mon", self)
        self.output_mon = FPUOutputMonitor("output_mon", self)
        self.scoreboard = FPUScoreboard("scoreboard",  self)
        self.coverage   = FPUCoverage("coverage",      self)

    def connect_phase(self):
        # Driver pulls seq items from sequencer
        self.driver.seq_item_port.connect(self.seqr.seq_item_export)

        # Input monitor feeds scoreboard + coverage
        self.input_mon.ap.connect(self.scoreboard.input_fifo.analysis_export)
        self.input_mon.ap.connect(self.coverage.analysis_export)

        # Output monitor feeds scoreboard
        self.output_mon.ap.connect(self.scoreboard.output_fifo.analysis_export)

    @property
    def sequencer(self):
        return self.seqr
