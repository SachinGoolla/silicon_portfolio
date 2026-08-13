"""cocotb test suite for mac_tile_axi.

Drives the AXI4-Lite control/status port (same manager tasks as
fpu_axi_periph's own suite) and the raw AXI4-Stream data ports directly --
this is the standalone IP's own P3/P4 harness, so it exercises the array's
real pipelined throughput (multiple vectors genuinely in flight at once),
not the coarser MMIO-polling granularity the SoC-integrated CPU will later
see through DATA_IN/RESULT0-3.

No numpy in this venv (checked: not installed) -- the golden reference is
plain Python, independently re-derived from the RTL's own int8_mac_core.sv
arithmetic (not shared code), matching this portfolio's own-oracle
discipline (e.g. rv32i_core's decode_check.py, never importing the
assembler's own bit-manipulation logic).

Register map (see mac_tile_axi.sv header for the full description):
  0x00 CTRL  0x04 STATUS  0x08-0x14 WEIGHT_ROW0-3  0x18 DATA_IN
  0x1C-0x28 RESULT0-3
"""
import struct
import random
import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge

STRB_ALL = 0xF

CTRL, STATUS = 0x00, 0x04
WEIGHT_ROW0, WEIGHT_ROW1, WEIGHT_ROW2, WEIGHT_ROW3 = 0x08, 0x0C, 0x10, 0x14
DATA_IN = 0x18
RESULT0, RESULT1, RESULT2, RESULT3 = 0x1C, 0x20, 0x24, 0x28

CTRL_LOAD_WEIGHTS   = 1 << 0
CTRL_TLAST_NEXT     = 1 << 1
CTRL_INPUT_SRC_MMIO = 1 << 2
CTRL_RESULT_ACK     = 1 << 3

STATUS_WEIGHTS_LOADED = 1 << 0
STATUS_BUSY           = 1 << 1
STATUS_RESULT_VALID   = 1 << 2
STATUS_RESULT_LAST    = 1 << 3
STATUS_INPUT_BUSY      = 1 << 4

K = N = 4


# ---------------------------------------------------------------------
# Packing helpers -- and an independent, differently-implemented
# cross-check (struct-based, not the same bit-shift code) confirmed
# against each other in test_packing_helpers_cross_check below. Phase 1's
# gen_test_program.py hand-transcription bug is exactly this failure
# class; this is the cheap insurance against it.
# ---------------------------------------------------------------------
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


def pack_act_vec_struct(vals):
    return int.from_bytes(struct.pack('<4b', *vals), 'little')


def unpack_result_vec_struct(word):
    return list(struct.unpack('<4i', word.to_bytes(16, 'little')))


def golden_matmul_row(a_row, w_rows):
    """a_row: 4 ints (one activation vector). w_rows[i][j]: 4x4 weight
    matrix. Returns y[j] = sum_i a_row[i]*w_rows[i][j] -- standard
    row-vector-times-matrix, matching PE(i,j)'s own i=reduction/j=feature
    indexing (see systolic_array_4x4.sv header)."""
    return [sum(a_row[i] * w_rows[i][j] for i in range(K)) for j in range(N)]


# ---------------------------------------------------------------------
# AXI4-Lite manager tasks -- same pattern as fpu_axi_periph's own suite.
# ---------------------------------------------------------------------
async def reset(dut):
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())
    dut.rst_n.value = 0
    dut.awvalid_i.value = 0
    dut.awaddr_i.value = 0
    dut.awprot_i.value = 0
    dut.wvalid_i.value = 0
    dut.wdata_i.value = 0
    dut.wstrb_i.value = 0
    dut.bready_i.value = 0
    dut.arvalid_i.value = 0
    dut.araddr_i.value = 0
    dut.arprot_i.value = 0
    dut.rready_i.value = 0
    dut.s_axis_tvalid_i.value = 0
    dut.s_axis_tdata_i.value = 0
    dut.s_axis_tlast_i.value = 0
    dut.m_axis_tready_i.value = 0
    for _ in range(4):
        await RisingEdge(dut.clk)
    dut.rst_n.value = 1
    for _ in range(2):
        await RisingEdge(dut.clk)


