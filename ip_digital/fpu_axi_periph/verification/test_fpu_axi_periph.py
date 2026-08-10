"""cocotb test suite for fpu_axi_periph.

Drives the AXI4-Lite register interface (same manager tasks as
axi_lite_slave's own suite) and checks the FPU compute path end-to-end
through the register map:

  0x00 CTRL   0x04 OPA   0x08 OPB   0x0C OPC   0x10 INT_OPA
  0x14 RESULT 0x18 INT_RESULT 0x1C STATUS  ([0]=BUSY [1]=DONE [6:2]=FFLAGS)

AXI protocol correctness (WSTRB, SLVERR, W-before-AW, back-pressure) is
already proven standalone by axi_lite_slave's own suite + P2 formal — these
tests focus on the new integration: register map wiring, the start/done
glue FSM, and result/flag capture from fpu_top.
"""
import struct
import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge

STRB_ALL = 0xF

CTRL, OPA, OPB, OPC, INT_OPA, RESULT, INT_RESULT, STATUS = (
    0x00, 0x04, 0x08, 0x0C, 0x10, 0x14, 0x18, 0x1C)

UNIT_FMA, UNIT_CVT, UNIT_NONCOMP = 0b00, 0b10, 0b11
OP_FADD  = (UNIT_FMA << 4) | 0b0000
OP_FMUL  = (UNIT_FMA << 4) | 0b0010
OP_FMADD = (UNIT_FMA << 4) | 0b0011
OP_FEQ   = (UNIT_NONCOMP << 4) | 0b0100
OP_FCVT_S_W = (UNIT_CVT << 4) | 0b0010

RM_RNE = 0b000


def fp32_bits(f):
    return struct.unpack('>I', struct.pack('>f', f))[0]


def fp32_to_float(b):
    return struct.unpack('>f', struct.pack('>I', b & 0xFFFFFFFF))[0]


def ctrl_word(op, fmt=0, rm=RM_RNE):
    return (op & 0x3F) | ((fmt & 0x3) << 6) | ((rm & 0x7) << 8)


async def reset(dut):
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())
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


async def axi_write(dut, addr, data, strb=STRB_ALL):
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


async def wait_done(dut, max_polls=40):
    """Poll STATUS until DONE=1. Returns (busy, done, fflags).

    Synchronizes on BUSY=1 first: the CTRL write's effect (clearing the
    *previous* op's DONE, asserting BUSY) is not instant, so polling for
    DONE immediately after the CTRL write can observe a stale DONE=1 left
    over from the prior operation on back-to-back ops.
    """
    for _ in range(max_polls):
        status, resp = await axi_read(dut, STATUS)
        assert resp == 0, f"STATUS read SLVERR: 0x{resp:x}"
        if status & 0x1:
            break
    for _ in range(max_polls):
        status, resp = await axi_read(dut, STATUS)
        assert resp == 0, f"STATUS read SLVERR: 0x{resp:x}"
        busy  = status & 0x1
        done  = (status >> 1) & 0x1
        flags = (status >> 2) & 0x1F
        if done:
            return busy, done, flags
    raise AssertionError(f"operation did not complete within {max_polls} polls")


async def run_op(dut, op, opa=0, opb=0, opc=0, int_opa=0, fmt=0, rm=RM_RNE):
    await axi_write(dut, OPA, opa)
    await axi_write(dut, OPB, opb)
    await axi_write(dut, OPC, opc)
    await axi_write(dut, INT_OPA, int_opa)
    bresp = await axi_write(dut, CTRL, ctrl_word(op, fmt, rm))
    assert bresp == 0, f"CTRL write SLVERR: 0x{bresp:x}"
    busy, done, flags = await wait_done(dut)
    assert done == 1
    result, r_resp     = await axi_read(dut, RESULT)
    int_result, ir_resp = await axi_read(dut, INT_RESULT)
    assert r_resp == 0 and ir_resp == 0
    return result, int_result, flags


@cocotb.test()
async def test_reset_state(dut):
    """After reset: STATUS/RESULT/INT_RESULT all read 0."""
    await reset(dut)
    status, resp = await axi_read(dut, STATUS)
    assert resp == 0 and status == 0, f"STATUS not zero after reset: 0x{status:x}"
    result, _ = await axi_read(dut, RESULT)
    assert result == 0, f"RESULT not zero after reset: 0x{result:x}"
    dut._log.info("test_reset_state PASS")


