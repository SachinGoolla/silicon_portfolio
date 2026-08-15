"""test_directed.py -- pyuvm directed tests for mac_cluster.

test_env_boot (checkpoint 2): the smallest possible smoke test -- confirms
MacClusterEnv instantiates on the real composed netlist, the driver can
execute one raw CSR read through the single AXI4-Lite port, and the
hierarchical monitor's generate-block signal reads (dut.g_tile[t].u_ni.*)
succeed without raising, before anything else in this UVM tier depends on
that capability. See the Phase 4 plan's checkpoint 0/2.

test_two_producer_chain (checkpoint 4): the existing standalone P3/P4
scenario (two concurrent producers -> one consumer, exercising a genuine XY
turn and real link contention) ported into this env with full scoreboard
checking -- added once mac_cluster_scoreboard.py/mac_cluster_ref.py exist.
"""
import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, Timer
from pyuvm import uvm_test, uvm_sequence, uvm_root, ConfigDB

from mac_cluster_env import MacClusterEnv
from mac_cluster_seq_item import MacClusterSeqItem


class _BootProbeSeq(uvm_sequence):
    """One raw CSR read -- the smallest possible real transaction."""

    async def body(self):
        item = MacClusterSeqItem("boot_probe").randomize_raw_csr(write=False, addr=0x0004)
        await self.start_item(item)
        await self.finish_item(item)


async def _reset(dut):
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
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


class MacClusterBootTest(uvm_test):
    def build_phase(self):
        self.env = MacClusterEnv.create("env", self)

    async def run_phase(self):
        self.raise_objection()
        seq = _BootProbeSeq("boot_probe_seq")
        await seq.start(self.env.sequencer)
        # A few more clocks so the hierarchical monitor (sampling every
        # edge in the background) has taken at least one real sample of
        # every tile before we declare success.
        await Timer(50, unit="ns")
        self.drop_objection()

    def report_phase(self):
        self.logger.info("MacClusterBootTest: env instantiated, one raw CSR "
                          "read completed, hierarchical monitor ran without error.")


@cocotb.test()
async def test_env_boot(dut):
    """Smallest possible smoke test: env boots, driver executes one raw
    CSR read, hierarchical monitor reads g_tile[t].u_ni.* without error."""
    await _reset(dut)
    ConfigDB().set(None, "*", "DUT", dut)
    await uvm_root().run_test("MacClusterBootTest", keep_singletons=True)


# ─────────────────────────────────────────── test_two_producer_chain

class _WeightLoadItemSeq(uvm_sequence):
    """Loads an explicit, caller-provided weight matrix (not randomized) --
    used to reproduce test_mac_cluster.py's own fixed W0/W1/W3 exactly, so
    this port can be checked against the same known-correct golden values
    the original directed test already established."""

    def __init__(self, name, tile, weight_rows):
        super().__init__(name)
        self.tile, self.weight_rows = tile, weight_rows

    async def body(self):
        item = MacClusterSeqItem(f"wload_fixed_t{self.tile}")
        item.op = "WEIGHT_LOAD"
        item.tile = self.tile
        item.weight_rows = self.weight_rows
        await self.start_item(item)
        await self.finish_item(item)


class _PushSeq(uvm_sequence):
    def __init__(self, name, src, dest_x, dest_y, act_vec):
        super().__init__(name)
        self.src, self.dest_x, self.dest_y, self.act_vec = src, dest_x, dest_y, act_vec

    async def body(self):
        item = MacClusterSeqItem(f"push_fixed_t{self.src}").randomize_entry_push(
            src=self.src, dest=(self.dest_x, self.dest_y), mesh_egress_en=1)
        item.act_vec = self.act_vec   # override the randomized vector with the fixed one
        await self.start_item(item)
        await self.finish_item(item)


class _PollSeq(uvm_sequence):
    def __init__(self, name, tile, last_seq):
        super().__init__(name)
        self.tile, self.last_seq = tile, last_seq
        self.result_seq = None

    async def body(self):
        item = MacClusterSeqItem(f"poll_fixed_t{self.tile}").randomize_poll_exit(
            tile=self.tile, last_seq=self.last_seq)
        await self.start_item(item)
        await self.finish_item(item)
        self.result_seq = item.result_seq


class MacClusterTwoProducerTest(uvm_test):
    """Same scenario, same golden weights/activations as
    test_mac_cluster.py's own test_two_producer_chain, ported into this
    env: two concurrent producers (tiles 0,1) -> one consumer (tile 3),
    exercising a genuine XY turn and real link contention. Checks the new
    env/driver/scoreboard reproduce the SAME known-correct result the
    original directed cocotb test already established, not just "no
    exception was raised.\""""

    W0 = [[20, 5, -3, 8], [-15, 10, 6, -2], [7, -12, 15, 3], [4, 6, -8, 11]]
    A0 = [100, -80, 60, -40]
    W1 = [[25, -6, 4, 9], [12, -18, 7, -3], [-9, 14, -20, 5], [6, -8, 10, -15]]
    A1 = [-100, 90, -70, 50]
    W3 = [[2, 1, -1, 3], [0, -2, 4, 1], [-1, 3, 0, -2], [1, 0, 2, -3]]
    W2_UNUSED = [[1, 0, 0, 1], [0, 1, 1, 0], [1, 1, 0, 0], [0, 0, 1, 1]]

    def build_phase(self):
        self.env = MacClusterEnv.create("env", self)

    async def run_phase(self):
        self.raise_objection()
        sb = self.env.scoreboard

        for tile, w in ((0, self.W0), (1, self.W1), (2, self.W2_UNUSED), (3, self.W3)):
            await _WeightLoadItemSeq(f"wload_{tile}", tile, w).start(self.env.sequencer)
            sb.load_weights(tile, w)
            self.env.coverage.load_weights(tile, w)

        await _PushSeq("push_0", src=0, dest_x=1, dest_y=1, act_vec=self.A0).start(self.env.sequencer)
        await _PushSeq("push_1", src=1, dest_x=1, dest_y=1, act_vec=self.A1).start(self.env.sequencer)

        poll_a = _PollSeq("poll_a", tile=3, last_seq=0)
        await poll_a.start(self.env.sequencer)
        poll_b = _PollSeq("poll_b", tile=3, last_seq=poll_a.result_seq)
        await poll_b.start(self.env.sequencer)

        await Timer(50, unit="ns")   # let the scoreboard's two drain loops settle
        self.drop_objection()

    def report_phase(self):
        sb = self.env.scoreboard
        violations = sb.stale_read_violations()
        self.logger.info(f"MacClusterTwoProducerTest: {sb.matched} matched, "
                          f"{sb.unexpected} unexpected, "
                          f"{sum(v for v in sb.expected.values() if v > 0)} never arrived, "
                          f"stale_read_violations={violations}")
        if sb.failed:
            self.logger.critical(f"MacClusterTwoProducerTest FAILED: {sb.failed} scoreboard mismatches "
                                  f"(includes stale_read_violations={violations})")
            assert False, f"{sb.failed} scoreboard mismatches"


@cocotb.test()
async def test_two_producer_chain(dut):
    """Two concurrent producers (tiles 0,1) -> one consumer (tile 3),
    ported from test_mac_cluster.py's own proven scenario into this UVM
    env, checked against the same golden values via the new multiset
    scoreboard."""
    await _reset(dut)
    ConfigDB().set(None, "*", "DUT", dut)
    await uvm_root().run_test("MacClusterTwoProducerTest", keep_singletons=True)
