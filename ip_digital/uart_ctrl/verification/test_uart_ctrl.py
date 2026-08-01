"""
test_uart_ctrl.py — cocotb + pyUVM functional tests for uart_ctrl (Pillar 3)
=============================================================================

Design under test:
  uart_ctrl — APB peripheral UART with TX/RX FSMs, 16× oversampled RX,
  self-contained sync FIFOs, and loopback mode.

Simulation parameters (set by Makefile/p3_functional.py):
  CLK_FREQ=1600, BAUD_RATE=100 → BRDIV_DEFAULT=0 → baud16_tick every clock.
  Bit period = 16 clock cycles.  Full 10-bit frame = 160 cycles.

Timing convention (pre-NBA sampling):
  Signals are captured at RisingEdge (pre-NBA) for APB bus monitoring, which
  matches the RTL's clocked evaluation at posedge PCLK.
  uart_tx serial line uses FallingEdge + cycle counts for bit recovery.

Tests
  test_loopback     pyUVM scoreboard: 4 APB-written bytes appear on uart_tx
  test_frame_error  Direct: inject bad-stop-bit frame, verify SR[4]=FRAME_ERR
  test_tx_watermark Direct: fill TX FIFO → TX_FULL; drain → TX_EMPTY flags
  test_irq          Direct: TX_EMPTY_IE fires irq_o; clears on IER=0
"""

import cocotb
from cocotb.clock    import Clock
from cocotb.triggers import RisingEdge, FallingEdge, ReadOnly

import pyuvm
from pyuvm import (
    uvm_test, uvm_env, uvm_monitor, uvm_scoreboard, uvm_component,
    uvm_analysis_port, uvm_tlm_analysis_fifo, uvm_object,
    ConfigDB
)

# ---------------------------------------------------------------------------
# Constants — must match DUT parameters
# ---------------------------------------------------------------------------
CYCLES_PER_BIT = 16   # baud16_tick every cycle (BRDIV=0; cocotb_sim.mk sets CLK_FREQ=1600, BAUD_RATE=100)
FIFO_DEPTH     = 4    # matches FIFO_DEPTH in cocotb_sim.mk

# APB register offsets
REG_CTRL  = 0x00
REG_BRDIV = 0x04
REG_TDR   = 0x08
REG_RDR   = 0x0C
REG_SR    = 0x10
REG_IER   = 0x14

# SR bit positions
SR_TX_FULL   = 0
SR_TX_EMPTY  = 1
SR_RX_FULL   = 2
SR_RX_EMPTY  = 3
SR_FRAME_ERR = 4
SR_PAR_ERR   = 5
SR_OVR_ERR   = 6

# CTRL bit positions
CTRL_EN      = 0
CTRL_TX_EN   = 1
CTRL_RX_EN   = 2
CTRL_LOOPBACK = 5


# ---------------------------------------------------------------------------
# APB helpers (module-level coroutines)
# ---------------------------------------------------------------------------

async def apb_write(dut, addr, data):
    """2-cycle APB write (SETUP → ACCESS). De-asserts at FallingEdge so the
    ApbTdrMonitor can sample at ReadOnly(ACCESS) before signals go low."""
    await RisingEdge(dut.PCLK)    # T1: pre-SETUP
    dut.PSEL.value    = 1
    dut.PWRITE.value  = 1
    dut.PADDR.value   = addr
    dut.PWDATA.value  = data
    dut.PENABLE.value = 0
    await RisingEdge(dut.PCLK)    # T2: SETUP captured by DUT
    dut.PENABLE.value = 1
    await RisingEdge(dut.PCLK)    # T3: ACCESS (PREADY=1, write occurs)
    # Signals stay asserted through ReadOnly so monitors can sample them.
    await FallingEdge(dut.PCLK)   # T3 falling: safe to de-assert
    dut.PSEL.value    = 0
    dut.PENABLE.value = 0
    dut.PWRITE.value  = 0


async def apb_read(dut, addr):
    """2-cycle APB read; returns PRDATA (registered in SETUP, valid in ACCESS).
    De-asserts at FallingEdge — never inside a ReadOnly phase."""
    await RisingEdge(dut.PCLK)    # T1
    dut.PSEL.value    = 1
    dut.PWRITE.value  = 0
    dut.PADDR.value   = addr
    dut.PENABLE.value = 0
    await RisingEdge(dut.PCLK)    # T2: SETUP — DUT registers PRDATA
    dut.PENABLE.value = 1
    await RisingEdge(dut.PCLK)    # T3: ACCESS — PREADY=1
    await ReadOnly()               # PRDATA stable (registered at T2 NBA)
    val = int(dut.PRDATA.value)
    await FallingEdge(dut.PCLK)   # T3 falling — de-assert (not ReadOnly)
    dut.PSEL.value    = 0
    dut.PENABLE.value = 0
    return val


