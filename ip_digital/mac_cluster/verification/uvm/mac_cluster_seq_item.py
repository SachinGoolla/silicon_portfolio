"""MacClusterSeqItem -- transaction object for mac_cluster's UVM tier.

Field randomization is plain random.randint()/random.choice() per field, one
randomize_<op>() method per op type -- same shape as fpu_top's own
FPUSeqItem.randomize_fma()/randomize_noncomp() (see
ip_digital/fpu/fpu_top/verification/uvm/fpu_seq_item.py). No cocotb-coverage
dependency: this repo's own existing UVM tier already proves a hand-rolled
generator is sufficient for discrete, small-domain fields like these.
"""
import random
from pyuvm import uvm_sequence_item

OP_WEIGHT_LOAD   = "WEIGHT_LOAD"
OP_ENTRY_PUSH    = "ENTRY_PUSH"
OP_POLL_EXIT     = "POLL_EXIT"
OP_RAW_CSR_WRITE = "RAW_CSR_WRITE"
OP_RAW_CSR_READ  = "RAW_CSR_READ"

WCLASS_IDENTITY_SCALED = "identity_scaled"
WCLASS_RANDOM_NONSYM   = "random_nonsym"
WCLASS_SAT_POS         = "sat_pos"
WCLASS_SAT_NEG         = "sat_neg"
WCLASS_ZERO            = "zero"

WEIGHT_CLASSES = [
    WCLASS_IDENTITY_SCALED, WCLASS_RANDOM_NONSYM,
    WCLASS_SAT_POS, WCLASS_SAT_NEG, WCLASS_ZERO,
]

K = N = 4


def gen_weight_rows(weight_class):
    """4x4 int8-range weight matrix for the given class. Deliberately
    non-symmetric for every class except IDENTITY_SCALED/ZERO (a symmetric
    matrix can't expose a transpose bug on its own -- mac_tile_axi's own
    REPORT.md notes this the hard way)."""
    if weight_class == WCLASS_IDENTITY_SCALED:
        scale = random.randint(3, 8)
        return [[scale if i == j else 0 for j in range(N)] for i in range(K)]
    if weight_class == WCLASS_ZERO:
        return [[0] * N for _ in range(K)]
    if weight_class == WCLASS_SAT_POS:
        return [[random.randint(15, 25) for _ in range(N)] for _ in range(K)]
    if weight_class == WCLASS_SAT_NEG:
        return [[random.randint(-25, -15) for _ in range(N)] for _ in range(K)]
    # WCLASS_RANDOM_NONSYM
    return [[random.randint(-20, 20) for _ in range(N)] for _ in range(K)]


def gen_act_vec():
    return [random.randint(-128, 127) for _ in range(4)]