async def axi_write(dut, addr, data, strb=STRB_ALL):
    dut.awvalid_i.value = 1
    dut.awaddr_i.value = addr
    dut.awprot_i.value = 0
    dut.wvalid_i.value = 1
    dut.wdata_i.value = data
    dut.wstrb_i.value = strb

    aw_done = w_done = False
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
    dut.araddr_i.value = addr
    dut.arprot_i.value = 0
    dut.rready_i.value = 1

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


async def load_weights(dut, w_rows, input_src_mmio=False):
    """w_rows: 4x4 list of int8, w_rows[i][j]."""
    mode_bit = CTRL_INPUT_SRC_MMIO if input_src_mmio else 0
    bresp = await axi_write(dut, CTRL, mode_bit)
    assert bresp == 0
    for reg, row in zip((WEIGHT_ROW0, WEIGHT_ROW1, WEIGHT_ROW2, WEIGHT_ROW3), w_rows):
        bresp = await axi_write(dut, reg, pack_act_vec(row))
        assert bresp == 0
    bresp = await axi_write(dut, CTRL, mode_bit | CTRL_LOAD_WEIGHTS)
    assert bresp == 0
    for _ in range(20):
        status, resp = await axi_read(dut, STATUS)
        assert resp == 0
        if status & STATUS_WEIGHTS_LOADED and not (status & STATUS_BUSY):
            return
    raise AssertionError("weights never reported loaded")


# ---------------------------------------------------------------------
# AXI4-Stream driver/monitor -- run concurrently so the driver and monitor
# overlap in simulated time, exercising genuine pipelining (multiple
# vectors in flight), not one-at-a-time polling.
# ---------------------------------------------------------------------
async def stream_vectors(dut, vectors, tlast_idx):
    for idx, vec in enumerate(vectors):
        dut.s_axis_tdata_i.value = pack_act_vec(vec)
        dut.s_axis_tlast_i.value = 1 if idx == tlast_idx else 0
        dut.s_axis_tvalid_i.value = 1
        while True:
            await RisingEdge(dut.clk)
            if dut.s_axis_tready_o.value:
                break
    dut.s_axis_tvalid_i.value = 0
    dut.s_axis_tlast_i.value = 0


async def collect_results(dut, count, out, ready_delay_cycles=0):
    """Collect `count` result vectors from m_axis. If ready_delay_cycles>0,
    holds m_axis_tready_i low for that many cycles once the FIRST result
    appears (m_axis_tvalid_o asserts), then releases it -- exercises the
    output axis_skid's engage/drain path end-to-end (each piece already
    formally proven standalone; this confirms the wiring between them)."""
    dut.m_axis_tready_i.value = 0 if ready_delay_cycles else 1
    stalled = False
    while len(out) < count:
        await RisingEdge(dut.clk)
        if ready_delay_cycles and not stalled and dut.m_axis_tvalid_o.value:
            stalled = True
            for _ in range(ready_delay_cycles):
                await RisingEdge(dut.clk)
            dut.m_axis_tready_i.value = 1
            continue
        if dut.m_axis_tvalid_o.value and dut.m_axis_tready_i.value:
            out.append((unpack_result_vec(int(dut.m_axis_tdata_o.value)),
                        int(dut.m_axis_tlast_o.value)))


