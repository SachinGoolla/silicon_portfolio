"""cocotb test suite for mac_cluster -- the Phase 3 standalone P3/P4 test
vector.

Demo (Phase 3 plan §4): two concurrent producers, one consumer. Tile 0
(0,0) and tile 1 (1,0) each compute an independent first-stage result from
a CPU-injected activation and forward it into the mesh, addressed to tile
3 (1,1). Tile 3 receives both (requantized to int8), and independently
MAC's each one against its own weights -- two separate results, not a
merged reduction (int8_mac_core does not accumulate across pushes; each
push is its own pass, matching the real RTL behavior). Tile 2 (0,1) is
loaded with weights but never pushed, matching the plan's own stated scope
(3 of 4 tiles active this demo).

Traffic exercises a genuine XY turn (tile0's path: (0,0)->(1,0)->(1,1), an
X hop then a Y hop, physically through tile1's own router) contending on
the SAME North-bound link tile1's own (1,0)->(1,1) traffic uses (a single
Y hop) -- the only 2-way contention achievable on a 2x2 mesh, and the
reason arrival order at tile3 is NOT assumed: this test accepts either
producer's result first and matches it against whichever golden value it
equals.

Golden model: independent, hand-written Python (no shared code with the
RTL's own arithmetic or with mac_tile_axi's own test suite) -- matmul +
the SAME arithmetic-right-shift-then-saturate semantics requant.sv's own
formal proof establishes. Weight matrices are deliberately non-symmetric
(mac_tile_axi's own Phase 2 REPORT notes a symmetric W=5*I test couldn't
have exposed a transpose bug on its own). Activation/result magnitudes are
chosen so BOTH producers' requantized results include values that saturate
in BOTH directions (positive saturation from tile0's own Y0[0]=3460,
negative saturation from tile1's own Y1[1]=-2400 and Y1[3]=-2270) plus
negative in-range values throughout -- the exact coverage requant.sv's own
signedness trap (Phase 3 plan §3 checkpoint 2) needs to be caught by, not
just possible-in-principle.
"""
import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge

STRB_ALL = 0xF

# ---------------------------------------------------------------------
# Address map (mac_cluster.sv header comment is the authoritative source).
# ---------------------------------------------------------------------
def tile_page_addr(tile, offset):
    return (tile << 8) | offset

CSR_PAGE = 4
def csr_addr(tile, reg):
    return (CSR_PAGE << 8) + (tile * 8 + reg) * 4

TILE_CTRL, TILE_STATUS = 0x00, 0x04
TILE_WEIGHT_ROW0, TILE_WEIGHT_ROW1, TILE_WEIGHT_ROW2, TILE_WEIGHT_ROW3 = 0x08, 0x0C, 0x10, 0x14

NI_CTRL, NI_STATUS, NI_DEST, NI_ENTRY_DATA = 0, 1, 2, 3
NI_EXIT_RESULT0, NI_EXIT_RESULT1, NI_EXIT_RESULT2, NI_EXIT_RESULT3 = 4, 5, 6, 7

NI_CTRL_ENTRY_PUSH      = 1 << 0
NI_CTRL_TLAST_NEXT      = 1 << 1
NI_CTRL_MESH_EGRESS_EN  = 1 << 2
NI_CTRL_EXIT_ACK        = 1 << 3

NI_STATUS_ENTRY_BUSY = 1 << 0
NI_STATUS_EXIT_VALID = 1 << 1
NI_STATUS_EXIT_LAST  = 1 << 2
NI_STATUS_EXIT_SEQ   = 1 << 3

TILE_STATUS_WEIGHTS_LOADED = 1 << 0
TILE_CTRL_LOAD_WEIGHTS     = 1 << 0

K = N = 4


# ---------------------------------------------------------------------
# Independent golden model -- plain Python, no shared code with the RTL.
# ---------------------------------------------------------------------
def golden_matmul(a_row, w_rows):
    return [sum(a_row[i] * w_rows[i][j] for i in range(K)) for j in range(N)]