class MacClusterSeqItem(uvm_sequence_item):
    """One transaction: an op plus whatever fields that op needs. The
    driver (mac_cluster_driver.py) decomposes each op into the underlying
    multi-beat AXI4-Lite sequence -- a coarse-grained item, not one item per
    AXI beat, so concurrently-forked per-tile sequences on the single
    physical sequencer can't interleave beats mid-transaction."""

    def __init__(self, name="mac_cluster_seq_item"):
        super().__init__(name)
        self.op = OP_RAW_CSR_READ
        self.tile = 0
        self.dest_x = 0
        self.dest_y = 0
        self.weight_class = WCLASS_RANDOM_NONSYM
        self.weight_rows = None
        self.act_vec = None
        self.addr = 0
        self.data = 0
        self.last_seq = 0        # POLL_EXIT: last-consumed exit_seq for this tile
        self.mesh_egress_en = 1  # ENTRY_PUSH: 0 = local loopback, never touches the mesh

        # POLL_EXIT result, written back onto this SAME object by the driver
        # (item is passed by reference through start_item/finish_item) so a
        # sequence can read what actually happened immediately after
        # finish_item() returns -- e.g. to correctly chain last_seq into
        # its own next iteration instead of tracking it independently and
        # risking desync with the driver's own view.
        self.result = None
        self.result_seq = None
        self.result_rejected = None
        # ENTRY_PUSH/WEIGHT_LOAD: set True by the driver if the operation
        # didn't complete within item.timeout iterations, instead of
        # raising -- the driver's run_phase is one shared coroutine for the
        # whole test, so an exception there would kill every subsequent
        # item, not just this one. Checked by the calling sequence after
        # finish_item() returns.
        self.starved = False
        # WEIGHT_LOAD: STATUS.BUSY sampled by the driver as the LAST action
        # before the actual LOAD_WEIGHTS write -- the observable closest to
        # axi4stream_ctrl.sv's real weight_we_gated decision. Best-effort,
        # not a guarantee (see mac_cluster_driver.py's _do_weight_load).
        self.observed_busy_at_commit = None

    def randomize_weight_load(self, tile=None, weight_class=None):
        self.op = OP_WEIGHT_LOAD
        self.tile = tile if tile is not None else random.randint(0, 3)
        self.weight_class = weight_class or random.choice(WEIGHT_CLASSES)
        self.weight_rows = gen_weight_rows(self.weight_class)
        return self

    def randomize_entry_push(self, src=None, dest=None, mesh_egress_en=None):
        """mesh_egress_en governs tile_ni.sv's EGRESS mux, not the entry
        path (confirmed by reading tile_ni.sv directly, not assumed from
        naming): after `src` tile computes on the pushed activation,
        mesh_egress_en=1 forwards ITS OWN result into the mesh addressed to
        (dest_x,dest_y); mesh_egress_en=0 captures it locally in src's own
        exit registers instead, and dest_x/dest_y are simply unused. This
        is the real "loopback" class -- CPU push and read-back at the same
        tile with zero mesh involvement, never exercised by the existing
        directed test (tile 3 there sits at mesh_egress_en's reset default
        but is only ever a mesh-delivered consumer, never CPU-pushed).

        dest==src with mesh_egress_en=1 is a real, distinct third case (the
        forwarded result XY-routes to "Local" and re-enters src's own
        ingress mux via the mesh a second time) with genuinely open
        re-triggering behavior not characterized this checkpoint --
        deliberately excluded from random selection here rather than
        silently assumed safe; a future checkpoint can investigate it
        explicitly if warranted."""
        self.op = OP_ENTRY_PUSH
        self.tile = src if src is not None else random.randint(0, 3)
        if mesh_egress_en is not None:
            self.mesh_egress_en = int(mesh_egress_en)
        else:
            self.mesh_egress_en = random.choice([0, 1])
        if dest is not None:
            self.dest_x, self.dest_y = dest
        elif self.mesh_egress_en:
            # Avoid dest==src while mesh_egress_en=1 -- the open, uninvestigated
            # self-loop case above -- by resampling away from it.
            while True:
                dx, dy = random.randint(0, 1), random.randint(0, 1)
                if (dx, dy) != (self.tile % 2, self.tile // 2):
                    self.dest_x, self.dest_y = dx, dy
                    break
        else:
            self.dest_x, self.dest_y = 0, 0   # unused when mesh_egress_en=0
        self.act_vec = gen_act_vec()
        return self

    def randomize_poll_exit(self, tile=None, last_seq=0):
        self.op = OP_POLL_EXIT
        self.tile = tile if tile is not None else random.randint(0, 3)
        self.last_seq = last_seq
        return self

    def randomize_raw_csr(self, write, addr=None, data=None):
        self.op = OP_RAW_CSR_WRITE if write else OP_RAW_CSR_READ
        self.addr = addr if addr is not None else random.randint(0, 0x7FF) & ~0x3
        self.data = data if data is not None else random.getrandbits(32)
        return self

    def convert2string(self):
        return (f"MacClusterSeqItem op={self.op} tile={self.tile} "
                f"dest=({self.dest_x},{self.dest_y}) weight_class={self.weight_class}")
