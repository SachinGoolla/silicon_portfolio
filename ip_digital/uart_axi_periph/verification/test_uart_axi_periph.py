"""cocotb test suite for uart_axi_periph.

Drives the AXI4-Lite register interface (same manager tasks as
fpu_axi_periph's own suite) and exercises the full UART stack end-to-end
through an external wire loopback (uart_rx_i <= uart_tx_o), the same
TB-level loopback convention apb_uart_master's CLAUDE.md documents ("TB uses
TB-level wire loopback instead of hardware CTRL loopback, to keep CTRL
clean").

Register map:
  0x00 TXDATA  0x04 RXDATA  0x08 STATUS ([0]=TX_READY [1]=RX_VALID [2]=ERR
  [3]=INIT_DONE)  0x0C CTRL ([0]=RX_ACK)

apb_uart_master and uart_ctrl protocol correctness (APB3 sequencing, TX/RX
FSM legality, FIFO safety) is already proven standalone by their own P2
formal + this repo's prior test suites. These tests focus on the new
integration: register map wiring, the TX hold-until-accepted glue, and the
CTRL-write RX-pop convention (axi_lite_slave has no read-side-effect
mechanism, so "pop" can't be modeled as "reading RXDATA advances the FIFO").

CLK_FREQ/BAUD_RATE are overridden via cocotb_sim.mk so apb_uart_master's
computed BRDIV_VAL = 0 (baud16_tick every cycle) -- otherwise a full UART
frame costs thousands of cycles at default baud.
"""
import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, Edge

TXDATA, RXDATA, STATUS, CTRL = 0x00, 0x04, 0x08, 0x0C

BIT_TX_READY  = 0
BIT_RX_VALID  = 1
BIT_ERR       = 2
BIT_INIT_DONE = 3


async def loopback(dut):
    """Ties uart_rx_i to uart_tx_o like a real external wire — reacts
    immediately on every change rather than waiting for a clock edge, since
    the pads are asynchronous from the fabric's point of view."""
    dut.uart_rx_i.value = dut.uart_tx_o.value
    while True:
        await Edge(dut.uart_tx_o)
        dut.uart_rx_i.value = dut.uart_tx_o.value


async def reset(dut):
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())
    cocotb.start_soon(loopback(dut))
    dut.rst_n.value    = 0
    dut.awvalid_i.value = 0
    dut.awaddr_i.value  = 0
    dut.awprot_i.value  = 0
    dut.wvalid_i.value  = 0
    dut.wdata_i.value   = 0
    dut.wstrb_i.value   = 0
    dut.bready_i.value  = 0
    dut.arvalid_i.value = 0
    dut.araddr_i.value  = 0
    dut.arprot_i.value  = 0
    dut.rready_i.value  = 0
    for _ in range(4):
        await RisingEdge(dut.clk)
    dut.rst_n.value = 1
    for _ in range(2):
        await RisingEdge(dut.clk)


async def axi_write(dut, addr, data, strb=0xF):
    dut.awvalid_i.value = 1
    dut.awaddr_i.value  = addr
    dut.awprot_i.value  = 0
    dut.wvalid_i.value  = 1
    dut.wdata_i.value   = data
    dut.wstrb_i.value   = strb

    aw_done = False
    w_done  = False
    while not (aw_done and w_done):
        await RisingEdge(dut.clk)
        if dut.awready_o.value and dut.awvalid_i.value:
            aw_done = True
            dut.awvalid_i.value = 0
        if dut.wready_o.value and dut.wvalid_i.value:
            w_done = True
            dut.wvalid_i.value = 0

    dut.bready_i.value = 1
    while not dut.bvalid_o.value:
        await RisingEdge(dut.clk)
    bresp = int(dut.bresp_o.value)
    await RisingEdge(dut.clk)
    dut.bready_i.value = 0
    return bresp


async def axi_read(dut, addr):
    dut.arvalid_i.value = 1
    dut.araddr_i.value  = addr
    dut.arprot_i.value  = 0
    dut.rready_i.value  = 1

    await RisingEdge(dut.clk)
    while not (dut.arready_o.value and dut.arvalid_i.value):
        await RisingEdge(dut.clk)
    dut.arvalid_i.value = 0

    while not dut.rvalid_o.value:
        await RisingEdge(dut.clk)
    rdata = int(dut.rdata_o.value)
    rresp = int(dut.rresp_o.value)
    await RisingEdge(dut.clk)
    dut.rready_i.value = 0
    return rdata, rresp