# ---------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------
@cocotb.test()
async def test_packing_helpers_cross_check(dut):
    """The two independently-implemented pack/unpack helpers must agree --
    catches a byte-order or sign-extension mixup before it can hide inside
    a golden-value comparison elsewhere."""
    samples = [[0, 0, 0, 0], [127, -128, 1, -1], [-128, -128, -128, -128], [5, -5, 100, -100]]
    for s in samples:
        assert pack_act_vec(s) == pack_act_vec_struct(s), f"pack mismatch for {s}"
    result_samples = [0, 0xDEADBEEF, (1 << 128) - 1, 0x00000001_FFFFFFFF_00000000_80000000]
    for r in result_samples:
        r &= (1 << 128) - 1
        assert unpack_result_vec(r) == unpack_result_vec_struct(r), f"unpack mismatch for 0x{r:x}"
    dut._log.info("test_packing_helpers_cross_check PASS")


@cocotb.test()
async def test_reset_state(dut):
    """After reset: STATUS reads 0 (nothing loaded, not busy, no pending result)."""
    await reset(dut)
    status, resp = await axi_read(dut, STATUS)
    assert resp == 0 and status == 0, f"STATUS not zero after reset: 0x{status:x}"
    dut._log.info("test_reset_state PASS")


@cocotb.test()
async def test_identity_probe(dut):
    """W streamed through A=I isolates every PE's weight individually in
    the output -- a skew bug (off-by-one in either direction) produces a
    specifically wrong, individually diagnosable element pattern."""
    await reset(dut)
    w_rows = [[3, -7, 12, -1], [8, 0, -4, 9], [-2, 15, 6, -11], [1, -1, 100, -100]]
    await load_weights(dut, w_rows)

    identity = [[1, 0, 0, 0], [0, 1, 0, 0], [0, 0, 1, 0], [0, 0, 0, 1]]
    results = []
    cocotb.start_soon(stream_vectors(dut, identity, tlast_idx=3))
    await collect_results(dut, 4, results)

    for m in range(4):
        golden = golden_matmul_row(identity[m], w_rows)
        got, tlast = results[m]
        assert got == golden, f"row {m}: got {got}, expected {golden} (== W row {m})"
        assert tlast == (1 if m == 3 else 0), f"row {m}: tlast={tlast}"
    dut._log.info("test_identity_probe PASS")


@cocotb.test()
async def test_random_matrix(dut):
    """Fixed-seed pseudo-random A/W, cross-checked against an independent
    golden reference -- not derived from the RTL's own arithmetic."""
    await reset(dut)
    rng = random.Random(42)
    w_rows = [[rng.randint(-20, 20) for _ in range(N)] for _ in range(K)]
    a_vecs = [[rng.randint(-20, 20) for _ in range(K)] for _ in range(4)]
    await load_weights(dut, w_rows)

    results = []
    cocotb.start_soon(stream_vectors(dut, a_vecs, tlast_idx=3))
    await collect_results(dut, 4, results)

    for m in range(4):
        golden = golden_matmul_row(a_vecs[m], w_rows)
        got, _ = results[m]
        assert got == golden, f"row {m}: got {got}, expected {golden}"
    dut._log.info("test_random_matrix PASS")


@cocotb.test()
async def test_magnitude_probe(dut):
    """All -128 activation against a weight column of all +127 -- worst
    single-output-element magnitude (4 * -128*127 = -65024), still far
    inside int32 but worth an explicit check rather than trusting a random
    seed to land on it."""
    await reset(dut)
    w_rows = [[127, 0, 0, 0]] * K
    await load_weights(dut, w_rows)

    act = [-128, -128, -128, -128]
    results = []
    cocotb.start_soon(stream_vectors(dut, [act], tlast_idx=0))
    await collect_results(dut, 1, results)

    golden = golden_matmul_row(act, w_rows)
    got, tlast = results[0]
    assert got == golden, f"got {got}, expected {golden}"
    assert got[0] == -65024, f"expected magnitude probe Y[0]=-65024, got {got[0]}"
    assert tlast == 1
    dut._log.info("test_magnitude_probe PASS")


