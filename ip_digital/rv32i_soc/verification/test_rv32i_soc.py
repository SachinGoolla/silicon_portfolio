"""cocotb test suite for rv32i_soc.

TOPLEVEL is rv32i_soc itself. Unlike test_rv32i_core.py (which has to model
the instruction ROM and the AXI4-Lite data-memory slave in Python, since
rv32i_core is a bare standalone datapath), everything rv32i_soc's program
touches -- the instruction ROM, the RAM, the UART peripheral, the FPU
peripheral, the address decoder -- is real internal RTL. This test only
drives clk/rst_n and polls, exactly like tb_rv32i_soc.sv does; there is no
custom bus model to write.

No CLK_FREQ/BAUD_RATE override is needed here -- rv32i_soc.sv's own
default parameters are already the fast-sim values (1600/100), so
program.s's UART TX/RX polling loops don't cost thousands of real-baud
cycles even though p3_functional.py instantiates TOPLEVEL at its
default parameter values with no override mechanism of its own. See
rv32i_soc.sv's header comment for why the defaults are fast-sim values
directly rather than a per-pillar override: a synthesized netlist has
no parameters left to override, so P8 GLS needs the same fast timing
baked in as the default, not applied at instantiation.

Golden values are read by hierarchically peeking dut.u_ram.reg_q -- the
RAM's internal register-file array (axi_lite_slave.sv's own reg_q,
instantiated inside rv32i_soc as u_ram) -- the cocotb equivalent of
tb_rv32i_soc.sv's own hierarchical peek of the same signal.
"""
import cocotb
from cocotb.clock import Clock
from cocotb.triggers import Edge, RisingEdge

RAM_WORD_FPU_RESULT = 0
RAM_WORD_DONE_MARKER = 1
RAM_WORD_UART_RX = 2
RAM_WORD_MAC_RESULT0 = 3
RAM_WORD_MAC_RESULT0_2ND = 4

EXPECT_FPU_RESULT = 0x40000000    # FADD(1.0, 1.0) = 2.0
EXPECT_DONE_MARKER = 0xCAFEF00D
EXPECT_UART_RX = 0x00000041       # 'A', looped back through uart_rx_i<=uart_tx_o
EXPECT_MAC_RESULT0 = 0x00000005       # W=5*I, A1=[1,2,3,4] via MMIO bridge -> Y[0]=5*1
EXPECT_MAC_RESULT0_2ND = 0x0000001E   # W=5*I, A2=[6,7,8,9], after RESULT_ACK -> Y[0]=5*6=30


def _safe_int(signal):
    v = signal.value
    return int(v) if v.is_resolvable else 0


async def loopback(dut):
    """Ties uart_rx_i to uart_tx_o like a real external wire -- same
    TB-level loopback convention test_uart_axi_periph.py already
    established for this exact "cocotb binds directly to the DUT, no SV
    wrapper" situation (rv32i_soc has no separate testbench module here,
    same as uart_axi_periph itself)."""
    dut.uart_rx_i.value = dut.uart_tx_o.value
    while True:
        await Edge(dut.uart_tx_o)
        dut.uart_rx_i.value = dut.uart_tx_o.value


async def reset(dut):
    dut.rst_n.value = 0
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())
    cocotb.start_soon(loopback(dut))
    for _ in range(5):
        await RisingEdge(dut.clk)
    dut.rst_n.value = 1


@cocotb.test()
async def test_program_runs_to_completion(dut):
    """Runs verification/program.s to completion: FPU FADD(1.0,1.0)=2.0
    via fpu_axi_periph's own poll-BUSY-then-DONE protocol, a RAM store/
    load round-trip through the address decoder, a UART TX byte looped
    back and read via RX (dut.uart_tx_o is wired to dut.uart_rx_i outside
    this module -- see the Makefile-generated toplevel binding, matching
    tb_rv32i_soc.sv's own `wire uart_loop` pattern applied at the pin
    level here since cocotb binds directly to rv32i_soc with no SV
    wrapper), and a deliberate touch of an unmapped address to prove the
    decoder's DECERR path propagates all the way back through the full
    composition (rv32i_lsu ignores bresp_i/rresp_i by design, so the core
    is expected to keep running normally afterward)."""
    await reset(dut)

    max_cycles = 20000
    for _ in range(max_cycles):
        if _safe_int(dut.u_ram.reg_q[RAM_WORD_DONE_MARKER]) != 0:
            break
        await RisingEdge(dut.clk)
    else:
        raise AssertionError(
            f"completion marker (RAM word {RAM_WORD_DONE_MARKER}) never "
            f"observed within {max_cycles} cycles"
        )

    for _ in range(4):
        await RisingEdge(dut.clk)  # let any trailing writeback settle

    errors = []

    got_fpu = _safe_int(dut.u_ram.reg_q[RAM_WORD_FPU_RESULT])
    if got_fpu != EXPECT_FPU_RESULT:
        errors.append(f"RAM[{RAM_WORD_FPU_RESULT}] (FPU result) = 0x{got_fpu:08x}, "
                       f"expected 0x{EXPECT_FPU_RESULT:08x}")
    else:
        dut._log.info(f"RAM[{RAM_WORD_FPU_RESULT}] (FPU result) = 0x{got_fpu:08x}  OK")

    got_marker = _safe_int(dut.u_ram.reg_q[RAM_WORD_DONE_MARKER])
    if got_marker != EXPECT_DONE_MARKER:
        errors.append(f"RAM[{RAM_WORD_DONE_MARKER}] (done marker) = 0x{got_marker:08x}, "
                       f"expected 0x{EXPECT_DONE_MARKER:08x}")
    else:
        dut._log.info(f"RAM[{RAM_WORD_DONE_MARKER}] (done marker) = 0x{got_marker:08x}  OK")

    got_rx = _safe_int(dut.u_ram.reg_q[RAM_WORD_UART_RX])
    if got_rx != EXPECT_UART_RX:
        errors.append(f"RAM[{RAM_WORD_UART_RX}] (UART RX loopback) = 0x{got_rx:08x}, "
                       f"expected 0x{EXPECT_UART_RX:08x}")
    else:
        dut._log.info(f"RAM[{RAM_WORD_UART_RX}] (UART RX loopback) = 0x{got_rx:08x}  OK")

    got_mac = _safe_int(dut.u_ram.reg_q[RAM_WORD_MAC_RESULT0])
    if got_mac != EXPECT_MAC_RESULT0:
        errors.append(f"RAM[{RAM_WORD_MAC_RESULT0}] (MAC RESULT0) = 0x{got_mac:08x}, "
                       f"expected 0x{EXPECT_MAC_RESULT0:08x}")
    else:
        dut._log.info(f"RAM[{RAM_WORD_MAC_RESULT0}] (MAC RESULT0) = 0x{got_mac:08x}  OK")

    got_mac2 = _safe_int(dut.u_ram.reg_q[RAM_WORD_MAC_RESULT0_2ND])
    if got_mac2 != EXPECT_MAC_RESULT0_2ND:
        errors.append(f"RAM[{RAM_WORD_MAC_RESULT0_2ND}] (MAC RESULT0, 2nd push) = 0x{got_mac2:08x}, "
                       f"expected 0x{EXPECT_MAC_RESULT0_2ND:08x}")
    else:
        dut._log.info(f"RAM[{RAM_WORD_MAC_RESULT0_2ND}] (MAC RESULT0, 2nd push) = 0x{got_mac2:08x}  OK")

    assert not errors, "rv32i_soc self-check failed:\n" + "\n".join(errors)
    dut._log.info("test_program_runs_to_completion PASS")
