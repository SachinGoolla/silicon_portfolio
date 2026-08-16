"""mac_cluster sequences -- base library (checkpoint 3) plus the composed
random-traffic sequence used for wall-clock budget measurement and later
the coverage-closure run.

Checkpoint 3 scope, deliberately: fixed producer/consumer ROLES (tiles 0/1
producing, tile 3 consuming -- the same roles test_mac_cluster.py's own
proven test_two_producer_chain uses), randomized DATA on top. mesh_egress_en
is a sticky, level-sensitive CSR bit (confirmed by reading mac_cluster.sv's
direct csr_regfile wiring, not assumed) -- a tile that sometimes produces
and sometimes terminally consumes needs its NI_CTRL explicitly re-armed
between roles or a stale mesh_egress_en=1 will misroute a later result.
That cross-role handling is real design work, done properly in checkpoint 6
(ConcurrentTrafficSeq) rather than bolted on here under time pressure.
"""
import random
from pyuvm import uvm_sequence

from mac_cluster_seq_item import MacClusterSeqItem, WEIGHT_CLASSES
from mac_cluster_driver import (
    csr_addr, NI_STATUS, NI_CTRL, NI_STATUS_EXIT_VALID, NI_CTRL_EXIT_ACK,
)
from mac_cluster_ref import tile_of

PRODUCER_TILES = (0, 1)
CONSUMER_TILE = 3


class WeightLoadSeq(uvm_sequence):
    """After finish_item() returns, self.weight_rows holds whatever matrix
    was actually sent (randomized or caller-forced) -- the item is the same
    object the driver executed against, so this is a direct read, not a
    guess at what randomize_weight_load() picked."""

    def __init__(self, name="weight_load_seq", tile=0, weight_class=None):
        super().__init__(name)
        self.tile = tile
        self.weight_class = weight_class
        self.weight_rows = None

    async def body(self):
        item = MacClusterSeqItem(f"wload_t{self.tile}").randomize_weight_load(
            tile=self.tile, weight_class=self.weight_class)
        await self.start_item(item)
        await self.finish_item(item)
        self.weight_rows = item.weight_rows


class ActivationStreamSeq(uvm_sequence):
    def __init__(self, name="activation_stream_seq", src=0, dest=(1, 1), mesh_egress_en=1):
        super().__init__(name)
        self.src, self.dest, self.mesh_egress_en = src, dest, mesh_egress_en

    async def body(self):
        item = MacClusterSeqItem(f"push_t{self.src}").randomize_entry_push(
            src=self.src, dest=self.dest, mesh_egress_en=self.mesh_egress_en)
        await self.start_item(item)
        await self.finish_item(item)


class CsrPollSeq(uvm_sequence):
    """Polls one tile's exit registers until a fresh result is seen (or the
    timeout raises). `cadence` is currently informational -- back-to-back
    vs. spaced polling cadence variation is a checkpoint-6 graft (it's what
    mac_cluster/REPORT.md names as Bug 4's actual trigger dimension)."""

    def __init__(self, name="csr_poll_seq", tile=CONSUMER_TILE, last_seq=0,
                 timeout=200, cadence="back_to_back"):
        super().__init__(name)
        self.tile, self.last_seq, self.timeout, self.cadence = tile, last_seq, timeout, cadence
        # Readable after finish_item() returns -- lets a caller chain
        # last_seq into its own next poll, same reasoning as
        # WeightLoadSeq's own weight_rows write-back. result_seq stays None
        # (and starved becomes True) if the driver's own bounded timeout
        # elapsed without a fresh result -- the driver sets item.starved
        # instead of raising (its run_phase is one shared coroutine for the
        # whole test), so a caller MUST check .starved before trusting
        # .result_seq is meaningful.
        self.result_seq = None
        self.starved = False

    async def body(self):
        item = MacClusterSeqItem(f"poll_t{self.tile}").randomize_poll_exit(
            tile=self.tile, last_seq=self.last_seq)
        item.timeout = self.timeout
        await self.start_item(item)
        await self.finish_item(item)
        self.result_seq = item.result_seq
        self.starved = item.starved