async def wait_sr_bit_clear(dut, bit_idx, timeout=5000):
    """Poll SR until bit_idx is 0 (e.g. RX_EMPTY cleared → data arrived)."""
    for _ in range(timeout):
        sr = await apb_read(dut, REG_SR)
        if not (sr >> bit_idx) & 1:
            return sr
    raise AssertionError(f"Timeout: SR[{bit_idx}] never cleared")


async def wait_sr_bit_set(dut, bit_idx, timeout=5000):
    """Poll SR until bit_idx is 1 (e.g. TX_EMPTY set → TX drained)."""
    for _ in range(timeout):
        sr = await apb_read(dut, REG_SR)
        if (sr >> bit_idx) & 1:
            return sr
    raise AssertionError(f"Timeout: SR[{bit_idx}] never set")


async def reset_dut(dut):
    dut.PRESETn.value = 0
    dut.PSEL.value    = 0
    dut.PENABLE.value = 0
    dut.PWRITE.value  = 0
    dut.PADDR.value   = 0
    dut.PWDATA.value  = 0
    dut.uart_rx.value = 1   # idle high
    for _ in range(4):
        await RisingEdge(dut.PCLK)
    dut.PRESETn.value = 1
    await RisingEdge(dut.PCLK)


async def send_uart_frame(dut, data, bad_stop=False):
    """Drive uart_rx with a UART frame (LSB-first, CYCLES_PER_BIT per bit)."""
    dut.uart_rx.value = 1
    await RisingEdge(dut.PCLK)
    # Start bit
    dut.uart_rx.value = 0
    for _ in range(CYCLES_PER_BIT):
        await RisingEdge(dut.PCLK)
    # 8 data bits, LSB first
    for i in range(8):
        dut.uart_rx.value = (data >> i) & 1
        for _ in range(CYCLES_PER_BIT):
            await RisingEdge(dut.PCLK)
    # Stop bit
    dut.uart_rx.value = 0 if bad_stop else 1
    for _ in range(CYCLES_PER_BIT):
        await RisingEdge(dut.PCLK)
    # Return to idle
    dut.uart_rx.value = 1
    await RisingEdge(dut.PCLK)


# ---------------------------------------------------------------------------
# UVM transactions
# ---------------------------------------------------------------------------

class UartItem(uvm_object):
    def __init__(self, name="uart_item"):
        super().__init__(name)
        self.data = 0


# ---------------------------------------------------------------------------
# APB TDR write monitor — captures bytes written to TDR via APB
# ---------------------------------------------------------------------------

class ApbTdrMonitor(uvm_monitor):
    def build_phase(self):
        self.ap = uvm_analysis_port("ap", self)

    async def run_phase(self):
        dut = cocotb.top
        while True:
            await RisingEdge(dut.PCLK)
            # Sample immediately at RisingEdge (before delta cycles).
            # apb_write sets PENABLE=1 AFTER T2's rising edge in a delta cycle,
            # so at T2's rising-edge sample PENABLE=0 (no capture) and at T3
            # PENABLE=1 is already stable (one full cycle settled). ReadOnly()
            # would incorrectly see PENABLE=1 at T2 (double-capture bug).
            psel    = int(dut.PSEL.value)
            penable = int(dut.PENABLE.value)
            pwrite  = int(dut.PWRITE.value)
            paddr   = int(dut.PADDR.value)
            pwdata  = int(dut.PWDATA.value)
            if psel and penable and pwrite and paddr == REG_TDR:
                item = UartItem("mon_tdr")
                item.data = pwdata & 0xFF
                self.ap.write(item)


# ---------------------------------------------------------------------------
# uart_tx serial-line monitor — reconstructs bytes from the serial bit stream
# ---------------------------------------------------------------------------

class UartTxLineMonitor(uvm_monitor):
    def build_phase(self):
        self.ap = uvm_analysis_port("ap", self)

    async def run_phase(self):
        dut = cocotb.top
        while True:
            # Wait for start bit (falling edge on uart_tx)
            await FallingEdge(dut.uart_tx)
            # Advance 8 cycles to reach mid-start-bit (BRDIV=0 → 1 tick/cycle)
            for _ in range(8):
                await RisingEdge(dut.PCLK)
            await ReadOnly()
            if int(dut.uart_tx.value) != 0:
                continue   # glitch — not a real start bit
            # Sample 8 data bits, one per 16-cycle bit period
            byte_val = 0
            for bit_idx in range(8):
                for _ in range(CYCLES_PER_BIT):
                    await RisingEdge(dut.PCLK)
                await ReadOnly()
                byte_val |= int(dut.uart_tx.value) << bit_idx
            item = UartItem("mon_tx_line")
            item.data = byte_val
            self.ap.write(item)


