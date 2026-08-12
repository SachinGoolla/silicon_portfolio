"""cocotb test suite for rv32i_core.

TOPLEVEL is rv32i_core itself (no SV testbench wrapper) -- this Python
code has to BE the instruction memory and the AXI4-Lite data-memory slave,
not just drive stimulus at a register-mapped boundary the way
test_uart_axi_periph.py does. Note the port DIRECTIONS here are the
opposite of that file's: rv32i_core is an AXI4-Lite MASTER (awvalid_o/
awready_i/etc), not a slave -- this test drives the slave side
(awready_i, wready_i, bvalid_i, arready_i, rvalid_i, rdata_i) and reads
the master side (awvalid_o, awaddr_o, wvalid_o, wdata_o, wstrb_o,
bready_o, arvalid_o, araddr_o, rready_o).

Deliberately reuses gen_test_program.py's `get_words()` for the
instruction stream (not a re-encoded copy) and re-derives the golden
memory values independently via the same approach golden_values.py uses,
so this test doesn't just re-check "does the SV testbench's own math
agree with itself" -- it's a second, Python-side computation.

The whole pipeline composition (forwarding, hazard/stall/flush wiring,
LSU MEM-stage integration, branch/JAL/JALR resolution, WB mux) was
already exercised and passed under tb_rv32i_core.sv (Icarus, P4/P8-style
sim). This test exercises the SAME design under cocotb/pyuvm's own event
model (P3's actual gate in this portfolio's 9-pillar flow) with a
DIFFERENT, independently-written AXI slave model (0 wait states here vs
the SV BFM's 2-cycle artificial latency) -- exercising the LSU/hazard-unit
stall path under two different real-world-plausible slave latencies, not
just one, and reducing the chance a harness bug in one vehicle reproduces
identically in the other.
"""
import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, Timer

from gen_test_program import get_words

PROGRAM_WORDS = get_words()
MEM_WORDS = 128

# Golden values, independently computed here (not imported from
# golden_values.py) -- same "compute it fresh, don't just re-trust a
# neighboring script's output" discipline as decode_check.py/
# golden_values.py themselves.
def _u32(x):
    return x & 0xFFFFFFFF

def _s32(x):
    x = _u32(x)
    return x - (1 << 32) if x & 0x80000000 else x

def compute_golden():
    x = {0: 0, 1: 0, 2: 5, 3: 7}
    x[4] = _u32(x[2] + x[3])
    x[5] = _u32(x[4] - x[2])
    x[6] = x[2] & x[3]
    x[7] = x[2] | x[3]
    x[8] = x[2] ^ x[3]
    x[9] = _u32(x[2] << 1)
    x[10] = _u32(x[4]) >> 2
    x[11] = _u32(-8)
    x[12] = _u32(_s32(x[11]) >> 1)
    x[13] = 1 if _s32(x[2]) < _s32(x[3]) else 0
    x[14] = 1 if _u32(x[3]) < _u32(x[2]) else 0
    x[15] = 1 if _s32(x[2]) < 10 else 0
    x[16] = x[3] & 3
    x[17] = x[2] | 8
    x[18] = x[3] ^ 1
    x[19] = _u32(0x12345 << 12)
    x[20] = 0x04c
    x[21] = x[4]
    x[22] = _u32(x[21] + x[21])
    x[23] = 99
    x[25] = 0x0c4 + 4
    x[27] = 0x0dc + 4
    x[31] = 1
    return {
        0: x[4], 4: x[9], 8: x[6], 12: x[8], 16: x[22], 20: x[23],
        24: x[25], 28: x[27], 32: x[19], 36: x[20], 100: x[31],
    }

GOLDEN_MEM = compute_golden()