class ReloadWhileBusySeq(uvm_sequence):
    """Issues WEIGHT_LOAD immediately after a push on the SAME tile (no
    intervening delay -- the caller is expected to have just fired that
    push without waiting for it to fully drain), racing the reload against
    the tile's own busy window. self.observed_busy, set after body()
    completes, records STATUS.BUSY as sampled by the driver's own
    _do_weight_load -- as the LAST action before the actual LOAD_WEIGHTS
    write commits, not an earlier, separate probe. An earlier version of
    this class did its own separate probe BEFORE issuing the weight-row
    writes; that early snapshot could disagree with the real
    weight_we_gated decision made several AXI beats later at the actual
    CTRL-write commit (confirmed the hard way: it silently desynced
    MacClusterClosureSeq's reference model from real RTL state). This does
    not re-derive axi4stream_ctrl.sv's already formally-proven
    weight_we_gated = weight_we_i && !busy_comb gate; it tracks whether the
    scenario was exercised, per the Phase 4 plan's own scope note for this
    bin -- still best-effort, not a hard guarantee (see
    mac_cluster_driver.py's _do_weight_load for the residual gap)."""

    def __init__(self, name="reload_while_busy_seq", tile=0):
        super().__init__(name)
        self.tile = tile
        self.observed_busy = None
        # Populated after finish_item() regardless of observed_busy -- the
        # RTL only actually APPLIES this if !busy_comb (weight_we_gated),
        # so a caller that needs to keep a reference model in sync should
        # NOT rely on this being accurate when observed_busy is True (see
        # MacClusterClosureSeq._reload's own docstring for why it uses a
        # separate, unambiguous follow-up reload instead of trusting this).
        self.weight_rows = None

    async def body(self):
        item = MacClusterSeqItem(f"reload_busy_t{self.tile}").randomize_weight_load(tile=self.tile)
        await self.start_item(item)
        await self.finish_item(item)
        self.observed_busy = item.observed_busy_at_commit
        self.weight_rows = item.weight_rows


