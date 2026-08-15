"""mac_cluster_ref.py -- independent Python reference model, no shared code
with the RTL's own arithmetic. golden_matmul/golden_requant are the same
independently-derived functions test_mac_cluster.py already established
(arithmetic-right-shift-then-saturate, matching requant.sv's own formal
proof), reused verbatim per this portfolio's own-oracle discipline.

Scope, stated explicitly: single-hop only (source computes, optionally
forwards through one requant hop to a destination whose own
mesh_egress_en is assumed 0). Multi-hop daisy-chains (a destination whose
OWN mesh_egress_en happens to be stale-set to 1, forwarding a second time)
are a real, distinct RTL path this model does not attempt to predict --
see mac_cluster_seq_item.py's randomize_entry_push() docstring for why the
sequence layer avoids generating that scenario in the first place, rather
than this model silently guessing at it.
"""

K = N = 4
MESH_DIM = 2


def golden_matmul(a_row, w_rows):
    return [sum(a_row[i] * w_rows[i][j] for i in range(K)) for j in range(N)]


def golden_requant(vals, shift=4):
    out = []
    for v in vals:
        shifted = v >> shift   # Python's >> on int is arithmetic (floor), matching >>>
        if shifted > 127:
            shifted = 127
        elif shifted < -128:
            shifted = -128
        out.append(shifted)
    return out


def tile_of(dest_x, dest_y):
    return dest_y * MESH_DIM + dest_x


class TileState:
    def __init__(self):
        self.weight_rows = None


class MacClusterRefModel:
    """Tracks per-tile weight state (mirroring the RTL's own weight-
    stationary reuse across pushes) and computes expected exit results."""

    def __init__(self):
        self.tiles = {t: TileState() for t in range(4)}

    def load_weights(self, tile, weight_rows):
        self.tiles[tile].weight_rows = [row[:] for row in weight_rows]

    def expected_local(self, src, act_vec):
        """mesh_egress_en=0: src computes and captures locally -- no
        requant (requant only happens on mesh ingress, never on a result
        that stays local)."""
        w = self.tiles[src].weight_rows
        assert w is not None, f"tile {src}: no weights loaded in reference model"
        return golden_matmul(list(act_vec), w)

    def expected_forwarded(self, src, dest_x, dest_y, act_vec):
        """mesh_egress_en=1: src computes, the raw int32 result forwards
        through the mesh unmodified, the destination's ingress requantizes
        it to int8 before using it as its own activation, dest computes and
        captures (dest's own mesh_egress_en assumed 0 -- see module
        docstring)."""
        w_src = self.tiles[src].weight_rows
        assert w_src is not None, f"tile {src}: no weights loaded in reference model"
        y_src = golden_matmul(list(act_vec), w_src)
        rq = golden_requant(y_src)
        dest = tile_of(dest_x, dest_y)
        w_dest = self.tiles[dest].weight_rows
        assert w_dest is not None, f"tile {dest}: no weights loaded in reference model"
        return golden_matmul(rq, w_dest), dest