def golden_requant(vals, shift=4):
    out = []
    for v in vals:
        shifted = v >> shift  # Python's >> on int is arithmetic (floor), matching >>>
        if shifted > 127:
            shifted = 127
        elif shifted < -128:
            shifted = -128
        out.append(shifted)
    return out


def pack_act_vec(vals):
    word = 0
    for idx, v in enumerate(vals):
        word |= (v & 0xFF) << (idx * 8)
    return word


def unpack_result_vec(word):
    out = []
    for idx in range(4):
        chunk = (word >> (idx * 32)) & 0xFFFFFFFF
        out.append(chunk - (1 << 32) if chunk >= (1 << 31) else chunk)
    return out


# ---------------------------------------------------------------------
# AXI4-Lite manager tasks -- same pattern as mac_tile_axi's own suite.
# ---------------------------------------------------------------------
async def reset(dut):
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())
    dut.rst_n.value = 0
    dut.awvalid_i.value = 0
    dut.wvalid_i.value = 0
    dut.bready_i.value = 0
    dut.arvalid_i.value = 0
    dut.rready_i.value = 0
    for _ in range(5):
        await RisingEdge(dut.clk)
    dut.rst_n.value = 1
    await RisingEdge(dut.clk)


async def axi_write(dut, addr, data, strb=STRB_ALL):
    dut.awvalid_i.value = 1
    dut.awaddr_i.value = addr
    dut.awprot_i.value = 0
    dut.wvalid_i.value = 1
    dut.wdata_i.value = data
    dut.wstrb_i.value = strb
    aw_done = wr_done = False
    for _ in range(50):
        await RisingEdge(dut.clk)
        if not aw_done and dut.awready_o.value:
            dut.awvalid_i.value = 0
            aw_done = True
        if not wr_done and dut.wready_o.value:
            dut.wvalid_i.value = 0
            wr_done = True
        if aw_done and wr_done:
            break
    dut.bready_i.value = 1
    for _ in range(50):
        await RisingEdge(dut.clk)
        if dut.bvalid_o.value:
            resp = int(dut.bresp_o.value)
            break
    else:
        raise AssertionError(f"axi_write(addr=0x{addr:x}): no BVALID")
    await RisingEdge(dut.clk)
    dut.bready_i.value = 0
    return resp


async def axi_read(dut, addr):
    dut.arvalid_i.value = 1
    dut.araddr_i.value = addr
    dut.arprot_i.value = 0
    dut.rready_i.value = 1
    for _ in range(50):
        await RisingEdge(dut.clk)
        if dut.arready_o.value:
            dut.arvalid_i.value = 0
            break
    for _ in range(50):
        await RisingEdge(dut.clk)
        if dut.rvalid_o.value:
            data = int(dut.rdata_o.value)
            resp = int(dut.rresp_o.value)
            break
    else:
        raise AssertionError(f"axi_read(addr=0x{addr:x}): no RVALID")
    await RisingEdge(dut.clk)
    dut.rready_i.value = 0
    return data, resp


async def load_tile_weights(dut, tile, w_rows):
    for row_idx, reg_off in enumerate((TILE_WEIGHT_ROW0, TILE_WEIGHT_ROW1,
                                        TILE_WEIGHT_ROW2, TILE_WEIGHT_ROW3)):
        bresp = await axi_write(dut, tile_page_addr(tile, reg_off), pack_act_vec(w_rows[row_idx]))
        assert bresp == 0
    bresp = await axi_write(dut, tile_page_addr(tile, TILE_CTRL), TILE_CTRL_LOAD_WEIGHTS)
    assert bresp == 0
    for _ in range(30):
        status, resp = await axi_read(dut, tile_page_addr(tile, TILE_STATUS))
        assert resp == 0
        if status & TILE_STATUS_WEIGHTS_LOADED:
            return
        await RisingEdge(dut.clk)
    raise AssertionError(f"tile {tile}: weights never reported loaded")


