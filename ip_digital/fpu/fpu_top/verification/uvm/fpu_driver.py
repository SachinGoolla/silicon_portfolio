"""FPUDriver — drives fpu_top input signals from seq_item stream."""
from cocotb.triggers import RisingEdge
from pyuvm import uvm_driver, ConfigDB


class FPUDriver(uvm_driver):
    """
    Pulls FPUSeqItem from seq_item_port, drives all DUT input signals,
    and waits for the DUT to be ready (ready_o) before each transaction.
    """

    def build_phase(self):
        self.dut = ConfigDB().get(self, "", "DUT")

    async def run_phase(self):
        self.dut.valid_i.value   = 0
        self.dut.op_i.value      = 0
        self.dut.src_a_i.value   = 0
        self.dut.src_b_i.value   = 0
        self.dut.src_c_i.value   = 0
        self.dut.int_src_i.value = 0
        self.dut.rm_i.value      = 0
        self.dut.fmt_i.value     = 0   # FP32

        while True:
            item = await self.seq_item_port.get_next_item()
            await self._drive(item)
            self.seq_item_port.item_done()

    async def _drive(self, item):
        # Sync to a rising edge first so all subsequent writes land in the
        # post-edge quiet period and are guaranteed to be seen by the NEXT edge.
        await RisingEdge(self.dut.clk)

        # Wait until DUT is ready (busy_o de-asserted)
        for _ in range(200):
            if int(self.dut.ready_o.value):
                break
            await RisingEdge(self.dut.clk)
        else:
            raise RuntimeError("FPUDriver: DUT never became ready (timeout 200 cycles)")

        self.dut.op_i.value      = item.op
        self.dut.src_a_i.value   = item.src_a
        self.dut.src_b_i.value   = item.src_b
        self.dut.src_c_i.value   = item.src_c
        self.dut.int_src_i.value = item.int_src
        self.dut.rm_i.value      = item.rm
        self.dut.fmt_i.value     = 0   # FP32
        self.dut.valid_i.value   = 1

        await RisingEdge(self.dut.clk)
        self.dut.valid_i.value = 0

        # Wait for valid_o — ensures one transaction at a time through the DUT.
        # This keeps the input/output FIFOs in the scoreboard aligned (1:1 pairing).
        for _ in range(200):
            await RisingEdge(self.dut.clk)
            if int(self.dut.valid_o.value):
                return
        raise RuntimeError("FPUDriver: valid_o never asserted (timeout 200 cycles)")
