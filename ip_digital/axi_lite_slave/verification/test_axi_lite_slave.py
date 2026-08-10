"""cocotb test suite for axi_lite_slave.

Drives an AXI4-Lite manager model; all transactions are blocking with explicit
VALID/READY handshake polling.  No bus-functional-model library dependency.

Tests
  test_reset_state     : all registers read as 0 after reset
  test_basic_write_read: write 0xDEADBEEF, read it back
  test_wstrb           : partial byte-lane write (WSTRB=0x8)
  test_slverr_write    : BRESP=SLVERR for out-of-range address
  test_slverr_read     : RRESP=SLVERR for out-of-range address
  test_w_before_aw     : W channel before AW channel — AXI4-Lite spec §A3
  test_back_pressure   : BVALID held while BREADY=0 (sticky-VALID check)
  test_regfile_port    : regfile_o reflects post-commit register value
"""

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, ReadOnly

DATA_WIDTH = 32
ADDR_WIDTH = 12
NUM_REGS   = 16
STRB_ALL   = 0xF


async def reset(dut):
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
    dut.hw_wdata_i.value = 0
    dut.hw_we_i.value    = 0
    for _ in range(4):
        await RisingEdge(dut.clk)
    dut.rst_n.value = 1
    for _ in range(2):
        await RisingEdge(dut.clk)


async def axi_write(dut, addr, data, strb=STRB_ALL):
    """Drive AW+W simultaneously, return BRESP."""
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
    """Drive AR, return (rdata, rresp)."""
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


@cocotb.test()
async def test_reset_state(dut):
    """All registers read as 0 after reset."""
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    await reset(dut)
    for i in range(NUM_REGS):
        data, resp = await axi_read(dut, i * 4)
        assert data == 0, f"reg[{i}] = 0x{data:08X} (expected 0)"
        assert resp == 0, f"reg[{i}] resp = {resp} (expected OKAY)"


@cocotb.test()
async def test_basic_write_read(dut):
    """Write 0xDEADBEEF to reg[1], read it back."""
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    await reset(dut)
    resp = await axi_write(dut, 0x004, 0xDEADBEEF)
    assert resp == 0, f"BRESP {resp} (expected OKAY)"
    data, resp = await axi_read(dut, 0x004)
    assert data == 0xDEADBEEF, f"readback 0x{data:08X}"
    assert resp == 0


@cocotb.test()
async def test_wstrb(dut):
    """WSTRB byte-lane masking: partial word write."""
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    await reset(dut)
    # Fill reg[2] with 0xFF bytes
    await axi_write(dut, 0x008, 0xFFFFFFFF)
    # Write only byte 3 (MSB) = 0xAA, leaving bytes 0-2 = 0xFF
    await axi_write(dut, 0x008, 0xAA000000, strb=0x8)
    data, _ = await axi_read(dut, 0x008)
    assert data == 0xAAFFFFFF, f"WSTRB result 0x{data:08X} (expected 0xAAFFFFFF)"


@cocotb.test()
async def test_slverr_write(dut):
    """BRESP=SLVERR (0x2) for out-of-bounds address."""
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    await reset(dut)
    oob = NUM_REGS * 4   # first address beyond register window
    resp = await axi_write(dut, oob, 0xBADCAFE)
    assert resp == 0b10, f"BRESP {resp} (expected SLVERR=0x2)"


@cocotb.test()
async def test_slverr_read(dut):
    """RRESP=SLVERR for out-of-bounds address."""
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    await reset(dut)
    oob = NUM_REGS * 4
    data, resp = await axi_read(dut, oob)
    assert resp == 0b10, f"RRESP {resp} (expected SLVERR=0x2)"
    assert data == 0


@cocotb.test()
async def test_w_before_aw(dut):
    """W channel accepted before AW channel — reversed ordering per spec."""
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    await reset(dut)

    # Drive W only (no AW yet)
    dut.wvalid_i.value = 1
    dut.wdata_i.value  = 0x12345678
    dut.wstrb_i.value  = STRB_ALL
    await RisingEdge(dut.clk)
    while not dut.wready_o.value:
        await RisingEdge(dut.clk)
    dut.wvalid_i.value = 0     # W accepted into buffer

    # Now drive AW
    dut.awvalid_i.value = 1
    dut.awaddr_i.value  = 0x014   # reg[5]
    await RisingEdge(dut.clk)
    while not dut.awready_o.value:
        await RisingEdge(dut.clk)
    dut.awvalid_i.value = 0

    # Wait for B
    dut.bready_i.value = 1
    while not dut.bvalid_o.value:
        await RisingEdge(dut.clk)
    assert int(dut.bresp_o.value) == 0, "W-before-AW: BRESP != OKAY"
    await RisingEdge(dut.clk)
    dut.bready_i.value = 0

    # Read back
    data, resp = await axi_read(dut, 0x014)
    assert data == 0x12345678, f"W-before-AW readback 0x{data:08X}"
    assert resp == 0


@cocotb.test()
async def test_back_pressure(dut):
    """BVALID must stay asserted while BREADY is low (AXI4-Lite §A3.2.1)."""
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    await reset(dut)

    # Initiate write with bready=0
    dut.awvalid_i.value = 1
    dut.awaddr_i.value  = 0x000
    dut.wvalid_i.value  = 1
    dut.wdata_i.value   = 0xCAFEBABE
    dut.wstrb_i.value   = STRB_ALL
    dut.bready_i.value  = 0

    aw_done = w_done = False
    while not (aw_done and w_done):
        await RisingEdge(dut.clk)
        if dut.awready_o.value and dut.awvalid_i.value:
            aw_done = True
            dut.awvalid_i.value = 0
        if dut.wready_o.value and dut.wvalid_i.value:
            w_done = True
            dut.wvalid_i.value = 0

    while not dut.bvalid_o.value:
        await RisingEdge(dut.clk)

    # Hold bready=0 for 8 cycles; bvalid must not drop
    for i in range(8):
        await RisingEdge(dut.clk)
        assert dut.bvalid_o.value == 1, \
            f"BVALID dropped with BREADY=0 at hold cycle {i}"

    dut.bready_i.value = 1
    await RisingEdge(dut.clk)
    dut.bready_i.value = 0


@cocotb.test()
async def test_regfile_port(dut):
    """regfile_o reflects post-commit register content."""
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    await reset(dut)
    await axi_write(dut, 0x00C, 0xABCD_1234)   # reg[3]
    # Allow one cycle for regfile_o to settle (it is combinational off reg_q)
    await RisingEdge(dut.clk)
    await ReadOnly()
    regfile = int(dut.regfile_o.value)
    reg3 = (regfile >> (3 * DATA_WIDTH)) & 0xFFFFFFFF
    assert reg3 == 0xABCD1234, f"regfile_o reg[3] = 0x{reg3:08X}"
