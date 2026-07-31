"""
test_async_fifo.py — pyUVM Functional Tests for async_fifo (Pillar 3)
======================================================================

UVM HIERARCHY:
  AsyncFIFOEnv         — top-level env
    WrAgent            — WriteDriver + WrMonitor + uvm_sequencer
    RdAgent            — RdDriver + RdMonitor + uvm_sequencer
    AsyncFIFOScoreboard — in-order FIFO integrity via uvm_tlm_analysis_fifo

TESTS:
  FillDrainTest  — fill FIFO, assert full, drain, assert empty, scoreboard checks data
  BackpressureTest — N=16 concurrent wr/rd, writer 3× faster (clock ratio)
  StressTest     — N=32 random data, fully concurrent wr+rd
  test_no_spurious_read — direct cocotb test, rd_en=0, verifies rd_bin stays 0

TIMING:
  wr_clk = 10 ns, rd_clk = 30 ns (3 : 1 ratio).
  Monitors sample on posedge + ReadOnly() to see settled NBA values.
  Drivers write on FallingEdge() (midcycle active phase) to avoid ReadOnly conflicts.
"""

import random

import cocotb
from cocotb.clock    import Clock
from cocotb.triggers import RisingEdge, FallingEdge, ReadOnly

from pyuvm import (
    uvm_object, uvm_sequence_item, uvm_driver, uvm_monitor,
    uvm_agent, uvm_env, uvm_scoreboard, uvm_sequence,
    uvm_test, uvm_component, uvm_analysis_port,
    uvm_tlm_analysis_fifo, uvm_sequencer,
    ConfigDB, uvm_root,
)

# ─────────────────────────────────────────────────────────────────────────────
# RTL parameters (must match DUT defaults)
# ─────────────────────────────────────────────────────────────────────────────
DATA_W       = 32
DEPTH        = 8
WR_PERIOD_NS = 10
RD_PERIOD_NS = 30


# ─────────────────────────────────────────────────────────────────────────────
# Configuration
# ─────────────────────────────────────────────────────────────────────────────
class AsyncFIFOConfig(uvm_object):
    def __init__(self, name="AsyncFIFOConfig"):
        super().__init__(name)
        self.depth = DEPTH


# ─────────────────────────────────────────────────────────────────────────────
# Sequence items
# ─────────────────────────────────────────────────────────────────────────────
class WrItem(uvm_sequence_item):
    def __init__(self, name="WrItem"):
        super().__init__(name)
        self.data = 0


class RdItem(uvm_sequence_item):
    """Read trigger. Monitor fills in data."""
    def __init__(self, name="RdItem"):
        super().__init__(name)
        self.data = 0


# ─────────────────────────────────────────────────────────────────────────────
# Drivers
# ─────────────────────────────────────────────────────────────────────────────
class WriteDriver(uvm_driver):
    async def run_phase(self):
        dut = cocotb.top
        dut.wr_en.value   = 0
        dut.wr_data.value = 0
        while True:
            item = await self.seq_item_port.get_next_item()
            while int(dut.full.value):        # stall until FIFO has room
                await RisingEdge(dut.wr_clk)
            await FallingEdge(dut.wr_clk)    # active phase: safe to drive
            dut.wr_en.value   = 1
            dut.wr_data.value = item.data
            await RisingEdge(dut.wr_clk)     # write latches on posedge
            await FallingEdge(dut.wr_clk)
            dut.wr_en.value   = 0
            self.seq_item_port.item_done()


class RdDriver(uvm_driver):
    async def run_phase(self):
        dut = cocotb.top
        dut.rd_en.value = 0
        while True:
            item = await self.seq_item_port.get_next_item()
            while int(dut.empty.value):       # stall until FIFO has data
                await RisingEdge(dut.rd_clk)
            await FallingEdge(dut.rd_clk)
            dut.rd_en.value = 1
            await RisingEdge(dut.rd_clk)
            await FallingEdge(dut.rd_clk)
            dut.rd_en.value = 0
            self.seq_item_port.item_done()


