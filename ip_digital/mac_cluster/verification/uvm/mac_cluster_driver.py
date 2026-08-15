"""MacClusterDriver -- drives mac_cluster's single AXI4-Lite slave port from a
MacClusterSeqItem stream.

Address map, axi_write/axi_read, load_tile_weights, ni_push_entry and
ni_poll_and_read_exit are reused verbatim from
ip_digital/mac_cluster/verification/test_mac_cluster.py (the Phase 3
standalone P3/P4 vehicle) rather than reinventing AXI beats -- same reuse
discipline this repo already applies elsewhere (see mac_cluster/REPORT.md).

There is exactly one physical AXI4-Lite port (mac_cluster.sv), so this is
one driver regardless of how many logical per-tile sequences a virtual
sequence forks concurrently -- pyuvm's sequencer arbitration serializes
their items onto this one driver, same as any single-port DUT.

The driver publishes ENTRY_PUSH acceptance and POLL_EXIT results via its own
analysis ports rather than a separate bus-snooping monitor: it already
performs every AXI beat itself, so it is the direct, first-hand source of
"what the CPU-visible side observed." The genuinely independent monitor
(mac_cluster_monitor.py's MacClusterHierMonitor) samples RTL-internal state
hierarchically -- a ground truth the driver's own CPU-visible view cannot by
construction cross-check itself. See mac_cluster_env.py for how those two
channels reach the scoreboard.
"""
import random
from cocotb.triggers import RisingEdge
from cocotb.utils import get_sim_time
from pyuvm import uvm_driver, uvm_analysis_port, ConfigDB

from mac_cluster_seq_item import (
    OP_WEIGHT_LOAD, OP_ENTRY_PUSH, OP_POLL_EXIT, OP_RAW_CSR_WRITE, OP_RAW_CSR_READ,
)

STRB_ALL = 0xF


def tile_page_addr(tile, offset):
    return (tile << 8) | offset


CSR_PAGE = 4


def csr_addr(tile, reg):
    return (CSR_PAGE << 8) + (tile * 8 + reg) * 4


TILE_CTRL, TILE_STATUS = 0x00, 0x04
TILE_WEIGHT_ROW0, TILE_WEIGHT_ROW1, TILE_WEIGHT_ROW2, TILE_WEIGHT_ROW3 = 0x08, 0x0C, 0x10, 0x14

NI_CTRL, NI_STATUS, NI_DEST, NI_ENTRY_DATA = 0, 1, 2, 3
NI_EXIT_RESULT0, NI_EXIT_RESULT1, NI_EXIT_RESULT2, NI_EXIT_RESULT3 = 4, 5, 6, 7

NI_CTRL_ENTRY_PUSH     = 1 << 0
NI_CTRL_TLAST_NEXT     = 1 << 1
NI_CTRL_MESH_EGRESS_EN = 1 << 2
NI_CTRL_EXIT_ACK       = 1 << 3

NI_STATUS_ENTRY_BUSY = 1 << 0
NI_STATUS_EXIT_VALID = 1 << 1
NI_STATUS_EXIT_LAST  = 1 << 2
NI_STATUS_EXIT_SEQ   = 1 << 3

TILE_STATUS_WEIGHTS_LOADED = 1 << 0
TILE_STATUS_BUSY           = 1 << 1
TILE_CTRL_LOAD_WEIGHTS     = 1 << 0


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


class EntryAccepted:
    __slots__ = ("tile", "dest_x", "dest_y", "act_vec", "mesh_egress_en")

    def __init__(self, tile, dest_x, dest_y, act_vec, mesh_egress_en):
        self.tile, self.dest_x, self.dest_y = tile, dest_x, dest_y
        self.act_vec, self.mesh_egress_en = act_vec, mesh_egress_en


class ExitCaptured:
    __slots__ = ("tile", "result", "seq", "rejected")

    def __init__(self, tile, result, seq, rejected):
        self.tile, self.result, self.seq, self.rejected = tile, result, seq, rejected


class OpExecuted:
    """Generic per-op event, one per driven transaction regardless of op
    type -- entry_ap/exit_ap carry richer op-specific data for the
    scoreboard, this is the uniform channel cp_op/cp_tile/cp_weight_class
    coverage (mac_cluster_coverage.py) subscribes to instead of needing
    four different subscriptions for four different op shapes."""
    __slots__ = ("op", "tile", "weight_class")

    def __init__(self, op, tile, weight_class=None):
        self.op, self.tile, self.weight_class = op, tile, weight_class