@cocotb.test()
async def test_weight_reuse_pass(dut):
    """Load weights once, stream TWO separate TLAST-delimited passes --
    demonstrates weight-stationary's actual point (amortized weight load)
    and exercises status sequencing across multiple passes."""
    await reset(dut)
    w_rows = [[2, -3, 4, -5], [1, 1, 1, 1], [-6, 7, -8, 9], [0, 2, -2, 3]]
    await load_weights(dut, w_rows)

    pass1 = [[1, 2, 3, 4], [4, 3, 2, 1], [0, 0, 0, 0], [1, -1, 1, -1]]
    results1 = []
    cocotb.start_soon(stream_vectors(dut, pass1, tlast_idx=3))
    await collect_results(dut, 4, results1)
    for m in range(4):
        golden = golden_matmul_row(pass1[m], w_rows)
        got, tlast = results1[m]
        assert got == golden, f"pass1 row {m}: got {got}, expected {golden}"
        assert tlast == (1 if m == 3 else 0)

    status, resp = await axi_read(dut, STATUS)
    assert resp == 0
    assert status & STATUS_WEIGHTS_LOADED, "weights should still be loaded between passes"

    pass2 = [[5, -5, 5, -5], [10, 0, -10, 0], [2, 2, 2, 2], [-1, -1, -1, -1]]
    results2 = []
    cocotb.start_soon(stream_vectors(dut, pass2, tlast_idx=3))
    await collect_results(dut, 4, results2)
    for m in range(4):
        golden = golden_matmul_row(pass2[m], w_rows)
        got, tlast = results2[m]
        assert got == golden, f"pass2 row {m}: got {got}, expected {golden}"
        assert tlast == (1 if m == 3 else 0)
    dut._log.info("test_weight_reuse_pass PASS")


@cocotb.test()
async def test_output_backpressure(dut):
    """Hold m_axis_tready low briefly right as the first result appears --
    confirms the output axis_skid absorbs the stall without dropping data
    (each piece already formally proven standalone; this confirms the
    array<->skid wiring end-to-end)."""
    await reset(dut)
    w_rows = [[1, 0, 0, 0], [0, 1, 0, 0], [0, 0, 1, 0], [0, 0, 0, 1]]  # identity weights
    await load_weights(dut, w_rows)

    vecs = [[9, 8, 7, 6], [1, 2, 3, 4], [-1, -2, -3, -4]]
    results = []
    cocotb.start_soon(stream_vectors(dut, vecs, tlast_idx=2))
    await collect_results(dut, len(vecs), results, ready_delay_cycles=3)

    for m in range(len(vecs)):
        golden = golden_matmul_row(vecs[m], w_rows)
        got, _ = results[m]
        assert got == golden, f"row {m}: got {got}, expected {golden}"
    dut._log.info("test_output_backpressure PASS")


@cocotb.test()
async def test_mmio_bridge_path(dut):
    """CPU-facing push/pop path: INPUT_SRC_MMIO=1, one vector via DATA_IN,
    polled RESULT_VALID, read back via RESULT0-3 -- the least-precedented
    piece of this phase (see Phase 2 plan Sec 9 risk 3), so it gets its
    own dedicated test rather than only being exercised incidentally."""
    await reset(dut)
    w_rows = [[4, 1, 0, -2], [0, 3, 1, 0], [-1, 0, 5, 2], [2, -3, 0, 1]]
    await load_weights(dut, w_rows, input_src_mmio=True)

    act = [7, -3, 2, 9]
    status, resp = await axi_read(dut, STATUS)
    assert resp == 0
    assert status & (1 << 4) == 0, "INPUT_BUSY should be clear before any push"  # STATUS_INPUT_BUSY

    bresp = await axi_write(dut, CTRL, CTRL_INPUT_SRC_MMIO | CTRL_TLAST_NEXT)
    assert bresp == 0
    bresp = await axi_write(dut, DATA_IN, pack_act_vec(act))
    assert bresp == 0

    for _ in range(20):
        status, resp = await axi_read(dut, STATUS)
        assert resp == 0
        if status & STATUS_RESULT_VALID:
            break
        await RisingEdge(dut.clk)
    else:
        raise AssertionError("MMIO result never became valid")
    assert status & STATUS_RESULT_LAST, "TLAST_NEXT should have tagged this result RESULT_LAST"

    r0, resp0 = await axi_read(dut, RESULT0)
    r1, resp1 = await axi_read(dut, RESULT1)
    r2, resp2 = await axi_read(dut, RESULT2)
    r3, resp3 = await axi_read(dut, RESULT3)
    assert resp0 == resp1 == resp2 == resp3 == 0
    got = [r0, r1, r2, r3]
    got_signed = []
    for v in got:
        got_signed.append(v - (1 << 32) if v >= (1 << 31) else v)

    golden = golden_matmul_row(act, w_rows)
    assert got_signed == golden, f"MMIO result: got {got_signed}, expected {golden}"
    dut._log.info("test_mmio_bridge_path PASS")