async def imem_model(dut):
    """Combinational-ROM model. Reads imem_addr_o and drives imem_rdata_i
    after a small (1ns) real-time delay past each RisingEdge, not
    immediately at the edge itself. Empirically confirmed necessary on
    this cocotb+Icarus combination, not just theoretical caution: reading
    immediately at RisingEdge raced the DUT's OWN if_id capture of the
    SAME imem_rdata_i this coroutine drives, for the SAME clock edge --
    if_id_pc_q (native RTL, no cocotb involvement) always advanced
    correctly, but if_id_instr_q (captured from THIS coroutine's output)
    consistently lagged it by exactly one instruction: a real observed
    cocotb/Icarus VPI scheduling race, not a DUT bug (confirmed separately
    via tb_rv32i_core.sv/Icarus with no cocotb involved at all, which
    passes end-to-end on the identical RTL and identical program).
    ReadOnly()+NextTimeStep() was tried first and made it WORSE (a
    permanent hang) -- NextTimeStep can advance much further than one
    delta cycle, apparently past the window the DUT expects a response
    in. A small real-time Timer is the standard, robust idiom for
    exactly this class of race: it guarantees every process's NBA updates
    for this edge have completed (10x+ the scheduler's delta-cycle
    resolution) while remaining far from the next edge (1ns vs a 10ns
    clock period) -- still a normal writable phase, unlike ReadOnly."""
    while True:
        await RisingEdge(dut.clk)
        await Timer(1, unit="ns")
        addr = _safe_int(dut.imem_addr_o)
        idx = (addr >> 2) & 0x7F
        word = PROGRAM_WORDS[idx] if idx < len(PROGRAM_WORDS) else 0x00000013
        dut.imem_rdata_i.value = word


def _safe_int(signal):
    """Same X-during-reset-transient risk as imem_model's addr read above,
    general to every DUT output this harness samples (not just
    imem_addr_o) -- observed empirically via a real cocotb run, not
    assumed. Treat unresolvable as 0: harmless during the reset window
    (an unasserted VALID/READY, or address 0), and every consumer here
    only starts making real protocol decisions once rst_n has been high
    for a full cycle."""
    v = signal.value
    return int(v) if v.is_resolvable else 0


class AxiMemModel:
    """AXI4-Lite RAM slave for rv32i_core's master port. Independent
    implementation from axi_lite_mem_bfm.sv (different language, 0 wait
    states instead of that model's 2-cycle artificial latency, different
    internal structure) so a harness bug in one is unlikely to reproduce
    identically in the other. Exposes `mem` so the test can read back
    final state directly instead of contending for the AXI bus with the
    coroutine that's already driving it every cycle."""

    def __init__(self, dut):
        self.dut = dut
        self.mem = [0] * MEM_WORDS
        self.aw_seen = False
        self.w_seen = False
        self.awaddr = 0
        self.wdata = 0
        self.wstrb = 0
        self.write_pending = False
        self.read_pending = False
        self.raddr = 0

    async def run(self):
        dut = self.dut
        dut.awready_i.value = 0
        dut.wready_i.value = 0
        dut.bvalid_i.value = 0
        dut.bresp_i.value = 0
        dut.arready_i.value = 0
        dut.rvalid_i.value = 0
        dut.rdata_i.value = 0
        dut.rresp_i.value = 0

        while True:
            await RisingEdge(dut.clk)
            await Timer(1, unit="ns")
            # Snapshot every DUT output this cycle needs, all at once,
            # guaranteed settled (same race as imem_model's own fix
            # above -- see that docstring).
            awvalid = _safe_int(dut.awvalid_o)
            awaddr  = _safe_int(dut.awaddr_o)
            wvalid  = _safe_int(dut.wvalid_o)
            wdata   = _safe_int(dut.wdata_o)
            wstrb   = _safe_int(dut.wstrb_o)
            bready  = _safe_int(dut.bready_o)
            arvalid = _safe_int(dut.arvalid_o)
            araddr  = _safe_int(dut.araddr_o)
            rready  = _safe_int(dut.rready_o)

            # True register-style model: DRIVE this cycle's response using
            # LAST cycle's decision (self.write_pending/self.read_pending
            # as they already stood, untouched, going into this
            # iteration), THEN compute what NEXT cycle's decision should
            # be from this cycle's snapshot. bready_o/rready_o are
            # unconditionally 1 for this LSU's ENTIRE S_WRESP/S_READ_DATA
            # state (not just "after observing VALID"), so a naive
            # "assert VALID, then react to READY, same iteration" clears
            # VALID within the SAME simulated instant it was set -- the
            # DUT's combinational state_d never observes a stable 1 for
            # even one full clock period, and the FSM hangs in S_WRESP/
            # S_READ_DATA forever. Confirmed via a real cocotb run (twice:
            # once with a same-cycle clear, once with a one-flag-deferred
            # clear that still collapsed the assertion to under a full
            # cycle) before landing on this drive-then-decide split, which
            # is the only version that actually held bvalid_i/rvalid_i
            # high for a full clock period.
            dut.awready_i.value = 0 if self.write_pending else 1
            dut.wready_i.value  = 0 if self.write_pending else 1
            dut.bvalid_i.value  = 1 if self.write_pending else 0
            dut.arready_i.value = 0 if self.read_pending else 1
            dut.rvalid_i.value  = 1 if self.read_pending else 0
            if self.read_pending:
                dut.rdata_i.value = self.mem[(self.raddr >> 2) & (MEM_WORDS - 1)]

            # Decide NEXT cycle's write state.
            if self.write_pending:
                if bready:
                    self.write_pending = False
            else:
                if awvalid and not self.aw_seen:
                    self.aw_seen = True
                    self.awaddr = awaddr
                if wvalid and not self.w_seen:
                    self.w_seen = True
                    self.wdata = wdata
                    self.wstrb = wstrb
                if self.aw_seen and self.w_seen:
                    idx = (self.awaddr >> 2) & (MEM_WORDS - 1)
                    word = self.mem[idx]
                    for lane in range(4):
                        if (self.wstrb >> lane) & 1:
                            word = (word & ~(0xFF << (8 * lane))) | \
                                   (((self.wdata >> (8 * lane)) & 0xFF) << (8 * lane))
                    self.mem[idx] = word & 0xFFFFFFFF
                    self.write_pending = True
                    self.aw_seen = self.w_seen = False

            # Decide NEXT cycle's read state.
            if self.read_pending:
                if rready:
                    self.read_pending = False
            else:
                if arvalid:
                    self.raddr = araddr
                    self.read_pending = True