# ─────────────────────────────────────────────────────────────────────────────
# Monitors
# ─────────────────────────────────────────────────────────────────────────────
class WrMonitor(uvm_monitor):
    def build_phase(self):
        self.ap = uvm_analysis_port("ap", self)

    async def run_phase(self):
        dut = cocotb.top
        while True:
            await RisingEdge(dut.wr_clk)
            # Sample pre-NBA: wr_gray/full haven't updated yet, so this matches
            # the RTL's `if (wr_en && !full)` condition that decides the write.
            wr_en = int(dut.wr_en.value)
            full  = int(dut.full.value)
            data  = int(dut.wr_data.value)
            await ReadOnly()
            if wr_en and not full:
                item      = WrItem("mon_wr")
                item.data = data
                self.ap.write(item)


class RdMonitor(uvm_monitor):
    """rd_data is registered — valid the cycle AFTER rd_en=1 && !empty."""
    def build_phase(self):
        self.ap = uvm_analysis_port("ap", self)

    async def run_phase(self):
        dut = cocotb.top
        prev_rd_en = 0
        prev_empty = 1
        while True:
            await RisingEdge(dut.rd_clk)
            # Sample pre-NBA: rd_gray/empty haven't updated yet — correct
            # read condition (same as RTL `if (rd_en && !empty)` at posedge).
            cur_rd_en = int(dut.rd_en.value)
            cur_empty = int(dut.empty.value)
            await ReadOnly()
            if prev_rd_en and not prev_empty:
                item      = RdItem("mon_rd")
                item.data = int(dut.rd_data.value)
                self.ap.write(item)
            prev_rd_en = cur_rd_en
            prev_empty = cur_empty


# ─────────────────────────────────────────────────────────────────────────────
# Agents
# ─────────────────────────────────────────────────────────────────────────────
class WrAgent(uvm_agent):
    def build_phase(self):
        self.seqr    = uvm_sequencer("wr_seqr", self)
        self.driver  = WriteDriver("wr_driver", self)
        self.monitor = WrMonitor("wr_monitor", self)

    def connect_phase(self):
        self.driver.seq_item_port.connect(self.seqr.seq_item_export)


class RdAgent(uvm_agent):
    def build_phase(self):
        self.seqr    = uvm_sequencer("rd_seqr", self)
        self.driver  = RdDriver("rd_driver", self)
        self.monitor = RdMonitor("rd_monitor", self)

    def connect_phase(self):
        self.driver.seq_item_port.connect(self.seqr.seq_item_export)


# ─────────────────────────────────────────────────────────────────────────────
# Scoreboard — FIFO-order integrity check
# ─────────────────────────────────────────────────────────────────────────────
class AsyncFIFOScoreboard(uvm_scoreboard):
    def build_phase(self):
        # Analysis FIFOs: monitors write here; run_phase reads in order
        self.wr_fifo = uvm_tlm_analysis_fifo("wr_fifo", self)
        self.rd_fifo = uvm_tlm_analysis_fifo("rd_fifo", self)
        self._errors = 0
        self._checks = 0

    async def run_phase(self):
        while True:
            wr = await self.wr_fifo.queue.get()
            rd = await self.rd_fifo.queue.get()
            self._checks += 1
            if wr.data != rd.data:
                self._errors += 1
                self.logger.error(
                    f"#{self._checks}: wrote 0x{wr.data:08x}  got 0x{rd.data:08x}")
            else:
                self.logger.info(
                    f"#{self._checks}: 0x{wr.data:08x} OK")

    def check_phase(self):
        if self._errors:
            raise AssertionError(
                f"Scoreboard: {self._errors}/{self._checks} data integrity failures")
        self.logger.info(f"All {self._checks} FIFO transfers verified in order")


# ─────────────────────────────────────────────────────────────────────────────
# Environment
# ─────────────────────────────────────────────────────────────────────────────
class AsyncFIFOEnv(uvm_env):
    def build_phase(self):
        self.wr_agent   = WrAgent("wr_agent", self)
        self.rd_agent   = RdAgent("rd_agent", self)
        self.scoreboard = AsyncFIFOScoreboard("scoreboard", self)

    def connect_phase(self):
        # Connect monitor analysis ports to scoreboard analysis FIFOs
        self.wr_agent.monitor.ap.connect(self.scoreboard.wr_fifo.analysis_export)
        self.rd_agent.monitor.ap.connect(self.scoreboard.rd_fifo.analysis_export)