@cocotb.test()
async def test_mmio_bridge_second_push(dut):
    """Regression test for a real bug found by adversarial review during
    Phase 2 SoC integration: the original design relied on a new DATA_IN
    push to implicitly clear the prior MMIO result (mmio_result_valid_q),
    but mmio_data_in_ready_o -- and therefore a push's acceptance -- was
    itself gated on that same flag already being clear. That is a same-
    cycle deadlock: the MMIO bridge could accept exactly one push, ever,
    and STATUS.INPUT_BUSY would latch high permanently on any second
    operation. test_mmio_bridge_path above never caught this because it
    only ever does ONE push. This test does two, with an explicit
    CTRL.RESULT_ACK between them (the fix), and would hang forever on the
    pre-fix RTL."""
    await reset(dut)
    w_rows = [[4, 1, 0, -2], [0, 3, 1, 0], [-1, 0, 5, 2], [2, -3, 0, 1]]
    await load_weights(dut, w_rows, input_src_mmio=True)

    async def push_and_check(act, tag):
        bresp = await axi_write(dut, CTRL, CTRL_INPUT_SRC_MMIO | CTRL_TLAST_NEXT)
        assert bresp == 0
        bresp = await axi_write(dut, DATA_IN, pack_act_vec(act))
        assert bresp == 0

        for _ in range(20):
            status, resp = await axi_read(dut, STATUS)
            assert resp == 0
            if status & STATUS_RESULT_VALID:
                break
            await RisingEdge(dut.clk)
        else:
            raise AssertionError(f"{tag}: MMIO result never became valid")

        r0, resp0 = await axi_read(dut, RESULT0)
        r1, resp1 = await axi_read(dut, RESULT1)
        r2, resp2 = await axi_read(dut, RESULT2)
        r3, resp3 = await axi_read(dut, RESULT3)
        assert resp0 == resp1 == resp2 == resp3 == 0
        got = [r0, r1, r2, r3]
        got_signed = [v - (1 << 32) if v >= (1 << 31) else v for v in got]
        golden = golden_matmul_row(act, w_rows)
        assert got_signed == golden, f"{tag}: got {got_signed}, expected {golden}"

    await push_and_check([7, -3, 2, 9], "first push")

    status, resp = await axi_read(dut, STATUS)
    assert resp == 0
    assert status & STATUS_INPUT_BUSY, (
        "INPUT_BUSY should be set while the first result is still unread"
    )

    # The fix under test: an explicit ack, not a second push, is what
    # clears the latched result and restores mmio_data_in_ready_o.
    bresp = await axi_write(dut, CTRL, CTRL_INPUT_SRC_MMIO | CTRL_RESULT_ACK)
    assert bresp == 0
    await RisingEdge(dut.clk)

    status, resp = await axi_read(dut, STATUS)
    assert resp == 0
    assert not (status & STATUS_INPUT_BUSY), (
        "INPUT_BUSY should clear after RESULT_ACK -- if this fails, the "
        "one-shot MMIO deadlock has regressed"
    )

    await push_and_check([1, 2, -3, 4], "second push")
    dut._log.info("test_mmio_bridge_second_push PASS")
