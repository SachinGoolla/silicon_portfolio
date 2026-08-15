"""FPU monitors — one for input capture, one for output capture."""
from cocotb.triggers import RisingEdge
from pyuvm import uvm_monitor, uvm_analysis_port, ConfigDB


class FPUInputCapture:
    """Lightweight snapshot of the DUT inputs at transaction acceptance."""
    __slots__ = ("op", "src_a", "src_b", "src_c", "int_src", "rm")

    def __init__(self, dut):
        self.op      = int(dut.op_i.value)
        self.src_a   = int(dut.src_a_i.value)
        self.src_b   = int(dut.src_b_i.value)
        self.src_c   = int(dut.src_c_i.value)
        self.int_src = int(dut.int_src_i.value)
        self.rm      = int(dut.rm_i.value)

    @property
    def unit(self):
        return (self.op >> 4) & 0x3


class FPUOutputCapture:
    """Snapshot of DUT output signals when valid_o is asserted."""
    __slots__ = ("result", "int_result", "fflags")

    def __init__(self, dut):
        self.result     = int(dut.result_o.value)
        self.int_result = int(dut.int_result_o.value)
        self.fflags     = int(dut.fflags_o.value)


class FPUInputMonitor(uvm_monitor):
    """Captures inputs at the rising edge where valid_i & ready_o are both asserted."""

    def build_phase(self):
        self.dut = ConfigDB().get(self, "", "DUT")
        self.ap  = uvm_analysis_port("ap", self)

    async def run_phase(self):
        while True:
            await RisingEdge(self.dut.clk)
            try:
                valid = int(self.dut.valid_i.value)
                ready = int(self.dut.ready_o.value)
            except Exception:
                continue
            if valid and ready:
                self.ap.write(FPUInputCapture(self.dut))


class FPUOutputMonitor(uvm_monitor):
    """Captures outputs at the rising edge where valid_o is asserted.

    The seen_valid_i guard ensures stale pipeline outputs from prior test
    phases (before the driver asserts valid_i for the first time) are not
    forwarded to the scoreboard.
    """

    def build_phase(self):
        self.dut = ConfigDB().get(self, "", "DUT")
        self.ap  = uvm_analysis_port("ap", self)

    async def run_phase(self):
        seen_valid_i = False
        while True:
            await RisingEdge(self.dut.clk)
            try:
                valid_i = int(self.dut.valid_i.value)
                valid_o = int(self.dut.valid_o.value)
            except Exception:
                continue
            if valid_i:
                seen_valid_i = True
            if valid_o and seen_valid_i:
                self.ap.write(FPUOutputCapture(self.dut))