async def ni_push_entry(dut, tile, act, dest_x, dest_y):
    """Configure tile's NI as a mesh-egress producer addressed to
    (dest_x,dest_y), then push one CPU-injected activation vector.

    Write order matters: entry_push_i (edge-pulsed off the NI_CTRL write)
    latches entry_data_i's value AT THE MOMENT it pulses -- NI_ENTRY_DATA
    must be written BEFORE NI_CTRL's ENTRY_PUSH bit, not after. Found this
    the hard way: writing CTRL first latched whatever NI_ENTRY_DATA still
    held from reset (zero), not the real activation -- a real bug in this
    test's own sequencing, not the RTL (mesh_egress_en_i/dest_x_i/dest_y_i
    are read live/combinationally every cycle, not latched-on-pulse, so
    NI_DEST can safely be written any time before the push completes)."""
    bresp = await axi_write(dut, csr_addr(tile, NI_DEST), (dest_y << 1) | dest_x)
    assert bresp == 0
    bresp = await axi_write(dut, csr_addr(tile, NI_ENTRY_DATA), pack_act_vec(act))
    assert bresp == 0
    bresp = await axi_write(dut, csr_addr(tile, NI_CTRL),
                             NI_CTRL_MESH_EGRESS_EN | NI_CTRL_ENTRY_PUSH | NI_CTRL_TLAST_NEXT)
    assert bresp == 0
    for _ in range(50):
        status, resp = await axi_read(dut, csr_addr(tile, NI_STATUS))
        assert resp == 0
        if not (status & NI_STATUS_ENTRY_BUSY):
            return
        await RisingEdge(dut.clk)
    raise AssertionError(f"tile {tile}: entry push never completed")


async def ni_poll_and_read_exit(dut, tile, last_seq, timeout=200):
    """Poll NI_STATUS until EXIT_VALID=1 AND NI_STATUS_EXIT_SEQ differs
    from last_seq (the seq value last consumed for this tile; pass 0
    before the first call, matching exit_seq_q's own reset value).

    EXIT_VALID alone is NOT sufficient: exit_valid_q can legitimately go
    1(old result)->0(exactly one cycle, if a new result is already
    waiting)->1(new result) faster than a multi-cycle AXI read sequence
    can reliably observe the intermediate 0. A poller that acts on the
    first EXIT_VALID=1 it sees right after issuing an ack can read a
    stale echo of the result it just consumed -- found as a REAL,
    reproducible race via an independently-written Verilog TB
    (tb_mac_cluster.sv) whose different AXI read cadence landed a 4-word
    RESULT0-3 read sequence straddling the CSR mirror's advance to a new
    snapshot, returning a torn old/new mix. This cocotb suite's own
    original (pre-fix) version used the exact same missing-discriminator
    poll and was passing for the same lucky-timing reason -- it just
    never landed a read in the race window. See REPORT.md and
    tile_ni.sv's own header comment on exit_seq_q for the full mechanism.
    """
    rejected = 0
    for _ in range(timeout):
        status, resp = await axi_read(dut, csr_addr(tile, NI_STATUS))
        assert resp == 0
        seq = 1 if (status & NI_STATUS_EXIT_SEQ) else 0
        if (status & NI_STATUS_EXIT_VALID) and seq != last_seq:
            r0, resp0 = await axi_read(dut, csr_addr(tile, NI_EXIT_RESULT0))
            r1, resp1 = await axi_read(dut, csr_addr(tile, NI_EXIT_RESULT1))
            r2, resp2 = await axi_read(dut, csr_addr(tile, NI_EXIT_RESULT2))
            r3, resp3 = await axi_read(dut, csr_addr(tile, NI_EXIT_RESULT3))
            assert resp0 == resp1 == resp2 == resp3 == 0
            got = [r0, r1, r2, r3]
            got_signed = [v - (1 << 32) if v >= (1 << 31) else v for v in got]
            bresp = await axi_write(dut, csr_addr(tile, NI_CTRL), NI_CTRL_EXIT_ACK)
            assert bresp == 0
            return got_signed, seq, rejected
        if status & NI_STATUS_EXIT_VALID:
            rejected += 1
        await RisingEdge(dut.clk)
    raise AssertionError(f"tile {tile}: exit result never became valid (fresh seq)")