async def wait_status_bit(dut, bit, want, max_polls=400):
    for _ in range(max_polls):
        status, resp = await axi_read(dut, STATUS)
        assert resp == 0, f"STATUS read SLVERR: 0x{resp:x}"
        if ((status >> bit) & 1) == want:
            return status
    raise AssertionError(f"bit {bit} never reached {want} within {max_polls} polls")


async def tx_byte(dut, b):
    await wait_status_bit(dut, BIT_TX_READY, 1)
    resp = await axi_write(dut, TXDATA, b)
    assert resp == 0, f"TXDATA write SLVERR: 0x{resp:x}"


async def rx_byte(dut):
    """Poll RX_VALID==1, read RXDATA, ack, then confirm RX_VALID==0 before
    returning. The confirm step is required, not defensive: STATUS is read
    back through axi_lite_slave's own 2-cycle hw_wdata_q/reg_q pipeline, so
    a poll issued immediately after the ack write can still observe the
    stale RX_VALID=1 describing the byte just acked, indistinguishable from
    a genuine new byte without first seeing it drop to 0."""
    await wait_status_bit(dut, BIT_RX_VALID, 1, max_polls=4000)
    rdata, resp = await axi_read(dut, RXDATA)
    assert resp == 0, f"RXDATA read SLVERR: 0x{resp:x}"
    await axi_write(dut, CTRL, 0x1)  # ack
    await wait_status_bit(dut, BIT_RX_VALID, 0, max_polls=20)  # confirm ack landed
    return rdata & 0xFF


@cocotb.test()
async def test_reset_and_init(dut):
    """After reset: apb_uart_master's autonomous init completes, TX_READY=1,
    RX_VALID=0, ERR=0."""
    await reset(dut)
    await wait_status_bit(dut, BIT_INIT_DONE, 1)
    status, resp = await axi_read(dut, STATUS)
    assert resp == 0
    assert (status >> BIT_TX_READY) & 1 == 1, f"TX_READY not set post-init: 0x{status:x}"
    assert (status >> BIT_RX_VALID) & 1 == 0, f"RX_VALID unexpectedly set: 0x{status:x}"
    assert (status >> BIT_ERR) & 1 == 0, f"ERR unexpectedly set: 0x{status:x}"
    dut._log.info("test_reset_and_init PASS")


@cocotb.test()
async def test_single_byte_loopback(dut):
    """A byte written to TXDATA round-trips through the whole UART stack
    (apb_uart_master TX FIFO -> APB write -> uart_ctrl TX FSM -> serial line
    -> uart_ctrl RX FSM -> APB read -> apb_uart_master RX FIFO) and appears
    on RXDATA."""
    await reset(dut)
    await wait_status_bit(dut, BIT_INIT_DONE, 1)
    await tx_byte(dut, 0x41)  # 'A'
    got = await rx_byte(dut)
    assert got == 0x41, f"loopback byte: got 0x{got:02x}, expected 0x41"
    dut._log.info("test_single_byte_loopback PASS")


@cocotb.test()
async def test_multi_byte_loopback_order(dut):
    """Back-to-back bytes arrive in order, not just individually correct."""
    await reset(dut)
    await wait_status_bit(dut, BIT_INIT_DONE, 1)
    for b in (0x48, 0x49):  # 'H', 'I'
        await tx_byte(dut, b)
    got0 = await rx_byte(dut)
    got1 = await rx_byte(dut)
    assert got0 == 0x48, f"byte0: got 0x{got0:02x}"
    assert got1 == 0x49, f"byte1: got 0x{got1:02x}"
    dut._log.info("test_multi_byte_loopback_order PASS")


@cocotb.test()
async def test_slverr_oob(dut):
    """Reading past the 4-register map returns SLVERR (delegated to
    axi_lite_slave)."""
    await reset(dut)
    _, resp = await axi_read(dut, 0x40)
    assert resp == 0b10, f"expected SLVERR, got 0x{resp:x}"
    dut._log.info("test_slverr_oob PASS")


@cocotb.test()
async def test_pop_noop_safe(dut):
    """Writing CTRL[0]=1 with no RX byte pending is a safe no-op (guarded
    internally by apb_uart_master's own !rxf_empty check)."""
    await reset(dut)
    await wait_status_bit(dut, BIT_INIT_DONE, 1)
    await axi_write(dut, CTRL, 0x1)
    for _ in range(4):
        await RisingEdge(dut.clk)
    status, resp = await axi_read(dut, STATUS)
    assert resp == 0
    assert (status >> BIT_RX_VALID) & 1 == 0, "RX_VALID unexpectedly set after no-op pop"
    dut._log.info("test_pop_noop_safe PASS")