class PollObservation:
    """Every STATUS read inside a POLL_EXIT that saw EXIT_VALID=1 (accepted
    OR rejected as stale) -- offset_cycles is the signed distance from the
    hierarchical monitor's nearest exit_seq_q toggle for this tile, the
    real ground-truth event this poll was (successfully or not) trying to
    observe. Feeds cp_poll_to_transition_offset (mac_cluster_coverage.py):
    {-1,0,+1} is Bug 4's actual danger zone."""
    __slots__ = ("tile", "offset_cycles", "accepted")

    def __init__(self, tile, offset_cycles, accepted):
        self.tile, self.offset_cycles, self.accepted = tile, offset_cycles, accepted


class MacClusterDriver(uvm_driver):
    CLK_PERIOD_NS = 10.0

    def build_phase(self):
        self.dut = ConfigDB().get(self, "", "DUT")
        # Optional: only present once mac_cluster_env.py registers it
        # (checkpoint 6+) -- None-guarded everywhere it's used below so
        # earlier checkpoints' tests (which don't need this channel) still
        # work unchanged.
        self.hier_mon = ConfigDB().get(self, "", "HIER_MON", default=None)
        self.entry_ap = uvm_analysis_port("entry_ap", self)
        self.exit_ap  = uvm_analysis_port("exit_ap", self)
        self.op_ap    = uvm_analysis_port("op_ap", self)
        self.poll_observation_ap = uvm_analysis_port("poll_observation_ap", self)
        # last-consumed exit_seq per tile, needed by POLL_EXIT items that
        # don't explicitly set last_seq (e.g. random closure traffic) --
        # exit_seq_q's own reset value is 0, matching this default.
        self._last_seq = {0: 0, 1: 0, 2: 0, 3: 0}
        # Grafted from Architecture A (checkpoint 6): per-beat randomized
        # idle delay before AWVALID/ARVALID and before BREADY/RREADY,
        # replacing the fixed-cadence assert-immediately pattern every
        # existing test uses -- directly stresses the AXI read-cadence
        # dependency mac_cluster/REPORT.md names as Bug 4's actual trigger
        # (a torn read only happened at a SPECIFIC poll timing, not any
        # timing). Off by default -- the test/sequence opts in explicitly
        # so directed tests keep their exact original beat timing.
        self.randomize_backpressure = False

    async def _maybe_delay(self):
        if self.randomize_backpressure:
            for _ in range(random.randint(0, 3)):
                await RisingEdge(self.dut.clk)

    async def run_phase(self):
        self.dut.awvalid_i.value = 0
        self.dut.wvalid_i.value  = 0
        self.dut.bready_i.value  = 0
        self.dut.arvalid_i.value = 0
        self.dut.rready_i.value  = 0

        while True:
            item = await self.seq_item_port.get_next_item()
            if item.op == OP_WEIGHT_LOAD:
                await self._do_weight_load(item)
            elif item.op == OP_ENTRY_PUSH:
                await self._do_entry_push(item)
            elif item.op == OP_POLL_EXIT:
                await self._do_poll_exit(item)
            elif item.op in (OP_RAW_CSR_WRITE, OP_RAW_CSR_READ):
                await self._do_raw_csr(item)
            else:
                raise ValueError(f"MacClusterDriver: unknown op {item.op}")
            self.op_ap.write(OpExecuted(item.op, item.tile, item.weight_class))
            self.seq_item_port.item_done()

    # ── AXI4-Lite primitives (verbatim from test_mac_cluster.py) ───────────

    async def axi_write(self, addr, data, strb=STRB_ALL):
        dut = self.dut
        await self._maybe_delay()
        dut.awvalid_i.value = 1
        dut.awaddr_i.value  = addr
        dut.awprot_i.value  = 0
        dut.wvalid_i.value  = 1
        dut.wdata_i.value   = data
        dut.wstrb_i.value   = strb
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
        await self._maybe_delay()
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

    async def axi_read(self, addr):
        dut = self.dut
        await self._maybe_delay()
        dut.arvalid_i.value = 1
        dut.araddr_i.value  = addr
        dut.arprot_i.value  = 0
        dut.rready_i.value  = 1
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

    # ── op handlers ─────────────────────────────────────────────────────

    async def _do_weight_load(self, item):
        for row_idx, reg_off in enumerate((TILE_WEIGHT_ROW0, TILE_WEIGHT_ROW1,
                                            TILE_WEIGHT_ROW2, TILE_WEIGHT_ROW3)):
            bresp = await self.axi_write(tile_page_addr(item.tile, reg_off),
                                          pack_act_vec(item.weight_rows[row_idx]))
            assert bresp == 0
        # Sampled as the LAST action before the actual LOAD_WEIGHTS write --
        # the observable closest to the real weight_we_gated decision
        # (axi4stream_ctrl.sv's weight_we_gated = weight_we_i && !busy_comb,
        # evaluated at THIS write's own commit, not several writes earlier).
        # A probe taken before the 4 preceding row writes above would be
        # stale by the time this write actually lands -- confirmed the hard
        # way: ReloadWhileBusySeq used to probe first and reload_seq.body()
        # discarded the timing gap, which silently desynced
        # MacClusterClosureSeq's reference model from real RTL state (see
        # that class's own docstring). Still not a perfect guarantee (a few
        # cycles of AXI handshake separate this read from the actual
        # commit) -- reference-model correctness does not rely on this
        # value; it exists for ReloadWhileBusySeq's own observed_busy
        # coverage classification, a best-effort signal, documented as such.
        status, resp = await self.axi_read(tile_page_addr(item.tile, TILE_STATUS))
        assert resp == 0
        item.observed_busy_at_commit = bool(status & TILE_STATUS_BUSY)
        bresp = await self.axi_write(tile_page_addr(item.tile, TILE_CTRL),
                                      TILE_CTRL_LOAD_WEIGHTS)
        assert bresp == 0
        for _ in range(item.__dict__.get("timeout", 30)):
            status, resp = await self.axi_read(tile_page_addr(item.tile, TILE_STATUS))
            assert resp == 0
            if status & TILE_STATUS_WEIGHTS_LOADED:
                return
            await RisingEdge(self.dut.clk)
        # Bounded timeout, not an exception -- same reasoning as
        # _do_entry_push's own item.starved convention: raising here would
        # kill the driver's one shared run_phase coroutine for every
        # subsequent item in the test, not just this one.
        self.logger.warning(f"tile {item.tile}: weights never reported loaded within "
                             f"{item.__dict__.get('timeout', 30)} iterations")
        item.starved = True

    async def _do_entry_push(self, item):
        # Write order matters: NI_ENTRY_DATA before NI_CTRL's ENTRY_PUSH bit
        # (edge-pulsed off the CTRL write, latches ENTRY_DATA at that
        # moment) -- see test_mac_cluster.py's own ni_push_entry() header
        # comment for the real bug this ordering fixes.
        bresp = await self.axi_write(csr_addr(item.tile, NI_DEST),
                                      (item.dest_y << 1) | item.dest_x)
        assert bresp == 0
        bresp = await self.axi_write(csr_addr(item.tile, NI_ENTRY_DATA),
                                      pack_act_vec(item.act_vec))
        assert bresp == 0
        ctrl = NI_CTRL_ENTRY_PUSH | NI_CTRL_TLAST_NEXT
        if item.mesh_egress_en:
            ctrl |= NI_CTRL_MESH_EGRESS_EN
        bresp = await self.axi_write(csr_addr(item.tile, NI_CTRL), ctrl)
        assert bresp == 0
        # Published here, right after the CTRL write's own commit -- NOT
        # gated behind confirmed acceptance below. entry_push_i's own set
        # condition in tile_ni.sv is `entry_push_i && !entry_pending_q`: if
        # entry_pending_q was already 1 at this exact commit (a PRIOR
        # push to this same tile still stuck pending -- structurally
        # possible whenever a caller reuses the same tile across
        # iterations without confirming the prior one drained, e.g.
        # ConcurrentEgressReconfigSeq's own push_own always targets the
        # same CONSUMER_TILE), THIS write is a silent no-op: entry_data_q
        # keeps the OLDER push's data, not this item's own. Gating
        # entry_ap on "my own poll later saw !ENTRY_BUSY" cannot tell
        # those two cases apart -- confirmed the hard way: it produced a
        # real scoreboard "unexpected" mismatch (not a stale-read, not a
        # timeout -- a genuine wrong-value observation) whose true cause
        # was a LATER item's poll observing an EARLIER, previously-starved
        # item's own push finally being served, and mis-attributing that
        # service to itself. Publishing here instead describes what's
        # actually true at this exact moment: this item's data has been
        # submitted to the CSR and its processing has begun -- ambiguity
        # about whose data is ACTUALLY in flight is a genuine, structural
        # RTL race this sequence layer must not paper over by pretending
        # the ambiguity doesn't exist.
        self.entry_ap.write(EntryAccepted(item.tile, item.dest_x, item.dest_y,
                                            list(item.act_vec), item.mesh_egress_en))
        for _ in range(item.__dict__.get("timeout", 50)):
            status, resp = await self.axi_read(csr_addr(item.tile, NI_STATUS))
            assert resp == 0
            if not (status & NI_STATUS_ENTRY_BUSY):
                return
            await RisingEdge(self.dut.clk)
        # Bounded timeout, not an exception: this driver's run_phase is one
        # shared coroutine for the whole test -- raising here would kill it
        # for every subsequent item, not just this one (confirmed the hard
        # way: a try/except wrapped around the calling sequence's own
        # start() call cannot catch an exception raised from inside the
        # driver's own independent run_phase task). Write the outcome back
        # onto the item instead, same as result/result_seq/result_rejected.
        # entry_ap was already published above regardless -- this item's
        # own data is still genuinely pending in the RTL (or was silently
        # dropped by a still-pending prior push to the same tile, per this
        # method's own comment above); either way, giving up polling here
        # does not mean the entry never happened.
        self.logger.warning(f"tile {item.tile}: entry push not accepted within "
                             f"{item.__dict__.get('timeout', 50)} iterations")
        item.starved = True

    async def _do_poll_exit(self, item):
        """Poll NI_STATUS until EXIT_VALID=1 AND EXIT_SEQ differs from the
        last-consumed seq for this tile -- EXIT_VALID alone is not
        sufficient (exit_valid_q can go 1->0->1 within a single cycle if a
        new result is already queued, faster than a multi-cycle AXI read
        can reliably observe the intermediate 0). See tile_ni.sv's own
        exit_seq_q header comment and mac_cluster/REPORT.md for the real
        race this discriminator fixes."""
        last_seq = item.last_seq if item.last_seq is not None else self._last_seq[item.tile]
        rejected = 0
        for _ in range(item.__dict__.get("timeout", 200)):
            status, resp = await self.axi_read(csr_addr(item.tile, NI_STATUS))
            assert resp == 0
            seq = 1 if (status & NI_STATUS_EXIT_SEQ) else 0
            if (status & NI_STATUS_EXIT_VALID) and self.hier_mon is not None:
                now_ns = get_sim_time(unit="ns")
                offset_ns = now_ns - self.hier_mon.last_toggle_time_ns[item.tile]
                offset_cycles = round(offset_ns / self.CLK_PERIOD_NS)
                self.poll_observation_ap.write(
                    PollObservation(item.tile, offset_cycles, accepted=(seq != last_seq)))
            if (status & NI_STATUS_EXIT_VALID) and seq != last_seq:
                r0, resp0 = await self.axi_read(csr_addr(item.tile, NI_EXIT_RESULT0))
                r1, resp1 = await self.axi_read(csr_addr(item.tile, NI_EXIT_RESULT1))
                r2, resp2 = await self.axi_read(csr_addr(item.tile, NI_EXIT_RESULT2))
                r3, resp3 = await self.axi_read(csr_addr(item.tile, NI_EXIT_RESULT3))
                assert resp0 == resp1 == resp2 == resp3 == 0
                got = [r0, r1, r2, r3]
                got_signed = [v - (1 << 32) if v >= (1 << 31) else v for v in got]
                bresp = await self.axi_write(csr_addr(item.tile, NI_CTRL), NI_CTRL_EXIT_ACK)
                assert bresp == 0
                self._last_seq[item.tile] = seq
                item.result, item.result_seq, item.result_rejected = got_signed, seq, rejected
                self.exit_ap.write(ExitCaptured(item.tile, got_signed, seq, rejected))
                return
            if status & NI_STATUS_EXIT_VALID:
                rejected += 1
            await RisingEdge(self.dut.clk)
        # Bounded timeout, not an exception -- same reasoning as
        # _do_entry_push/_do_weight_load's own item.starved convention.
        # This driver method is now used in genuinely racy contexts (e.g.
        # test_race_adjacent.py polling a tile whose own array may still be
        # recovering from a buffer-overflow class documented in
        # ConcurrentEgressReconfigSeq) where a real, non-bug timeout is
        # plausible -- a raise here would have killed the shared driver
        # coroutine for every item after it, not just this poll.
        self.logger.warning(f"tile {item.tile}: exit result never became valid (fresh seq) "
                             f"within {item.__dict__.get('timeout', 200)} iterations")
        item.starved = True

    async def _do_raw_csr(self, item):
        if item.op == OP_RAW_CSR_WRITE:
            await self.axi_write(item.addr, item.data)
        else:
            data, resp = await self.axi_read(item.addr)
            # Reuse the .result field (POLL_EXIT's own result-writeback
            # convention, see docstring on MacClusterSeqItem) rather than
            # adding a third result field just for this op.
            item.result = data
