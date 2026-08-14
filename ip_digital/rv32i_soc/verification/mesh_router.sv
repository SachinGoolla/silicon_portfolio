// mesh_router.sv -- a 5-port (North/East/South/West/Local) XY-routing mesh
// router. Input-buffered, output-arbitrated: every input port has its own
// 1-entry FWFT skid buffer (axis_skid.sv, proven, reused unmodified) and its
// own routing decision (xy_route.sv, proven, reused unmodified); every
// output port arbitrates among the (exactly 4, see below) inputs that could
// legally want it via a round-robin arbiter (rr_arbiter.sv, proven, reused
// unmodified). See Phase 3 plan §1 for the full derivation.
//
// CORRECTION to the Phase 3 plan's own stated design (found by this
// checkpoint's formal proof, not assumed away): the plan's original
// reasoning was that single-flit packets let every router tie
// burst_lock_i=0 permanently, discharging rr_arbiter_liveness.sby's own
// `assume(!burst_lock_i)` for free. That reasoning conflated "packets are
// only 1 flit long" with "grants never need to be held across cycles" --
// two different things. With burst_lock_i=0, rr_arbiter recomputes its
// grant FRESH every cycle from whatever's currently requesting (no
// burst_lock_i means no hold at all, not even for one already-decided-but-
// not-yet-transferred grant) -- so if a second input starts requesting the
// same output before the first grant's flit has actually transferred
// (out_ready_i still low), the rotating priority pointer swaps the winner
// mid-flight, changing out_flit_o's DATA while out_valid_o stays asserted
// -- a real AXI-stream VALID-STICKY violation, caught as a genuine BMC
// counterexample at step 3 during this checkpoint's own development, not
// a hypothetical. mask_i is still tied to '0 (no power-gating in this
// design), but burst_lock_i is tied to a per-output xfer_DIR signal
// (`out_valid_o[DIR] && out_ready_i[DIR]`) fed into last_i, and
// burst_lock_i itself tied to 1'b1 -- holding each output's grant exactly
// until its own flit actually transfers, then releasing for fresh
// round-robin arbitration. This is the SAME hold mechanism rr_arbiter's
// own header already names for AXI burst semantics, reused here for a
// different reason (backpressure-hold, not multi-beat-burst-hold) --
// meaning this router's liveness under real backpressure INHERITS
// rr_arbiter_liveness.sby's own already-documented, already-accepted gap
// (STARVATION_FREE is proven only under `assume(!burst_lock_i)`), not a
// new one, and NOT "imported with zero gap" as originally planned. Honest
// correction, not silently patched over -- see this IP's own REPORT.md.
//
// N_REQ=4 is exact, not a convenient default: under XY routing, no-U-turn
// means a flit arriving on input port q can never legally want output q
// again, so every one of the 5 outputs has exactly 4 possible requesters
// (all inputs except the one aligned with that output) -- this lands
// exactly on rr_arbiter's proven sweep set (N_REQ in {4,8,16}).
//
// Registered-grant skew (Phase 3 plan §1): rr_arbiter's grant_o is
// registered -- a decision against cycle-N requests appears at cycle N+1.
// "Granted" is not the same as "transferred" until out_ready_i actually
// fires; out_valid_o/m_ready are both built from the explicit
// `grant && buf_valid[winner] && out_ready_i[q]` formula, not from grant
// alone. Bounded-latency delivery under contention remains a cover, not a
// safety, property (see the .sby) -- burst_lock_i fixes VALID-STICKY
// correctness, it does not turn an unbounded-backpressure scenario into a
// provable bound.
`timescale 1ns/1ps

module mesh_router #(
    parameter int MESH_DIM  = 2,
    parameter int PAYLOAD_W = 128,
    parameter int CW        = 1,    // coordinate width; caller passes $clog2(MESH_DIM)
    parameter int FLIT_W    = 134,  // caller passes 2 + 4*CW + PAYLOAD_W
    parameter int MY_X      = 0,    // static per-instance position
    parameter int MY_Y      = 0
) (
    input  logic clk,
    input  logic rst_n,

    // 5 ports, {N,E,S,W,L} = indices {0,1,2,3,4} -- flat, part-selected
    // [dir*FLIT_W +: FLIT_W], not unpacked/multi-dim-packed array ports
    // (Yosys -sv rejects both, confirmed in Phase 2's systolic_array_4x4.sv).
    input  logic [5*FLIT_W-1:0] in_flit_i,
    input  logic [4:0]          in_valid_i,
    output logic [4:0]          in_ready_o,

    output logic [5*FLIT_W-1:0] out_flit_o,
    output logic [4:0]          out_valid_o,
    input  logic [4:0]          out_ready_i
);

    // Flit layout (Phase 3 plan §2):
    //   [133]      tlast
    //   [132]      ptype (reserved)
    //   [131:130]  src_y, src_x   (CW bits each)
    //   [129:128]  dest_y, dest_x (CW bits each)
    //   [127:0]    payload
    localparam int F_DEST_X_LSB = PAYLOAD_W;
    localparam int F_DEST_Y_LSB = F_DEST_X_LSB + CW;

    localparam int DIR_N = 0;
    localparam int DIR_E = 1;
    localparam int DIR_S = 2;
    localparam int DIR_W = 3;
    localparam int DIR_L = 4;

    // -----------------------------------------------------------------
    // Per-input buffering + route decode (identical structure per port,
    // safe to loop -- the same generate-for-instance-replication pattern
    // systolic_array_4x4.sv already uses; the request/grant cross-wiring
    // below is NOT looped -- see the file header for why).
    // -----------------------------------------------------------------
    logic [4:0]          buf_valid;
    logic [5*FLIT_W-1:0] buf_flit;
    logic [5*5-1:0]      wants_flat;  // [p*5 +: 5], one-hot per port
    logic [4:0]          m_ready;     // computed by the per-output section below

    genvar gp;
    generate
        for (gp = 0; gp < 5; gp = gp + 1) begin : g_input
            axis_skid #(.WIDTH(FLIT_W)) u_skid (
                .clk       (clk),
                .rst_n     (rst_n),
                .s_valid_i (in_valid_i[gp]),
                .s_ready_o (in_ready_o[gp]),
                .s_data_i  (in_flit_i[gp*FLIT_W +: FLIT_W]),
                .m_valid_o (buf_valid[gp]),
                .m_ready_i (m_ready[gp]),
                .m_data_o  (buf_flit[gp*FLIT_W +: FLIT_W])
            );

            xy_route #(.MESH_DIM(MESH_DIM)) u_route (
                .dest_x_i (buf_flit[gp*FLIT_W + F_DEST_X_LSB +: CW]),
                .dest_y_i (buf_flit[gp*FLIT_W + F_DEST_Y_LSB +: CW]),
                .my_x_i   (MY_X[CW-1:0]),
                .my_y_i   (MY_Y[CW-1:0]),
                .wants_o  (wants_flat[gp*5 +: 5])
            );
        end
    endgenerate

    // -----------------------------------------------------------------
    // Per-output arbitration. Requesters for output DIR are the 4 ports
    // other than DIR itself, in ascending port-index order -- the same
    // fixed rule used for BOTH request assembly here and grant readback
    // in the m_ready section below, so the two can never drift out of
    // sync with each other (both are literally the same "skip DIR, count
    // up" rule, not two independently hand-maintained tables).
    //
    //   Output N(0): slot0=E slot1=S slot2=W slot3=L
    //   Output E(1): slot0=N slot1=S slot2=W slot3=L
    //   Output S(2): slot0=N slot1=E slot2=W slot3=L
    //   Output W(3): slot0=N slot1=E slot2=S slot3=L
    //   Output L(4): slot0=N slot1=E slot2=S slot3=W
    // -----------------------------------------------------------------
    logic [3:0] req_N, req_E, req_S, req_W, req_L;
    logic [3:0] grant_N, grant_E, grant_S, grant_W, grant_L;

    // Each term is additionally masked by !m_ready[port] -- a real,
    // subtle race the formal proof caught (not assumed away): a port
    // being drained THIS cycle (m_ready[p]=1, its current flit legally
    // consumed by whichever grant already resolved) must NOT also feed a
    // request into a DIFFERENT arbiter's decision for NEXT cycle based on
    // that same (about-to-be-replaced) content. Without this mask, a
    // fresh grant decision sampled this cycle can become visible one
    // cycle later still "pointing at" that port, but by then the port's
    // buffer has already been refilled by an unrelated flit that likely
    // wants a different direction entirely -- the arbiter's registered
    // grant would then be silently attached to the wrong data, exactly
    // the VALID-STICKY violation this checkpoint's own formal proof
    // caught as a real BMC counterexample. See this IP's own REPORT.md
    // for the full incident.
    assign req_N = {buf_valid[DIR_L] && wants_flat[DIR_L*5+DIR_N] && !m_ready[DIR_L],
                     buf_valid[DIR_W] && wants_flat[DIR_W*5+DIR_N] && !m_ready[DIR_W],
                     buf_valid[DIR_S] && wants_flat[DIR_S*5+DIR_N] && !m_ready[DIR_S],
                     buf_valid[DIR_E] && wants_flat[DIR_E*5+DIR_N] && !m_ready[DIR_E]};
    assign req_E = {buf_valid[DIR_L] && wants_flat[DIR_L*5+DIR_E] && !m_ready[DIR_L],
                     buf_valid[DIR_W] && wants_flat[DIR_W*5+DIR_E] && !m_ready[DIR_W],
                     buf_valid[DIR_S] && wants_flat[DIR_S*5+DIR_E] && !m_ready[DIR_S],
                     buf_valid[DIR_N] && wants_flat[DIR_N*5+DIR_E] && !m_ready[DIR_N]};
    assign req_S = {buf_valid[DIR_L] && wants_flat[DIR_L*5+DIR_S] && !m_ready[DIR_L],
                     buf_valid[DIR_W] && wants_flat[DIR_W*5+DIR_S] && !m_ready[DIR_W],
                     buf_valid[DIR_E] && wants_flat[DIR_E*5+DIR_S] && !m_ready[DIR_E],
                     buf_valid[DIR_N] && wants_flat[DIR_N*5+DIR_S] && !m_ready[DIR_N]};
    assign req_W = {buf_valid[DIR_L] && wants_flat[DIR_L*5+DIR_W] && !m_ready[DIR_L],
                     buf_valid[DIR_S] && wants_flat[DIR_S*5+DIR_W] && !m_ready[DIR_S],
                     buf_valid[DIR_E] && wants_flat[DIR_E*5+DIR_W] && !m_ready[DIR_E],
                     buf_valid[DIR_N] && wants_flat[DIR_N*5+DIR_W] && !m_ready[DIR_N]};
    assign req_L = {buf_valid[DIR_W] && wants_flat[DIR_W*5+DIR_L] && !m_ready[DIR_W],
                     buf_valid[DIR_S] && wants_flat[DIR_S*5+DIR_L] && !m_ready[DIR_S],
                     buf_valid[DIR_E] && wants_flat[DIR_E*5+DIR_L] && !m_ready[DIR_E],
                     buf_valid[DIR_N] && wants_flat[DIR_N*5+DIR_L] && !m_ready[DIR_N]};

    // mask_i tied to '0 (no power-gating in this design). burst_lock_i is
    // tied to 1'b1 on every instance, with last_i wired to that output's
    // own actual-transfer condition (xfer_DIR, declared below with the
    // output mux) -- holds each grant exactly until its flit transfers,
    // then releases for fresh arbitration. See the file header for why
    // this replaced the original burst_lock_i=0 plan (a real VALID-STICKY
    // bug the formal proof caught, not a style choice) and for the
    // resulting liveness scope correction. last_i depends combinationally
    // on grant_DIR, this SAME instance's own output -- not a
    // combinational loop: grant_o is a registered (flip-flop) output, so
    // this is ordinary synchronous feedback (a signal derived from a
    // register feeding that register's own next-state logic), not a
    // zero-delay cycle.
    // gnt_valid_o left unconnected -- this router derives its own
    // out_valid_o from grant && buf_valid[winner] directly (§1's explicit
    // formula), so rr_arbiter's own gnt_valid_o (a plain |grant_o
    // convenience output) is redundant here, not needed.
    /* verilator lint_off PINCONNECTEMPTY */
    rr_arbiter #(.N_REQ(4)) u_arb_N (.clk(clk), .rst_n(rst_n), .req_i(req_N), .mask_i(4'b0), .burst_lock_i(1'b1), .last_i(xfer_N), .grant_o(grant_N), .gnt_valid_o());
    rr_arbiter #(.N_REQ(4)) u_arb_E (.clk(clk), .rst_n(rst_n), .req_i(req_E), .mask_i(4'b0), .burst_lock_i(1'b1), .last_i(xfer_E), .grant_o(grant_E), .gnt_valid_o());
    rr_arbiter #(.N_REQ(4)) u_arb_S (.clk(clk), .rst_n(rst_n), .req_i(req_S), .mask_i(4'b0), .burst_lock_i(1'b1), .last_i(xfer_S), .grant_o(grant_S), .gnt_valid_o());
    rr_arbiter #(.N_REQ(4)) u_arb_W (.clk(clk), .rst_n(rst_n), .req_i(req_W), .mask_i(4'b0), .burst_lock_i(1'b1), .last_i(xfer_W), .grant_o(grant_W), .gnt_valid_o());
    rr_arbiter #(.N_REQ(4)) u_arb_L (.clk(clk), .rst_n(rst_n), .req_i(req_L), .mask_i(4'b0), .burst_lock_i(1'b1), .last_i(xfer_L), .grant_o(grant_L), .gnt_valid_o());
    /* verilator lint_on PINCONNECTEMPTY */

    logic xfer_N, xfer_E, xfer_S, xfer_W, xfer_L;

    // Output mux + explicit transfer condition (grant && buf_valid[winner]
    // && out_ready_i[q] -- Phase 3 plan §1's own stated formula, not
    // "grant alone", given the registered-grant skew).
    always_comb begin
        out_flit_o[DIR_N*FLIT_W +: FLIT_W] = grant_N[3] ? buf_flit[DIR_L*FLIT_W +: FLIT_W] :
                                              grant_N[2] ? buf_flit[DIR_W*FLIT_W +: FLIT_W] :
                                              grant_N[1] ? buf_flit[DIR_S*FLIT_W +: FLIT_W] :
                                                            buf_flit[DIR_E*FLIT_W +: FLIT_W];
        out_valid_o[DIR_N] = (grant_N[3] && buf_valid[DIR_L]) || (grant_N[2] && buf_valid[DIR_W]) ||
                              (grant_N[1] && buf_valid[DIR_S]) || (grant_N[0] && buf_valid[DIR_E]);

        out_flit_o[DIR_E*FLIT_W +: FLIT_W] = grant_E[3] ? buf_flit[DIR_L*FLIT_W +: FLIT_W] :
                                              grant_E[2] ? buf_flit[DIR_W*FLIT_W +: FLIT_W] :
                                              grant_E[1] ? buf_flit[DIR_S*FLIT_W +: FLIT_W] :
                                                            buf_flit[DIR_N*FLIT_W +: FLIT_W];
        out_valid_o[DIR_E] = (grant_E[3] && buf_valid[DIR_L]) || (grant_E[2] && buf_valid[DIR_W]) ||
                              (grant_E[1] && buf_valid[DIR_S]) || (grant_E[0] && buf_valid[DIR_N]);

        out_flit_o[DIR_S*FLIT_W +: FLIT_W] = grant_S[3] ? buf_flit[DIR_L*FLIT_W +: FLIT_W] :
                                              grant_S[2] ? buf_flit[DIR_W*FLIT_W +: FLIT_W] :
                                              grant_S[1] ? buf_flit[DIR_E*FLIT_W +: FLIT_W] :
                                                            buf_flit[DIR_N*FLIT_W +: FLIT_W];
        out_valid_o[DIR_S] = (grant_S[3] && buf_valid[DIR_L]) || (grant_S[2] && buf_valid[DIR_W]) ||
                              (grant_S[1] && buf_valid[DIR_E]) || (grant_S[0] && buf_valid[DIR_N]);

        out_flit_o[DIR_W*FLIT_W +: FLIT_W] = grant_W[3] ? buf_flit[DIR_L*FLIT_W +: FLIT_W] :
                                              grant_W[2] ? buf_flit[DIR_S*FLIT_W +: FLIT_W] :
                                              grant_W[1] ? buf_flit[DIR_E*FLIT_W +: FLIT_W] :
                                                            buf_flit[DIR_N*FLIT_W +: FLIT_W];
        out_valid_o[DIR_W] = (grant_W[3] && buf_valid[DIR_L]) || (grant_W[2] && buf_valid[DIR_S]) ||
                              (grant_W[1] && buf_valid[DIR_E]) || (grant_W[0] && buf_valid[DIR_N]);

        out_flit_o[DIR_L*FLIT_W +: FLIT_W] = grant_L[3] ? buf_flit[DIR_W*FLIT_W +: FLIT_W] :
                                              grant_L[2] ? buf_flit[DIR_S*FLIT_W +: FLIT_W] :
                                              grant_L[1] ? buf_flit[DIR_E*FLIT_W +: FLIT_W] :
                                                            buf_flit[DIR_N*FLIT_W +: FLIT_W];
        out_valid_o[DIR_L] = (grant_L[3] && buf_valid[DIR_W]) || (grant_L[2] && buf_valid[DIR_S]) ||
                              (grant_L[1] && buf_valid[DIR_E]) || (grant_L[0] && buf_valid[DIR_N]);
    end

    // Actual-transfer condition per output -- feeds back into that same
    // output's own arbiter as last_i (see the instantiations above).
    assign xfer_N = out_valid_o[DIR_N] && out_ready_i[DIR_N];
    assign xfer_E = out_valid_o[DIR_E] && out_ready_i[DIR_E];
    assign xfer_S = out_valid_o[DIR_S] && out_ready_i[DIR_S];
    assign xfer_W = out_valid_o[DIR_W] && out_ready_i[DIR_W];
    assign xfer_L = out_valid_o[DIR_L] && out_ready_i[DIR_L];

    // -----------------------------------------------------------------
    // Per-input m_ready: "was this port's buffered flit granted by
    // whichever output it wants, AND is that output actually ready this
    // cycle" -- read back using the EXACT SAME slot assignments as the
    // request assembly above (see the table in that section's comment).
    // wants_flat[p] is one-hot (proven at checkpoint 1, re-asserted below
    // for the buffered value), so at most one of the 5 terms per port is
    // ever live -- an OR across all 5 is safe, not a real race.
    // -----------------------------------------------------------------
    assign m_ready[DIR_N] = (wants_flat[DIR_N*5+DIR_E] && grant_E[0] && out_ready_i[DIR_E]) ||
                             (wants_flat[DIR_N*5+DIR_S] && grant_S[0] && out_ready_i[DIR_S]) ||
                             (wants_flat[DIR_N*5+DIR_W] && grant_W[0] && out_ready_i[DIR_W]) ||
                             (wants_flat[DIR_N*5+DIR_L] && grant_L[0] && out_ready_i[DIR_L]);

    assign m_ready[DIR_E] = (wants_flat[DIR_E*5+DIR_N] && grant_N[0] && out_ready_i[DIR_N]) ||
                             (wants_flat[DIR_E*5+DIR_S] && grant_S[1] && out_ready_i[DIR_S]) ||
                             (wants_flat[DIR_E*5+DIR_W] && grant_W[1] && out_ready_i[DIR_W]) ||
                             (wants_flat[DIR_E*5+DIR_L] && grant_L[1] && out_ready_i[DIR_L]);

    assign m_ready[DIR_S] = (wants_flat[DIR_S*5+DIR_N] && grant_N[1] && out_ready_i[DIR_N]) ||
                             (wants_flat[DIR_S*5+DIR_E] && grant_E[1] && out_ready_i[DIR_E]) ||
                             (wants_flat[DIR_S*5+DIR_W] && grant_W[2] && out_ready_i[DIR_W]) ||
                             (wants_flat[DIR_S*5+DIR_L] && grant_L[2] && out_ready_i[DIR_L]);

    assign m_ready[DIR_W] = (wants_flat[DIR_W*5+DIR_N] && grant_N[2] && out_ready_i[DIR_N]) ||
                             (wants_flat[DIR_W*5+DIR_E] && grant_E[2] && out_ready_i[DIR_E]) ||
                             (wants_flat[DIR_W*5+DIR_S] && grant_S[2] && out_ready_i[DIR_S]) ||
                             (wants_flat[DIR_W*5+DIR_L] && grant_L[3] && out_ready_i[DIR_L]);

    assign m_ready[DIR_L] = (wants_flat[DIR_L*5+DIR_N] && grant_N[3] && out_ready_i[DIR_N]) ||
                             (wants_flat[DIR_L*5+DIR_E] && grant_E[3] && out_ready_i[DIR_E]) ||
                             (wants_flat[DIR_L*5+DIR_S] && grant_S[3] && out_ready_i[DIR_S]) ||
                             (wants_flat[DIR_L*5+DIR_W] && grant_W[3] && out_ready_i[DIR_W]);

`ifdef FORMAL
    initial assume(!rst_n);

    // Legitimate-upstream assumption, one per mesh-facing port (N/E/S/W --
    // NOT Local, any destination is a legitimate local injection). A fully
    // free/arbitrary flit injected at, say, the North port could carry any
    // dest_x/dest_y at all in this isolated single-router model -- but no
    // REAL neighbor router, itself obeying XY routing, would ever actually
    // send this router a flit that doesn't match what its own xy_route
    // decision implies. Confirmed the hard way: the no-U-turn assert below
    // FAILED at BMC step 1 without this -- a malformed flit with dest_y >
    // my_y injected at the North port legitimately wants North again under
    // the fully general model. This assume is exactly the same "assume the
    // discipline of whatever's attached" pattern rv32i_addr_decoder.sv's
    // own formal block already established for its real slaves' VALID-
    // sticky behavior -- a real neighbor's own XY decision is what's being
    // assumed here, not an arbitrary constraint. mesh_2x2.sv's own
    // checkpoint re-verifies this holds for real (no assume needed there --
    // the actual neighbor wiring provides genuinely-XY-routed traffic).
    always_comb begin
        if (rst_n) begin
            if (buf_valid[DIR_N]) begin
                assume(buf_flit[DIR_N*FLIT_W + F_DEST_X_LSB +: CW] == MY_X[CW-1:0]);
                assume(buf_flit[DIR_N*FLIT_W + F_DEST_Y_LSB +: CW] <= MY_Y[CW-1:0]);
            end
            if (buf_valid[DIR_S]) begin
                assume(buf_flit[DIR_S*FLIT_W + F_DEST_X_LSB +: CW] == MY_X[CW-1:0]);
                assume(buf_flit[DIR_S*FLIT_W + F_DEST_Y_LSB +: CW] >= MY_Y[CW-1:0]);
            end
            if (buf_valid[DIR_E]) begin
                assume(buf_flit[DIR_E*FLIT_W + F_DEST_X_LSB +: CW] <= MY_X[CW-1:0]);
            end
            if (buf_valid[DIR_W]) begin
                assume(buf_flit[DIR_W*FLIT_W + F_DEST_X_LSB +: CW] >= MY_X[CW-1:0]);
            end
            // Local-injected traffic is assumed never self-addressed
            // (dest != this router's own position). This is a real, if
            // narrow, wiring gap this checkpoint found: req_L only ever
            // gathers requests from the 4 mesh-facing ports (matching
            // "requesters for output L = the 4 non-L ports"), so a
            // self-addressed Local-injected flit (wants=Local) has no
            // path back out the Local port at all -- it would sit in its
            // skid buffer forever. Scoped out rather than wired up: no
            // real traffic in this phase is ever self-addressed (tile-to-
            // tile dataflow is, by definition, between DIFFERENT tiles),
            // and tile_ni.sv (checkpoint 5) never constructs a
            // self-addressed destination by its own design. If a future
            // phase needs genuine self-addressed loopback, this is the
            // exact spot that needs real wiring, not just this assume.
            if (buf_valid[DIR_L]) begin
                assume(!(buf_flit[DIR_L*FLIT_W + F_DEST_X_LSB +: CW] == MY_X[CW-1:0] &&
                         buf_flit[DIR_L*FLIT_W + F_DEST_Y_LSB +: CW] == MY_Y[CW-1:0]));
            end
        end
    end

    // No-U-turn: a flit buffered at a MESH-FACING port (N/E/S/W) never
    // legally wants that same direction back. Local is deliberately
    // excluded here -- "arrived Local, wants Local" isn't a U-turn at all,
    // it's self-addressed traffic, which is a different (and separately
    // excluded, see the assume above) scope question, not a routing
    // direction reversal. xy_route.sv cannot assert this on its own (it
    // has no notion of which physical port it's instantiated for) --
    // checked here, where the arrival port IS known, as a structural
    // guarantee GIVEN legitimate upstream traffic (the assumes above), not
    // a completely unconstrained one.
    always_comb begin
        if (rst_n) begin
            if (buf_valid[DIR_N]) assert(!wants_flat[DIR_N*5+DIR_N]);
            if (buf_valid[DIR_E]) assert(!wants_flat[DIR_E*5+DIR_E]);
            if (buf_valid[DIR_S]) assert(!wants_flat[DIR_S*5+DIR_S]);
            if (buf_valid[DIR_W]) assert(!wants_flat[DIR_W*5+DIR_W]);
        end
    end

    // Mutual exclusion at every output: at most one grant bit set (this
    // is rr_arbiter's own ONEHOT0 property, re-checked at this level's
    // own boundary rather than trusted blindly).
    always_comb begin
        if (rst_n) begin
            assert($onehot0(grant_N));
            assert($onehot0(grant_E));
            assert($onehot0(grant_S));
            assert($onehot0(grant_W));
            assert($onehot0(grant_L));
        end
    end

    // Single-hop routing correctness: a flit buffered at port p, wanting
    // direction q, that actually transfers this cycle, must transfer
    // through output q specifically (not some other output) -- checked
    // against the SAME buf_flit content, confirming the mux picked the
    // right source.
    always_comb begin
        if (rst_n) begin
            if (m_ready[DIR_N] && wants_flat[DIR_N*5+DIR_E]) assert(out_flit_o[DIR_E*FLIT_W +: FLIT_W] == buf_flit[DIR_N*FLIT_W +: FLIT_W]);
            if (m_ready[DIR_N] && wants_flat[DIR_N*5+DIR_S]) assert(out_flit_o[DIR_S*FLIT_W +: FLIT_W] == buf_flit[DIR_N*FLIT_W +: FLIT_W]);
            if (m_ready[DIR_N] && wants_flat[DIR_N*5+DIR_W]) assert(out_flit_o[DIR_W*FLIT_W +: FLIT_W] == buf_flit[DIR_N*FLIT_W +: FLIT_W]);
            if (m_ready[DIR_N] && wants_flat[DIR_N*5+DIR_L]) assert(out_flit_o[DIR_L*FLIT_W +: FLIT_W] == buf_flit[DIR_N*FLIT_W +: FLIT_W]);
        end
    end

    // VALID-sticky at every output boundary (inherited discipline,
    // re-checked at this level).
    logic [4:0] f_ovalid_d, f_oready_d;
    logic [5*FLIT_W-1:0] f_oflit_d;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            f_ovalid_d <= 5'b0; f_oready_d <= 5'b0; f_oflit_d <= '0;
        end else begin
            f_ovalid_d <= out_valid_o; f_oready_d <= out_ready_i; f_oflit_d <= out_flit_o;
        end
    end
    always_comb begin
        for (int k = 0; k < 5; k++) begin
            if (rst_n && f_ovalid_d[k] && !f_oready_d[k]) begin
                assert(out_valid_o[k]);
                assert(out_flit_o[k*FLIT_W +: FLIT_W] == f_oflit_d[k*FLIT_W +: FLIT_W]);
            end
        end
    end

    // Bounded-latency cover, not a safety claim (Phase 3 plan §1/§5): a
    // flit injected at the Local port and delivered out any mesh
    // direction is reachable -- demonstrates actual delivery under this
    // checkpoint's own traffic, not a general analytical bound under
    // arbitrary backpressure.
    always_comb begin
        cover(rst_n && m_ready[DIR_L] && wants_flat[DIR_L*5+DIR_N]);
        cover(rst_n && m_ready[DIR_L] && wants_flat[DIR_L*5+DIR_E]);
        cover(rst_n && m_ready[DIR_L] && wants_flat[DIR_L*5+DIR_S]);
        cover(rst_n && m_ready[DIR_L] && wants_flat[DIR_L*5+DIR_W]);
    end

    // A second local injection succeeds after a first -- the
    // deadlock-liveness lesson (Phase 2 MMIO incident), applied here.
    // $past() as a bare system function is fine inside a plain clocked
    // always block on this toolchain (confirmed working elsewhere in this
    // repo); it is NOT fine inside always_comb or an SVA property block.
    logic f_seen_local_xfer_q;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) f_seen_local_xfer_q <= 1'b0;
        else if (m_ready[DIR_L]) f_seen_local_xfer_q <= 1'b1;
    end
    always @(posedge clk) begin
        cover(rst_n && m_ready[DIR_L] && f_seen_local_xfer_q);
    end
`endif

endmodule