# ---------------------------------------------------------------------------
# Scoreboard — matches TDR writes to TX serial output in order
# ---------------------------------------------------------------------------

class UartScoreboard(uvm_component):
    def build_phase(self):
        self.tdr_fifo = uvm_tlm_analysis_fifo("tdr_fifo", self)
        self.tx_fifo  = uvm_tlm_analysis_fifo("tx_fifo",  self)
        self.tdr_export = self.tdr_fifo.analysis_export
        self.tx_export  = self.tx_fifo.analysis_export
        self._checks    = 0
        self._errors    = 0

    async def run_phase(self):
        while True:
            tdr = await self.tdr_fifo.get()
            tx  = await self.tx_fifo.get()
            if tdr.data != tx.data:
                self.logger.error(
                    f"Mismatch #{self._checks}: "
                    f"TDR wrote 0x{tdr.data:02X}, TX line saw 0x{tx.data:02X}"
                )
                self._errors += 1
            else:
                self.logger.info(f"Check #{self._checks}: 0x{tdr.data:02X} OK")
            self._checks += 1


# ---------------------------------------------------------------------------
# Environment
# ---------------------------------------------------------------------------

class UartEnv(uvm_env):
    def build_phase(self):
        self.tdr_mon   = ApbTdrMonitor.create("tdr_mon", self)
        self.tx_mon    = UartTxLineMonitor.create("tx_mon", self)
        self.scoreboard = UartScoreboard.create("scoreboard", self)

    def connect_phase(self):
        self.tdr_mon.ap.connect(self.scoreboard.tdr_export)
        self.tx_mon.ap.connect(self.scoreboard.tx_export)


# ---------------------------------------------------------------------------
# Base test
# ---------------------------------------------------------------------------

class BaseTest(uvm_test):
    def build_phase(self):
        self.env = UartEnv.create("env", self)


# ---------------------------------------------------------------------------
# Scoreboard polling helper
# ---------------------------------------------------------------------------

async def _wait_scoreboard(dut, sb, n, timeout_cycles=10000):
    for _ in range(timeout_cycles):
        if sb._checks >= n:
            return
        await RisingEdge(dut.PCLK)
    raise AssertionError(f"Scoreboard timeout: expected {n} checks, got {sb._checks}")


# ===========================================================================
# TEST 1: Loopback — 4 bytes written to TDR must appear on uart_tx line
# ===========================================================================

@pyuvm.test()
class test_loopback(BaseTest):
    """Enable loopback, write 4 bytes, verify uart_tx reproduces them."""
    N = 4
    DATA = [0xDE, 0xAD, 0xBE, 0xEF]

    async def run_phase(self):
        dut = cocotb.top
        self.raise_objection()

        cocotb.start_soon(Clock(dut.PCLK, 10, unit="ns").start())
        await reset_dut(dut)

        # Enable loopback + TX + RX + EN, BRDIV=0 for fast sim
        await apb_write(dut, REG_CTRL,  (1 << CTRL_LOOPBACK) |
                                         (1 << CTRL_RX_EN)   |
                                         (1 << CTRL_TX_EN)   |
                                         (1 << CTRL_EN))
        await apb_write(dut, REG_BRDIV, 0)

        for b in self.DATA:
            await apb_write(dut, REG_TDR, b)

        await _wait_scoreboard(dut, self.env.scoreboard, self.N)

        assert self.env.scoreboard._errors == 0, \
            f"Scoreboard recorded {self.env.scoreboard._errors} mismatch(es)"
        self.logger.info(f"PASS: {self.N} bytes verified on uart_tx line")
        self.drop_objection()


# ===========================================================================
# TEST 2: Frame error — bad stop bit sets SR[FRAME_ERR]
# ===========================================================================