# ─────────────────────────────────────────────────────────────────────────────
# Sequences
# ─────────────────────────────────────────────────────────────────────────────
class FillSeq(uvm_sequence):
    def __init__(self, name="FillSeq", n=DEPTH, base=0xA0000000):
        super().__init__(name)
        self.n    = n
        self.base = base

    async def body(self):
        for i in range(self.n):
            item      = WrItem(f"wr{i}")
            item.data = (self.base + i) & 0xFFFF_FFFF
            await self.start_item(item)
            await self.finish_item(item)


class DrainSeq(uvm_sequence):
    def __init__(self, name="DrainSeq", n=DEPTH):
        super().__init__(name)
        self.n = n

    async def body(self):
        for i in range(self.n):
            item = RdItem(f"rd{i}")
            await self.start_item(item)
            await self.finish_item(item)


class RandomWrSeq(uvm_sequence):
    def __init__(self, name="RandomWrSeq", n=16):
        super().__init__(name)
        self.n = n

    async def body(self):
        for i in range(self.n):
            item      = WrItem(f"rwr{i}")
            item.data = random.randint(0, 0xFFFF_FFFF)
            await self.start_item(item)
            await self.finish_item(item)


# ─────────────────────────────────────────────────────────────────────────────
# UVM Tests
# ─────────────────────────────────────────────────────────────────────────────
async def _wait_scoreboard(dut, sb, n, clk, timeout_cycles=200):
    """Poll until scoreboard has seen exactly n checks, or fail on timeout."""
    for _ in range(timeout_cycles):
        if sb._checks >= n:
            return
        await RisingEdge(clk)
    raise AssertionError(
        f"Scoreboard timeout: expected {n} checks, got {sb._checks}")


class FillDrainTest(uvm_test):
    def build_phase(self):
        self.env = AsyncFIFOEnv("env", self)

    async def run_phase(self):
        self.raise_objection()
        dut     = cocotb.top
        wr_seqr = self.env.wr_agent.seqr
        rd_seqr = self.env.rd_agent.seqr

        # Write DEPTH items (fills FIFO)
        fill = FillSeq("fill", n=DEPTH, base=0x10000000)
        await fill.start(wr_seqr)

        # Wait for full flag to propagate through synchroniser (≥ SYNC_STAGES cycles)
        for _ in range(6):
            await RisingEdge(dut.wr_clk)
        await ReadOnly()
        assert int(dut.full.value) == 1, "Expected full=1 after DEPTH writes"

        # Read back all items
        drain = DrainSeq("drain", n=DEPTH)
        await drain.start(rd_seqr)

        # Flush pipeline: rd_data is registered, scoreboard needs 1 more rd_clk
        await _wait_scoreboard(dut, self.env.scoreboard, DEPTH, dut.rd_clk)

        # Verify empty propagates
        for _ in range(8):
            await RisingEdge(dut.rd_clk)
        await ReadOnly()
        assert int(dut.empty.value) == 1, "Expected empty=1 after full drain"
        self.drop_objection()

    def check_phase(self):
        sb = self.env.scoreboard
        assert sb._errors == 0, f"{sb._errors} data integrity failures"
        assert sb._checks == DEPTH, f"Expected {DEPTH} scoreboard checks, got {sb._checks}"


class BackpressureTest(uvm_test):
    N = 16

    def build_phase(self):
        self.env = AsyncFIFOEnv("env", self)

    async def run_phase(self):
        self.raise_objection()
        dut     = cocotb.top
        wr_seqr = self.env.wr_agent.seqr
        rd_seqr = self.env.rd_agent.seqr

        fill  = FillSeq("fill",  n=self.N, base=0xB0000000)
        drain = DrainSeq("drain", n=self.N)
        # Concurrent: writer is 3× faster than reader (clock ratio)
        wr_task = cocotb.start_soon(fill.start(wr_seqr))
        rd_task = cocotb.start_soon(drain.start(rd_seqr))
        await wr_task
        await rd_task
        # Flush pipeline
        await _wait_scoreboard(dut, self.env.scoreboard, self.N, dut.rd_clk)
        self.drop_objection()

    def check_phase(self):
        sb = self.env.scoreboard
        assert sb._errors == 0, f"{sb._errors} data integrity failures"
        assert sb._checks == self.N, f"Expected {self.N} checks, got {sb._checks}"