class ConcurrentEgressReconfigSeq(uvm_sequence):
    """Forces entry_pending_q and mesh_in_valid_i to genuinely have a
    chance to collide at the SAME tile -- a scenario the existing fixed
    2-producer/1-consumer topology structurally cannot create (producer
    and consumer tiles are always disjoint there). `mesh_src` pushes
    toward `tile` (mesh_egress_en=1, dest=tile's own coordinates) WITHOUT
    waiting extra cycles, then `tile`'s own CPU entry push is fired
    immediately after -- racing the two so mesh_src's forwarded result may
    still be traversing the mesh when tile's own entry_pending_q sets, the
    same back-to-back-no-delay trick ReloadWhileBusySeq uses to land its
    own race window. Whether contention actually lands is empirical, not
    guaranteed by this sequence's own timing (see mac_cluster_monitor.py's
    HierSample.ingress_mux_contention and cp_ingress_mux_contention in
    mac_cluster_coverage.py for what actually observes it) -- discovery-
    based, per the Phase 4 plan's own honest scoping for this bin.

    Opportunistic drain-and-ack of `tile`'s own exit register runs FIRST,
    before this iteration's own two pushes -- found necessary the hard way:
    `tile`'s single-slot exit buffer (tile_ni.sv's exit_valid_q) holds at
    most one un-drained result. Without ANY draining, the first iteration
    that ever runs already overflows it: push_own's own result lands while
    push_mesh's forwarded one is still sitting unacked, freezing
    axi4stream_ctrl.sv's array (array_pipeline_en gates off), which
    permanently drops tile_s_axis_tready_i -- and since tile_ni's
    src_is_mesh_q only re-decides on a completed handshake, a live
    mesh_in_valid_i then locks the ingress mux onto mesh priority forever.
    Confirmed via a real per-cycle hierarchical trace (a throwaway debug
    watcher on dut.g_tile[3].u_ni, not guessed): the observed starvation
    was this undrained-buffer backpressure chain, NOT raw mesh-priority
    arbitration outrunning the CPU -- the ingress mux itself decided
    correctly every time it was actually able to re-decide.

    UPDATE (Phase 5 checkpoint A): that "decided correctly every time"
    claim was true when written but has since been tightened, not
    invalidated. tile_ni.sv's ingress mux used to give the mesh
    UNCONDITIONAL priority (no bound at all); test_race_adjacent.py's own
    observed starved count dropped 6->5 after entry_starve_cnt_q/
    FAIRNESS_LIMIT landed -- meaning one of the previously-observed starved
    pushes here WAS raw mesh-priority contention outrunning the CPU, now
    fixed. The remaining ~5 are still this buffer-freeze chain, which
    Checkpoint A does not touch (see test_ingress_fairness.py for the
    isolated regression that confirms the fairness bound in isolation from
    this freeze mechanism, where starved is 0/20).

    The once-per-iteration drain here is a partial mitigation, not a full
    fix, and is deliberately left that way: it runs BEFORE this iteration's
    own push_mesh/push_own, so it clears whatever a PRIOR iteration left
    behind, but it cannot stop THIS iteration's own two pushes from
    refilling the single slot moments later (mesh-forwarded arrives, gets
    captured, then push_own's own result has nowhere to go) -- confirmed
    empirically: most iterations under RECONFIG_ATTEMPTS still end up
    starved even with the drain in place (see test_race_adjacent.py's own
    report_phase for the observed count). A blocking, fully-draining
    CsrPollSeq before every push would eliminate that, but would also
    serialize away the actual race window this sequence exists to create
    -- so a nonzero starved count here is an EXPECTED, not surprising,
    outcome of racing two injection paths without full drain discipline,
    not evidence of ingress-mux unfairness on its own. What this drain DOES
    guarantee: the backlog never exceeds what one iteration's own two
    pushes can produce, so the stale-read detector and scoreboard stay
    meaningful (no cross-iteration accumulation to obscure a real bug).

    Bounded: `tile`'s own entry push is still polled with a finite timeout
    by the driver -- if it's never accepted, the driver sets
    push_own.starved=True instead of raising (the driver's run_phase is one
    shared coroutine for the whole test; an exception there would kill
    every subsequent item, not just this one). This sequence mirrors that
    outcome onto self.starved for the caller."""

    def __init__(self, name="concurrent_egress_reconfig_seq", mesh_src=0, tile=3, timeout=100):
        super().__init__(name)
        self.mesh_src, self.tile, self.timeout = mesh_src, tile, timeout
        self.starved = False

    async def _drain_own_exit(self):
        status_item = MacClusterSeqItem(f"cerc_drain_probe_{self.tile}").randomize_raw_csr(
            write=False, addr=csr_addr(self.tile, NI_STATUS))
        await self.start_item(status_item)
        await self.finish_item(status_item)
        if status_item.result & NI_STATUS_EXIT_VALID:
            ack_item = MacClusterSeqItem(f"cerc_drain_ack_{self.tile}").randomize_raw_csr(
                write=True, addr=csr_addr(self.tile, NI_CTRL), data=NI_CTRL_EXIT_ACK)
            await self.start_item(ack_item)
            await self.finish_item(ack_item)

    async def body(self):
        await self._drain_own_exit()

        dest = (self.tile % 2, self.tile // 2)
        push_mesh = MacClusterSeqItem(f"cerc_mesh_{self.mesh_src}").randomize_entry_push(
            src=self.mesh_src, dest=dest, mesh_egress_en=1)
        await self.start_item(push_mesh)
        await self.finish_item(push_mesh)

        push_own = MacClusterSeqItem(f"cerc_own_{self.tile}").randomize_entry_push(
            src=self.tile, dest=(0, 0), mesh_egress_en=0)   # local loopback -- dest unused
        push_own.timeout = self.timeout
        await self.start_item(push_own)
        await self.finish_item(push_own)
        self.starved = push_own.starved


class IngressFairnessSeq(uvm_sequence):
    """Phase 5 checkpoint A's load-bearing empirical check. Isolates the
    ingress-mux fairness mechanism (tile_ni.sv's entry_starve_cnt_q /
    FAIRNESS_LIMIT) from the exit-buffer-freeze mechanism
    ConcurrentEgressReconfigSeq's own docstring identifies as the DOMINANT
    cause of test_race_adjacent.py's observed starvation. Unlike that
    sequence, this one fully drains `tile`'s exit register TWICE after every
    iteration -- once for whichever result lands first (mesh-forwarded or
    the CPU entry push, order not guaranteed), once for the other -- so
    axi4stream_ctrl.sv's array never freezes and entry_starve_cnt_q's own
    formal bound (tile_ni_liveness.sby's entry_starve_cnt_q <=
    FAIRNESS_LIMIT+1) is the only mechanism left that could produce a
    starved push.

    Both push_mesh (forwarded from mesh_src, mesh_egress_en=1) and push_own
    (a direct CPU entry push on `tile`, mesh_egress_en=0, which also resets
    `tile`'s own sticky mesh_egress_en_i to 0 -- so BOTH results land in
    `tile`'s own exit register, not one forwarded onward) are fired back-to-
    back with no intervening wait, same racing discipline
    ConcurrentEgressReconfigSeq already established as sufficient to create
    real ingress-mux contention (confirmed empirically there via
    ingress_mux_contention=100%).

    Expected result: starved_count stays 0 across `iterations` -- this is
    the checkpoint's actual verification, not test_race_adjacent.py's own,
    differently-scoped (freeze-dominated) starved metric, which this
    sequence deliberately does not re-litigate.
    """

    def __init__(self, name="ingress_fairness_seq", mesh_src=0, tile=CONSUMER_TILE, iterations=20):
        super().__init__(name)
        self.mesh_src, self.tile, self.iterations = mesh_src, tile, iterations
        self.starved_count = 0
        self.last_seq = 0
        self.drain_starved_count = 0

    async def _drain_one(self):
        poll = MacClusterSeqItem(f"ifs_drain_{self.tile}").randomize_poll_exit(
            tile=self.tile, last_seq=self.last_seq)
        poll.timeout = 200
        await self.start_item(poll)
        await self.finish_item(poll)
        if poll.starved:
            self.drain_starved_count += 1
        else:
            self.last_seq = poll.result_seq

    async def body(self):
        dest = (self.tile % 2, self.tile // 2)
        for i in range(self.iterations):
            push_mesh = MacClusterSeqItem(f"ifs_mesh_{i}").randomize_entry_push(
                src=self.mesh_src, dest=dest, mesh_egress_en=1)
            await self.start_item(push_mesh)
            await self.finish_item(push_mesh)

            push_own = MacClusterSeqItem(f"ifs_own_{i}").randomize_entry_push(
                src=self.tile, mesh_egress_en=0)
            await self.start_item(push_own)
            await self.finish_item(push_own)
            if push_own.starved:
                self.starved_count += 1

            # Both pushes' results land in this tile's single exit slot
            # (push_own's mesh_egress_en=0 write also resets tile's own
            # sticky mesh_egress_en_i, so the mesh-forwarded result no
            # longer forwards past this tile either) -- drain both before
            # the next iteration's pushes can refill the slot.
            await self._drain_one()
            await self._drain_one()


class MacClusterBasicRandomSeq(uvm_sequence):
    """Composed traffic for timing measurement (checkpoint 3) and, once the
    scoreboard/coverage exist, the base of the closure run. Each iteration:
    a random producer (0 or 1) pushes a random activation to the fixed
    consumer (3), then that push is immediately drained -- same
    push-then-poll structure test_two_producer_chain already proves
    correct, generalized to N randomized iterations instead of 2 fixed
    ones. Weights are loaded once up front (weight-stationary reuse across
    iterations, matching this IP's own established dataflow)."""

    def __init__(self, name="mac_cluster_basic_random_seq", iterations=20,
                 scoreboard=None, coverage=None):
        super().__init__(name)
        self.iterations = iterations
        self.scoreboard = scoreboard   # optional -- None for pure timing/smoke runs
        self.coverage = coverage
        self.last_seq = {CONSUMER_TILE: 0}
        self.pushed = []   # [(producer_tile, act_vec)], for the caller's own bookkeeping

    async def body(self):
        for tile in (*PRODUCER_TILES, CONSUMER_TILE):
            wc = random.choice(WEIGHT_CLASSES)
            wseq = WeightLoadSeq(f"wload_{tile}", tile=tile, weight_class=wc)
            await wseq.start(self.sequencer)
            if self.scoreboard is not None:
                self.scoreboard.load_weights(tile, wseq.weight_rows)
            if self.coverage is not None:
                self.coverage.load_weights(tile, wseq.weight_rows)

        for i in range(self.iterations):
            src = random.choice(PRODUCER_TILES)
            push_item = MacClusterSeqItem(f"push_{i}").randomize_entry_push(
                src=src, dest=(CONSUMER_TILE % 2, CONSUMER_TILE // 2), mesh_egress_en=1)
            await self.start_item(push_item)
            await self.finish_item(push_item)
            self.pushed.append((src, list(push_item.act_vec)))

            poll_item = MacClusterSeqItem(f"poll_{i}").randomize_poll_exit(
                tile=CONSUMER_TILE, last_seq=self.last_seq[CONSUMER_TILE])
            await self.start_item(poll_item)
            await self.finish_item(poll_item)
            # poll_item is the SAME object the driver wrote result_seq onto
            # (passed by reference) -- chain it into the next iteration's
            # last_seq instead of a locally-tracked value that could desync.
            self.last_seq[CONSUMER_TILE] = poll_item.result_seq


class MacClusterClosureSeq(uvm_sequence):
    """Checkpoint 7: the composed, weighted-random generator for the actual
    coverage-closure run. Generalizes MacClusterBasicRandomSeq's fixed
    producer(0/1)-to-consumer(3) topology to random src/dst across all 4
    tiles (needed for cp_src_dst_tile's full cross and cp_tile itself), and
    folds in RAW_CSR ops and ReloadWhileBusySeq so cp_op/cp_reload_while_busy
    close too -- everything MacClusterCoverage actually tracks (see that
    file), not just entry/exit traffic.

    Every push is immediately followed by a poll of whichever tile the
    result actually lands on (self on loopback, tile_of(dest_x,dest_y) on a
    mesh forward) -- push-then-poll, never push-then-push. This is a
    structural choice, not an optimization: checkpoint 6's own
    ConcurrentEgressReconfigSeq found the hard way that a tile's single-
    slot exit buffer (tile_ni.sv's exit_valid_q) permanently wedges the
    whole ingress mux once two un-drained results land on it (see that
    sequence's docstring for the full mechanism). Draining every push
    before the next one starts means that backlog can never reach two, so
    this sequence can run hundreds of iterations without needing
    checkpoint 6's own opportunistic-drain workaround.

    dest==src with mesh_egress_en=1 (the self-forwarding daisy-chain case)
    is still excluded here, same as everywhere else in this suite --
    MacClusterSeqItem.randomize_entry_push()'s own docstring documents why
    it's deliberately out of scope.

    A second, cross-iteration instance of the same daisy-chain hazard is
    also avoided here, found the hard way (a real closure-run hang, not
    guessed): mesh_egress_en_i is STICKY per tile -- it reflects whatever
    mesh_egress_en value THAT tile was most recently pushed as `src` with,
    forever, until it's pushed as `src` again. If tile B was used as a
    forward SOURCE in an earlier iteration (mesh_egress_en_i now stuck at
    1) and a LATER iteration picks tile B as another tile's forward
    DESTINATION, tile B's own newly-computed result (from being that
    destination) does not capture into exit_valid_q at all -- egress mux
    control (tile_ni.sv's `tile_m_axis_tready_o = mesh_egress_en_i ? ... :
    !exit_valid_q`) sends it back into the mesh instead, toward whatever
    stale dest_x_i/dest_y_i tile B's own OLD push happened to leave set.
    _do_poll_exit, waiting on tile B's own EXIT_VALID, then waits forever
    for a capture that structurally cannot happen -- this is not a timeout-
    budget problem (confirmed: raising the poll timeout 10x did not fix
    it), it's this sequence choosing an invalid destination. Fix: track
    each tile's own current mesh_egress_en_i state locally (self._me) and
    only pick a forward destination from tiles currently at 0; if none are
    available this iteration, fall back to a loopback push instead (always
    safe -- a loopback push sets its OWN mesh_egress_en_i to 0 as part of
    the same write)."""

    RAW_CSR_PROB   = 0.05
    RELOAD_PROB    = 0.08
    LOOPBACK_PROB  = 0.30

    def __init__(self, name="mac_cluster_closure_seq", iterations=200,
                 scoreboard=None, coverage=None):
        super().__init__(name)
        self.iterations = iterations
        self.scoreboard = scoreboard
        self.coverage = coverage
        self.last_seq = {t: 0 for t in range(4)}
        # Tracks the CURRENT mesh_egress_en_i value for each tile (reset
        # default 0) -- see this class's own docstring for why a tile
        # whose value is stuck at 1 is unsafe to pick as a forward dest.
        self._me = {t: 0 for t in range(4)}

    async def _load_weights(self, tile, weight_class=None):
        wseq = WeightLoadSeq(f"closure_wload_{tile}", tile=tile, weight_class=weight_class)
        await wseq.start(self.sequencer)
        if self.scoreboard is not None:
            self.scoreboard.load_weights(tile, wseq.weight_rows)
        if self.coverage is not None:
            self.coverage.load_weights(tile, wseq.weight_rows)

    async def _push_and_drain(self, i):
        src = random.randint(0, 3)
        safe_dests = [t for t in range(4) if t != src and self._me[t] == 0]
        mesh_egress_en = 1 if (safe_dests and random.random() >= self.LOOPBACK_PROB) else 0

        if mesh_egress_en:
            dest_tile = random.choice(safe_dests)
            push_item = MacClusterSeqItem(f"closure_push_{i}").randomize_entry_push(
                src=src, dest=(dest_tile % 2, dest_tile // 2), mesh_egress_en=1)
        else:
            dest_tile = src
            push_item = MacClusterSeqItem(f"closure_push_{i}").randomize_entry_push(
                src=src, mesh_egress_en=0)
        self._me[src] = mesh_egress_en

        await self.start_item(push_item)
        await self.finish_item(push_item)

        poll_item = MacClusterSeqItem(f"closure_poll_{i}").randomize_poll_exit(
            tile=dest_tile, last_seq=self.last_seq[dest_tile])
        poll_item.timeout = 300
        await self.start_item(poll_item)
        await self.finish_item(poll_item)
        self.last_seq[dest_tile] = poll_item.result_seq

    async def _reload(self, i):
        # A bare probe-then-reload with nothing in flight almost never
        # observes BUSY=1: entry_pending_q (what a push's own finish_item
        # waits on) clears within 1-2 cycles of acceptance, long before
        # busy_comb's own ~(K+N-1)*LATENCY-cycle occupancy window closes.
        # Push a loopback activation WITHOUT draining it first (mirroring
        # test_race_adjacent.py's own proven pre_reload_push pattern) so
        # the probe lands while the array is still genuinely computing,
        # then drain that push's own result afterward via this sequence's
        # normal last_seq-chained poll so it doesn't show up as leftover.
        tile = random.randint(0, 3)
        push_item = MacClusterSeqItem(f"closure_reload_push_{i}").randomize_entry_push(
            src=tile, mesh_egress_en=0)
        await self.start_item(push_item)
        await self.finish_item(push_item)
        self._me[tile] = 0

        reload_seq = ReloadWhileBusySeq(f"closure_reload_{i}", tile=tile)
        await reload_seq.start(self.sequencer)
        if self.coverage is not None:
            outcome = "attempted_dropped" if reload_seq.observed_busy else "attempted_applied"
            self.coverage.sample_reload_while_busy(outcome)

        # Drain the loopback push issued above -- this ALSO guarantees the
        # tile is now genuinely idle (busy_comb provably 0), since a poll
        # only succeeds once the array has actually produced and captured
        # a result.
        poll_item = MacClusterSeqItem(f"closure_reload_poll_{i}").randomize_poll_exit(
            tile=tile, last_seq=self.last_seq[tile])
        poll_item.timeout = 300
        await self.start_item(poll_item)
        await self.finish_item(poll_item)
        self.last_seq[tile] = poll_item.result_seq

        # reload_seq's own weight_rows may or may not actually have taken
        # effect in the RTL -- observed_busy_at_commit (sampled right
        # before the real CTRL-write commit) is the closest available
        # signal but still not a hard guarantee (a few cycles of AXI
        # handshake separate the sample from the commit), and there is no
        # CSR-visible way to read mac_pe's own weight_q directly (an
        # earlier version of this method tried reading back
        # TILE_WEIGHT_ROW0-3 instead, which is WRONG for a different
        # reason: that register is an unconditional SW-write mirror in
        # mac_tile_axi.sv's own regfile, never gated by weight_we_gated,
        # so it always reflects the just-written value regardless of
        # whether the array itself ever latched it -- confirmed by reading
        # mac_tile_axi.sv's own hw_we[] list, which never includes the
        # WEIGHT_ROW indices). Rather than infer reference-model
        # correctness from either signal, issue a second, UNAMBIGUOUS
        # weight load now that the tile is definitely idle (confirmed by
        # the poll above having just succeeded) and sync to THAT one's own
        # weight_rows instead -- zero inference, by construction correct.
        settle_seq = WeightLoadSeq(f"closure_reload_settle_{i}", tile=tile)
        await settle_seq.start(self.sequencer)
        if self.scoreboard is not None:
            self.scoreboard.load_weights(tile, settle_seq.weight_rows)
        if self.coverage is not None:
            self.coverage.load_weights(tile, settle_seq.weight_rows)

    async def _raw_csr(self, i):
        # A genuinely random address/data write here is unsafe: this repo's
        # own address space packs NI_CTRL's entry_push/mesh_egress_en/
        # exit_ack bits into the same word range randomize_raw_csr()'s
        # default addr can land on, and a random write there would flip
        # this sequence's own tracked mesh_egress_en_i state (self._me)
        # and the scoreboard's expected-multiset bookkeeping without
        # either knowing -- found via the same closure-run hang this
        # class's own docstring describes for the destination-picking bug.
        # NI_STATUS is HW-write-only (csr_hw_we asserted unconditionally
        # every cycle in mac_cluster.sv), so a SW write there is always
        # inert -- safe to hit RAW_CSR_WRITE coverage with zero side
        # effects. Reads are safe at any address (never mutate state).
        write = random.choice([True, False])
        tile = random.randint(0, 3)
        if write:
            item = MacClusterSeqItem(f"closure_raw_{i}").randomize_raw_csr(
                write=True, addr=csr_addr(tile, NI_STATUS))
        else:
            item = MacClusterSeqItem(f"closure_raw_{i}").randomize_raw_csr(write=False)
        await self.start_item(item)
        await self.finish_item(item)

    async def body(self):
        for tile in range(4):
            await self._load_weights(tile)

        for i in range(self.iterations):
            roll = random.random()
            if roll < self.RAW_CSR_PROB:
                await self._raw_csr(i)
            elif roll < self.RAW_CSR_PROB + self.RELOAD_PROB:
                await self._reload(i)
            else:
                await self._push_and_drain(i)