@cocotb.test()
async def test_fadd(dut):
    """1.0 + 1.0 = 2.0, no exceptions."""
    await reset(dut)
    result, _, flags = await run_op(dut, OP_FADD, fp32_bits(1.0), fp32_bits(1.0))
    assert result == fp32_bits(2.0), f"FADD: got 0x{result:08x}, exp 0x{fp32_bits(2.0):08x}"
    assert flags == 0, f"FADD: unexpected fflags 0x{flags:x}"
    dut._log.info("test_fadd PASS")


@cocotb.test()
async def test_fmul(dut):
    """2.0 * 3.0 = 6.0."""
    await reset(dut)
    result, _, flags = await run_op(dut, OP_FMUL, fp32_bits(2.0), fp32_bits(3.0))
    assert result == fp32_bits(6.0), f"FMUL: got 0x{result:08x}, exp 0x{fp32_bits(6.0):08x}"
    assert flags == 0
    dut._log.info("test_fmul PASS")


@cocotb.test()
async def test_fmadd(dut):
    """2.0 * 3.0 + 1.0 = 7.0 — exercises the OPC (src_c_i) register."""
    await reset(dut)
    result, _, flags = await run_op(
        dut, OP_FMADD, fp32_bits(2.0), fp32_bits(3.0), fp32_bits(1.0))
    assert result == fp32_bits(7.0), f"FMADD: got 0x{result:08x}, exp 0x{fp32_bits(7.0):08x}"
    assert flags == 0
    dut._log.info("test_fmadd PASS")


@cocotb.test()
async def test_feq(dut):
    """1.0 == 1.0 — exercises the INT_RESULT register (int_result_o path)."""
    await reset(dut)
    _, int_result, flags = await run_op(dut, OP_FEQ, fp32_bits(1.0), fp32_bits(1.0))
    assert (int_result & 1) == 1, f"FEQ: expected true, got int_result=0x{int_result:x}"
    dut._log.info("test_feq PASS")


@cocotb.test()
async def test_fcvt_s_w(dut):
    """int32(3) -> FP32 3.0 — exercises the INT_OPA (int_src_i) register."""
    await reset(dut)
    result, _, flags = await run_op(dut, OP_FCVT_S_W, int_opa=3)
    assert result == fp32_bits(3.0), f"FCVT.S.W: got 0x{result:08x}, exp 0x{fp32_bits(3.0):08x}"
    dut._log.info("test_fcvt_s_w PASS")


@cocotb.test()
async def test_busy_during_op(dut):
    """BUSY must read 1 immediately after START, before DONE appears."""
    await reset(dut)
    await axi_write(dut, OPA, fp32_bits(1.0))
    await axi_write(dut, OPB, fp32_bits(1.0))
    await axi_write(dut, CTRL, ctrl_word(OP_FADD))
    status, resp = await axi_read(dut, STATUS)
    assert resp == 0
    assert (status & 0x1) == 1, f"BUSY not set right after START: 0x{status:x}"
    assert ((status >> 1) & 0x1) == 0, "DONE set too early"
    await wait_done(dut)
    dut._log.info("test_busy_during_op PASS")


@cocotb.test()
async def test_back_to_back(dut):
    """Second operation must clear DONE and complete independently of the first."""
    await reset(dut)
    r1, _, f1 = await run_op(dut, OP_FADD, fp32_bits(1.0), fp32_bits(1.0))
    assert r1 == fp32_bits(2.0) and f1 == 0
    r2, _, f2 = await run_op(dut, OP_FMUL, fp32_bits(4.0), fp32_bits(5.0))
    assert r2 == fp32_bits(20.0), f"back-to-back FMUL: got 0x{r2:08x}"
    assert f2 == 0
    dut._log.info("test_back_to_back PASS")


@cocotb.test()
async def test_slverr_oob(dut):
    """Reading past the 8-register map returns SLVERR (delegated to axi_lite_slave)."""
    await reset(dut)
    _, resp = await axi_read(dut, 0x40)
    assert resp == 0b10, f"expected SLVERR, got 0x{resp:x}"
    dut._log.info("test_slverr_oob PASS")