class StressTest(uvm_test):
    N = 32

    def build_phase(self):
        self.env = AsyncFIFOEnv("env", self)

    async def run_phase(self):
        self.raise_objection()
        dut     = cocotb.top
        wr_seqr = self.env.wr_agent.seqr
        rd_seqr = self.env.rd_agent.seqr

        wr = RandomWrSeq("stress_wr", n=self.N)
        rd = DrainSeq("stress_rd",    n=self.N)
        wr_task = cocotb.start_soon(wr.start(wr_seqr))
        rd_task = cocotb.start_soon(rd.start(rd_seqr))
        await wr_task
        await rd_task
        # Flush pipeline
        await _wait_scoreboard(dut, self.env.scoreboard, self.N, dut.rd_clk)
        self.drop_objection()

    def check_phase(self):
        sb = self.env.scoreboard
        assert sb._errors == 0, f"{sb._errors} data integrity failures"
        assert sb._checks == self.N, f"Expected {self.N} checks, got {sb._checks}"


# ─────────────────────────────────────────────────────────────────────────────
# Reset helper
# ─────────────────────────────────────────────────────────────────────────────
async def _reset(dut):
    dut.wr_rst_n.value = 0
    dut.rd_rst_n.value = 0
    dut.wr_en.value    = 0
    dut.rd_en.value    = 0
    dut.wr_data.value  = 0
    for _ in range(4):
        await RisingEdge(dut.wr_clk)
    for _ in range(4):
        await RisingEdge(dut.rd_clk)
    await FallingEdge(dut.wr_clk)
    dut.wr_rst_n.value = 1
    await FallingEdge(dut.rd_clk)
    dut.rd_rst_n.value = 1
    for _ in range(4):
        await RisingEdge(dut.wr_clk)
    for _ in range(4):
        await RisingEdge(dut.rd_clk)


# ─────────────────────────────────────────────────────────────────────────────
# cocotb entry points
# ─────────────────────────────────────────────────────────────────────────────

@cocotb.test()
async def test_fill_drain(dut):
    """Fill FIFO to DEPTH; verify full; drain; verify empty; scoreboard checks data."""
    cocotb.start_soon(Clock(dut.wr_clk, WR_PERIOD_NS, unit="ns").start())
    cocotb.start_soon(Clock(dut.rd_clk, RD_PERIOD_NS, unit="ns").start())
    await _reset(dut)
    await uvm_root().run_test("FillDrainTest")


@cocotb.test()
async def test_backpressure(dut):
    """Concurrent wr+rd, writer 3× faster — verifies full/empty flow control."""
    cocotb.start_soon(Clock(dut.wr_clk, WR_PERIOD_NS, unit="ns").start())
    cocotb.start_soon(Clock(dut.rd_clk, RD_PERIOD_NS, unit="ns").start())
    await _reset(dut)
    await uvm_root().run_test("BackpressureTest")


@cocotb.test()
async def test_no_spurious_read(dut):
    """rd_en=0 while FIFO fills — rd_bin must not advance (no phantom reads)."""
    cocotb.start_soon(Clock(dut.wr_clk, WR_PERIOD_NS, unit="ns").start())
    cocotb.start_soon(Clock(dut.rd_clk, RD_PERIOD_NS, unit="ns").start())
    await _reset(dut)

    dut.rd_en.value = 0
    for i in range(4):
        while int(dut.full.value):
            await RisingEdge(dut.wr_clk)
        await FallingEdge(dut.wr_clk)
        dut.wr_en.value   = 1
        dut.wr_data.value = 0xC000_0000 + i
        await RisingEdge(dut.wr_clk)
        await FallingEdge(dut.wr_clk)
        dut.wr_en.value   = 0

    for _ in range(8):
        await RisingEdge(dut.rd_clk)
    await ReadOnly()
    rd_bin_val = int(dut.rd_bin.value)
    assert rd_bin_val == 0, f"Spurious read: rd_bin={rd_bin_val} expected 0"
    dut._log.info("PASS no spurious reads when rd_en=0")


@cocotb.test()
async def test_stress(dut):
    """32 random data words, concurrent wr+rd — no data loss or misordering."""
    cocotb.start_soon(Clock(dut.wr_clk, WR_PERIOD_NS, unit="ns").start())
    cocotb.start_soon(Clock(dut.rd_clk, RD_PERIOD_NS, unit="ns").start())
    await _reset(dut)
    await uvm_root().run_test("StressTest")