@cocotb.test()
async def test_two_producer_chain(dut):
    """Two concurrent producers (tiles 0,1) -> one consumer (tile 3),
    exercising a genuine XY turn and real link contention -- the demo
    Phase 3 plan §4 specifies."""
    await reset(dut)

    W0 = [[20, 5, -3, 8], [-15, 10, 6, -2], [7, -12, 15, 3], [4, 6, -8, 11]]
    A0 = [100, -80, 60, -40]
    W1 = [[25, -6, 4, 9], [12, -18, 7, -3], [-9, 14, -20, 5], [6, -8, 10, -15]]
    A1 = [-100, 90, -70, 50]
    W3 = [[2, 1, -1, 3], [0, -2, 4, 1], [-1, 3, 0, -2], [1, 0, 2, -3]]
    W2_unused = [[1, 0, 0, 1], [0, 1, 1, 0], [1, 1, 0, 0], [0, 0, 1, 1]]

    golden_Y0 = golden_matmul(A0, W0)
    golden_RQ0 = golden_requant(golden_Y0)
    golden_Y1 = golden_matmul(A1, W1)
    golden_RQ1 = golden_requant(golden_Y1)
    golden_Y3a = golden_matmul(golden_RQ0, W3)  # tile3's result from tile0's forward
    golden_Y3b = golden_matmul(golden_RQ1, W3)  # tile3's result from tile1's forward

    dut._log.info(f"golden RQ0={golden_RQ0} RQ1={golden_RQ1} Y3a={golden_Y3a} Y3b={golden_Y3b}")

    # Sanity: both directions of saturation are genuinely exercised by
    # this specific test data (Phase 3 plan §4's own hard requirement).
    assert 127 in golden_RQ0 or 127 in golden_RQ1, "positive saturation never exercised"
    assert -128 in golden_RQ0 or -128 in golden_RQ1, "negative saturation never exercised"
    assert any(v < 0 for v in golden_RQ0 + golden_RQ1), "negative in-range value never exercised"

    await load_tile_weights(dut, 0, W0)
    await load_tile_weights(dut, 1, W1)
    await load_tile_weights(dut, 2, W2_unused)  # loaded, never pushed -- matches plan §4
    await load_tile_weights(dut, 3, W3)

    # Tile 3 stays in its reset-default CPU-exit mode (mesh_egress_en=0) --
    # no NI_CTRL write needed for it before results start arriving.

    await ni_push_entry(dut, 0, A0, dest_x=1, dest_y=1)
    await ni_push_entry(dut, 1, A1, dest_x=1, dest_y=1)

    got_a, seq_a, rej_a = await ni_poll_and_read_exit(dut, 3, last_seq=0)
    got_b, seq_b, rej_b = await ni_poll_and_read_exit(dut, 3, last_seq=seq_a)

    dut._log.info(f"tile3 exit results (arrival order): {got_a}, then {got_b}")
    dut._log.info(f"exit_seq observed: a={seq_a} (rejected {rej_a} stale reading(s)), "
                   f"b={seq_b} (rejected {rej_b} stale reading(s))")
    assert seq_a != seq_b, "both exit reads returned the SAME seq value -- exit_seq_q never toggled"

    # Match order-independently: whichever arrived first must equal EITHER
    # golden result, and the two together must cover both.
    matched_a = (got_a == golden_Y3a) or (got_a == golden_Y3b)
    matched_b = (got_b == golden_Y3a) or (got_b == golden_Y3b)
    assert matched_a, f"first result {got_a} matches neither golden Y3a={golden_Y3a} nor Y3b={golden_Y3b}"
    assert matched_b, f"second result {got_b} matches neither golden Y3a={golden_Y3a} nor Y3b={golden_Y3b}"
    assert got_a != got_b, "both exit results were identical -- only one producer's result was seen twice"
    seen = {tuple(got_a), tuple(got_b)}
    assert seen == {tuple(golden_Y3a), tuple(golden_Y3b)}, \
        f"seen {seen} != expected {{{golden_Y3a}, {golden_Y3b}}} -- one producer's result never arrived"

    dut._log.info("test_two_producer_chain PASS")