async def reset(dut):
    dut.rst_n.value = 0
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())
    cocotb.start_soon(imem_model(dut))
    axi_model = AxiMemModel(dut)
    cocotb.start_soon(axi_model.run())
    for _ in range(5):
        await RisingEdge(dut.clk)
    dut.rst_n.value = 1
    return axi_model


@cocotb.test()
async def test_program_runs_to_completion(dut):
    """Runs the full test program (ALU op coverage, byte/half/word
    stores, a load-use hazard immediately followed by its dependent use,
    all six branch conditions, JAL, JALR, LUI, AUIPC) and checks every
    golden memory location — including the load-use+AXI-stall interaction
    (mem[16]) and both branches/JAL/JALR landing correctly (mem[20]/[24]/
    [28]) rather than hoping a generic program happens to exercise them."""
    axi_model = await reset(dut)

    # Poll the DONE sentinel (mem[100], word index 25) directly off the
    # slave model's own backing store -- no bus contention, since the
    # model owns mem[] independent of any in-flight transaction.
    max_cycles = 1000
    for _ in range(max_cycles):
        if axi_model.mem[25] != 0:
            break
        await RisingEdge(dut.clk)
    else:
        raise AssertionError(f"DONE sentinel (mem[100]) never observed within {max_cycles} cycles")

    await RisingEdge(dut.clk)  # let any trailing writeback settle

    errors = []
    for addr, expected in sorted(GOLDEN_MEM.items()):
        got = axi_model.mem[addr >> 2]
        if got != expected:
            errors.append(f"mem[{addr}] = 0x{got:08x}, expected 0x{expected:08x}")
        else:
            dut._log.info(f"mem[{addr}] = 0x{got:08x}  OK")

    assert not errors, "rv32i_core self-check failed:\n" + "\n".join(errors)
    dut._log.info("test_program_runs_to_completion PASS")