@pyuvm.test()
class test_frame_error(BaseTest):
    """Inject frame with stop bit = 0; verify FRAME_ERR latches in SR."""

    async def run_phase(self):
        dut = cocotb.top
        self.raise_objection()

        cocotb.start_soon(Clock(dut.PCLK, 10, unit="ns").start())
        await reset_dut(dut)

        # RX enabled, no loopback (drive uart_rx directly), BRDIV=0
        await apb_write(dut, REG_CTRL,  (1 << CTRL_RX_EN) | (1 << CTRL_EN))
        await apb_write(dut, REG_BRDIV, 0)

        # Inject a frame with bad stop bit
        await send_uart_frame(dut, 0xA5, bad_stop=True)

        # Allow RX FSM to finish and latch error (extra cycles for sync delay)
        for _ in range(32):
            await RisingEdge(dut.PCLK)

        sr = await apb_read(dut, REG_SR)
        assert (sr >> SR_FRAME_ERR) & 1, \
            f"FRAME_ERR (SR[4]) not set after bad-stop-bit frame. SR=0x{sr:08X}"

        # Clear the error flag by writing 1 to SR[4]
        await apb_write(dut, REG_SR, 1 << SR_FRAME_ERR)
        sr = await apb_read(dut, REG_SR)
        assert not (sr >> SR_FRAME_ERR) & 1, \
            f"FRAME_ERR did not clear after SW write. SR=0x{sr:08X}"

        self.logger.info("PASS: FRAME_ERR latched and cleared correctly")
        self.drop_objection()


# ===========================================================================
# TEST 3: TX FIFO watermark — TX_FULL and TX_EMPTY flags
# ===========================================================================

@pyuvm.test()
class test_tx_watermark(BaseTest):
    """Fill TX FIFO → check TX_FULL; re-enable TX and drain → check TX_EMPTY."""

    async def run_phase(self):
        dut = cocotb.top
        self.raise_objection()

        cocotb.start_soon(Clock(dut.PCLK, 10, unit="ns").start())
        await reset_dut(dut)

        # EN + RX_EN only (no TX_EN so bytes sit in FIFO)
        await apb_write(dut, REG_CTRL,  (1 << CTRL_RX_EN) | (1 << CTRL_EN))
        await apb_write(dut, REG_BRDIV, 0)

        # Fill TX FIFO (FIFO_DEPTH=16 slots)
        for i in range(FIFO_DEPTH):
            await apb_write(dut, REG_TDR, i)
        # One extra — should be silently dropped (full)
        await apb_write(dut, REG_TDR, 0xFF)

        sr = await apb_read(dut, REG_SR)
        assert (sr >> SR_TX_FULL) & 1, \
            f"TX_FULL not set after writing {FIFO_DEPTH} bytes. SR=0x{sr:08X}"
        assert not (sr >> SR_TX_EMPTY) & 1, \
            f"TX_EMPTY unexpectedly set. SR=0x{sr:08X}"

        # Enable TX + loopback to drain
        await apb_write(dut, REG_CTRL,
                        (1 << CTRL_LOOPBACK) |
                        (1 << CTRL_RX_EN)    |
                        (1 << CTRL_TX_EN)    |
                        (1 << CTRL_EN))

        await wait_sr_bit_set(dut, SR_TX_EMPTY, timeout=50000)
        sr = await apb_read(dut, REG_SR)
        assert (sr >> SR_TX_EMPTY) & 1, \
            f"TX_EMPTY not set after draining FIFO. SR=0x{sr:08X}"

        self.logger.info("PASS: TX_FULL and TX_EMPTY flags correct")
        self.drop_objection()


# ===========================================================================
# TEST 4: IRQ — TX_EMPTY_IE asserts irq_o; deasserts when IER cleared
# ===========================================================================

@pyuvm.test()
class test_irq(BaseTest):
    """TX_EMPTY_IE: irq_o asserts when FIFO drains; deasserts on IER=0."""

    async def run_phase(self):
        dut = cocotb.top
        self.raise_objection()

        cocotb.start_soon(Clock(dut.PCLK, 10, unit="ns").start())
        await reset_dut(dut)

        # Loopback + all enables + BRDIV=0
        await apb_write(dut, REG_CTRL,
                        (1 << CTRL_LOOPBACK) |
                        (1 << CTRL_RX_EN)    |
                        (1 << CTRL_TX_EN)    |
                        (1 << CTRL_EN))
        await apb_write(dut, REG_BRDIV, 0)
        # Enable TX_EMPTY interrupt
        await apb_write(dut, REG_IER, 1)

        # Send one byte — TX_EMPTY=0 while transmitting → irq_o=0
        await apb_write(dut, REG_TDR, 0x5A)

        # Wait for TX to drain (TX_EMPTY=1)
        await wait_sr_bit_set(dut, SR_TX_EMPTY, timeout=10000)

        await RisingEdge(dut.PCLK)
        await ReadOnly()
        assert int(dut.irq_o.value) == 1, \
            "irq_o not asserted after TX_EMPTY with TX_EMPTY_IE=1"

        # Clear IER — irq_o must deassert
        await apb_write(dut, REG_IER, 0)
        await RisingEdge(dut.PCLK)
        await ReadOnly()
        assert int(dut.irq_o.value) == 0, \
            "irq_o still asserted after IER cleared"

        self.logger.info("PASS: TX_EMPTY_IE / irq_o correct")
        self.drop_objection()
