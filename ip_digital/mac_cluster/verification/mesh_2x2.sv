// mesh_2x2.sv -- a 2x2 XY-routed mesh: 4x mesh_router.sv (proven, reused
// unmodified) wired to their real neighbors, with boundary (non-existent
// neighbor) ports tied off. 4 Local ports are exposed externally, one per
// tile position (TILE_IDX = MY_Y*MESH_DIM + MY_X: 0=(0,0) 1=(1,0) 2=(0,1)
// 3=(1,1)).
//
// This is where mesh_router's own checkpoint-3 "legitimate-upstream"
// assumes stop being assumptions and become facts: every mesh-facing port
// here is now wired to a REAL neighbor router's REAL output, which only
// ever produces flits its own xy_route decision actually chose --
// checkpoint 3 assumed this discipline from whatever's attached (matching
// rv32i_addr_decoder.sv's own established pattern); this checkpoint is
// where that discipline is finally the truth, not an assumption.
`timescale 1ns/1ps

module mesh_2x2 #(
    parameter int MESH_DIM  = 2,
    parameter int PAYLOAD_W = 128,
    parameter int CW        = 1,
    parameter int FLIT_W    = 134
) (
    input  logic clk,
    input  logic rst_n,

    // 4 Local ports, one per tile position -- flat, part-selected
    // [idx*FLIT_W +: FLIT_W] / [idx], matching this repo's established
    // port-syntax convention (no unpacked/multi-dim-packed array ports).
    input  logic [4*FLIT_W-1:0] local_in_flit_i,
    input  logic [3:0]          local_in_valid_i,
    output logic [3:0]          local_in_ready_o,

    output logic [4*FLIT_W-1:0] local_out_flit_o,
    output logic [3:0]          local_out_valid_o,
    input  logic [3:0]          local_out_ready_i
);

    localparam int DIR_N = 0;
    localparam int DIR_E = 1;
    localparam int DIR_S = 2;
    localparam int DIR_W = 3;
    localparam int DIR_L = 4;

    // Internal, non-port arrays -- fine on every tool (only module PORTS
    // need the flat-vector treatment); indexed by TILE_IDX = MY_Y*2+MY_X.
    //
    // The lint tool flags r_in_flit/r_in_valid with UNOPTFLAT ("circular
    // combinational logic") -- worth the real analysis, not a blind
    // waiver, since the 4-router ring topology (0->1->3->2->0) genuinely
    // could create a multi-hop zero-delay path: axis_skid's own FWFT
    // pass-through makes buf_flit[p]==in_flit_i[p] combinationally
    // whenever that port's skid is empty, and out_flit_o[q] comes from
    // buf_flit[winner] via a REGISTERED grant -- so in principle,
    // in_flit_i[p] -> out_flit_o[q] within one router IS a real
    // zero-delay path when p happens to be both empty-and-passing-through
    // AND the currently-held winner for q. Chased this to ground: for
    // grant_q to be HELD pointing at p, p must have been ACTIVELY
    // requesting (buf_valid=1) when that decision was made and burst_lock_i
    // has kept it pinned since; mesh_router.sv's own req-masking fix
    // (`&& !m_ready[port]`, see that file's own header for the incident)
    // means a port can only be a fresh grant target if it was NOT ALSO
    // being drained that same cycle -- so "p is currently empty AND
    // grant_q is still pointing at p" is not a state this design's own
    // control logic can produce; the two conditions are mutually
    // exclusive by construction, not by luck. Verilator's own static
    // analysis can't see this (it reasons about signal-array dependency
    // shape, not this cross-module control invariant) and falls back to
    // its slower iterative solver for this region, which still converges
    // correctly since no genuine oscillation exists -- confirm this
    // empirically too via P4's own golden-matched simulation result
    // before trusting the static analysis alone (see this IP's own
    // REPORT.md for whether that confirmation held).
    /* verilator lint_off UNOPTFLAT */
    logic [5*FLIT_W-1:0] r_in_flit  [4];
    logic [4:0]          r_in_valid [4];
    /* verilator lint_on UNOPTFLAT */
    logic [4:0]          r_in_ready [4];
    logic [5*FLIT_W-1:0] r_out_flit [4];
    logic [4:0]          r_out_valid[4];
    logic [4:0]          r_out_ready[4];

    genvar ti;
    generate
        for (ti = 0; ti < 4; ti = ti + 1) begin : g_router
            mesh_router #(
                .MESH_DIM(MESH_DIM), .PAYLOAD_W(PAYLOAD_W), .CW(CW), .FLIT_W(FLIT_W),
                .MY_X(ti % MESH_DIM), .MY_Y(ti / MESH_DIM)
            ) u_router (
                .clk         (clk),
                .rst_n       (rst_n),
                .in_flit_i   (r_in_flit[ti]),
                .in_valid_i  (r_in_valid[ti]),
                .in_ready_o  (r_in_ready[ti]),
                .out_flit_o  (r_out_flit[ti]),
                .out_valid_o (r_out_valid[ti]),
                .out_ready_i (r_out_ready[ti])
            );
        end
    endgenerate

    // -----------------------------------------------------------------
    // Neighbor wiring. Tile positions: 0=(0,0) 1=(1,0) 2=(0,1) 3=(1,1).
    //   0<->1 : 0's East  <-> 1's West   (same row, adjacent in X)
    //   2<->3 : 2's East  <-> 3's West   (same row, adjacent in X)
    //   0<->2 : 0's North <-> 2's South  (same column, adjacent in Y)
    //   1<->3 : 1's North <-> 3's South  (same column, adjacent in Y)
    // Every other mesh-facing direction is a boundary: in_valid tied 0,
    // out_ready tied 1 (accept-and-discard -- inert, since mesh_router's
    // own checkpoint 3 already proves a boundary output's valid never
    // actually asserts).
    // -----------------------------------------------------------------
    always_comb begin
        // Tile 0 (0,0): North<-2 South(out), East<-1 West(out); South/West boundary.
        r_in_flit[0][DIR_N*FLIT_W +: FLIT_W] = r_out_flit[2][DIR_S*FLIT_W +: FLIT_W];
        r_in_valid[0][DIR_N] = r_out_valid[2][DIR_S];
        r_out_ready[2][DIR_S] = r_in_ready[0][DIR_N];

        r_in_flit[0][DIR_E*FLIT_W +: FLIT_W] = r_out_flit[1][DIR_W*FLIT_W +: FLIT_W];
        r_in_valid[0][DIR_E] = r_out_valid[1][DIR_W];
        r_out_ready[1][DIR_W] = r_in_ready[0][DIR_E];

        r_in_flit[0][DIR_S*FLIT_W +: FLIT_W] = '0;
        r_in_valid[0][DIR_S] = 1'b0;
        r_out_ready[0][DIR_S] = 1'b1;

        r_in_flit[0][DIR_W*FLIT_W +: FLIT_W] = '0;
        r_in_valid[0][DIR_W] = 1'b0;
        r_out_ready[0][DIR_W] = 1'b1;

        // Tile 1 (1,0): North<-3 South(out), West<-0 East(out); East/South boundary.
        r_in_flit[1][DIR_N*FLIT_W +: FLIT_W] = r_out_flit[3][DIR_S*FLIT_W +: FLIT_W];
        r_in_valid[1][DIR_N] = r_out_valid[3][DIR_S];
        r_out_ready[3][DIR_S] = r_in_ready[1][DIR_N];

        r_in_flit[1][DIR_W*FLIT_W +: FLIT_W] = r_out_flit[0][DIR_E*FLIT_W +: FLIT_W];
        r_in_valid[1][DIR_W] = r_out_valid[0][DIR_E];
        r_out_ready[0][DIR_E] = r_in_ready[1][DIR_W];

        r_in_flit[1][DIR_E*FLIT_W +: FLIT_W] = '0;
        r_in_valid[1][DIR_E] = 1'b0;
        r_out_ready[1][DIR_E] = 1'b1;

        r_in_flit[1][DIR_S*FLIT_W +: FLIT_W] = '0;
        r_in_valid[1][DIR_S] = 1'b0;
        r_out_ready[1][DIR_S] = 1'b1;

        // Tile 2 (0,1): South<-0 North(out), East<-3 West(out); North/West boundary.
        r_in_flit[2][DIR_S*FLIT_W +: FLIT_W] = r_out_flit[0][DIR_N*FLIT_W +: FLIT_W];
        r_in_valid[2][DIR_S] = r_out_valid[0][DIR_N];
        r_out_ready[0][DIR_N] = r_in_ready[2][DIR_S];

        r_in_flit[2][DIR_E*FLIT_W +: FLIT_W] = r_out_flit[3][DIR_W*FLIT_W +: FLIT_W];
        r_in_valid[2][DIR_E] = r_out_valid[3][DIR_W];
        r_out_ready[3][DIR_W] = r_in_ready[2][DIR_E];

        r_in_flit[2][DIR_N*FLIT_W +: FLIT_W] = '0;
        r_in_valid[2][DIR_N] = 1'b0;
        r_out_ready[2][DIR_N] = 1'b1;

        r_in_flit[2][DIR_W*FLIT_W +: FLIT_W] = '0;
        r_in_valid[2][DIR_W] = 1'b0;
        r_out_ready[2][DIR_W] = 1'b1;

        // Tile 3 (1,1): South<-1 North(out), West<-2 East(out); North/East boundary.
        r_in_flit[3][DIR_S*FLIT_W +: FLIT_W] = r_out_flit[1][DIR_N*FLIT_W +: FLIT_W];
        r_in_valid[3][DIR_S] = r_out_valid[1][DIR_N];
        r_out_ready[1][DIR_N] = r_in_ready[3][DIR_S];

        r_in_flit[3][DIR_W*FLIT_W +: FLIT_W] = r_out_flit[2][DIR_E*FLIT_W +: FLIT_W];
        r_in_valid[3][DIR_W] = r_out_valid[2][DIR_E];
        r_out_ready[2][DIR_E] = r_in_ready[3][DIR_W];

        r_in_flit[3][DIR_N*FLIT_W +: FLIT_W] = '0;
        r_in_valid[3][DIR_N] = 1'b0;
        r_out_ready[3][DIR_N] = 1'b1;

        r_in_flit[3][DIR_E*FLIT_W +: FLIT_W] = '0;
        r_in_valid[3][DIR_E] = 1'b0;
        r_out_ready[3][DIR_E] = 1'b1;

        // Local ports (index 4 within each router) <-> external local_* ports.
        for (int t = 0; t < 4; t++) begin
            r_in_flit[t][DIR_L*FLIT_W +: FLIT_W] = local_in_flit_i[t*FLIT_W +: FLIT_W];
            r_in_valid[t][DIR_L] = local_in_valid_i[t];
            local_in_ready_o[t] = r_in_ready[t][DIR_L];

            local_out_flit_o[t*FLIT_W +: FLIT_W] = r_out_flit[t][DIR_L*FLIT_W +: FLIT_W];
            local_out_valid_o[t] = r_out_valid[t][DIR_L];
            r_out_ready[t][DIR_L] = local_out_ready_i[t];
        end
    end

`ifdef FORMAL
    initial assume(!rst_n);

    // Same flit-layout offsets as mesh_router.sv, computed from THIS
    // file's own PAYLOAD_W/CW parameters -- NOT hardcoded bit positions.
    // mesh_router's own formal checkpoint narrows PAYLOAD_W (via chparam)
    // for tractability; hardcoding "128"/"129" here would silently break
    // (or worse, silently pass while checking the wrong bits) under that
    // same narrowing, since dest_x/dest_y's real position shifts with
    // PAYLOAD_W. Deriving them the same way mesh_router.sv does keeps this
    // file correct under any PAYLOAD_W this checkpoint or the main design
    // is ever run at.
    localparam int F_DEST_X_LSB = PAYLOAD_W;
    localparam int F_DEST_Y_LSB = F_DEST_X_LSB + CW;

    logic f_local_xfer [4];
    always_comb begin
        for (int t = 0; t < 4; t++) begin
            f_local_xfer[t] = local_out_valid_o[t] && local_out_ready_i[t];
        end
    end

    // End-to-end routing correctness: whatever flit arrives at a LOCAL
    // OUTPUT port must genuinely belong there -- its own dest_x/dest_y
    // header fields must match THAT tile's literal position. Literal
    // (0,0)/(1,0)/(0,1)/(1,1) constants per tile index, not re-derived
    // from this file's own ti%MESH_DIM/ti/MESH_DIM generate-loop
    // parameterization -- the anti-vacuity discipline rv32i_addr_decoder.sv
    // established, reapplied fresh here (a wiring bug that swapped, say,
    // tiles 1 and 2's neighbor connections would still self-consistently
    // "deliver something" without a literal check like this one). Payload/
    // src integrity is NOT re-proven here -- each router's own checkpoint-3
    // single-hop routing-correctness property already guarantees that
    // transitively, provided the wiring (what THIS property actually
    // checks) is correct.
    always_comb begin
        if (rst_n) begin
            if (local_out_valid_o[0]) begin
                assert(local_out_flit_o[0*FLIT_W+F_DEST_X_LSB] == 1'b0);
                assert(local_out_flit_o[0*FLIT_W+F_DEST_Y_LSB] == 1'b0);
            end
            if (local_out_valid_o[1]) begin
                assert(local_out_flit_o[1*FLIT_W+F_DEST_X_LSB] == 1'b1);
                assert(local_out_flit_o[1*FLIT_W+F_DEST_Y_LSB] == 1'b0);
            end
            if (local_out_valid_o[2]) begin
                assert(local_out_flit_o[2*FLIT_W+F_DEST_X_LSB] == 1'b0);
                assert(local_out_flit_o[2*FLIT_W+F_DEST_Y_LSB] == 1'b1);
            end
            if (local_out_valid_o[3]) begin
                assert(local_out_flit_o[3*FLIT_W+F_DEST_X_LSB] == 1'b1);
                assert(local_out_flit_o[3*FLIT_W+F_DEST_Y_LSB] == 1'b1);
            end
        end
    end

    // Reachability: every tile can receive, including the pairs needing a
    // genuine 2-hop XY turn (0->3 and 3->0) -- the same "second full cycle
    // is reachable" liveness discipline applied at the network level
    // (Phase 3 plan §5).
    always_comb begin
        cover(rst_n && local_in_valid_i[0] && local_in_ready_o[0] &&
              local_in_flit_i[0*FLIT_W+F_DEST_X_LSB] == 1'b1 &&
              local_in_flit_i[0*FLIT_W+F_DEST_Y_LSB] == 1'b1 &&
              f_local_xfer[3]); // 0 -> 3: full XY turn (X hop then Y hop)
        cover(rst_n && local_in_valid_i[3] && local_in_ready_o[3] &&
              local_in_flit_i[3*FLIT_W+F_DEST_X_LSB] == 1'b0 &&
              local_in_flit_i[3*FLIT_W+F_DEST_Y_LSB] == 1'b0 &&
              f_local_xfer[0]); // 3 -> 0: full XY turn, opposite direction
        cover(rst_n && f_local_xfer[0]);
        cover(rst_n && f_local_xfer[1]);
        cover(rst_n && f_local_xfer[2]);
        cover(rst_n && f_local_xfer[3]);
    end

    // A second delivery to the SAME destination succeeds after a first --
    // the deadlock-liveness lesson, applied at the mesh level too, not
    // just inside a single router (Phase 3 plan §5).
    logic f_seen_xfer3_q;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) f_seen_xfer3_q <= 1'b0;
        else if (f_local_xfer[3]) f_seen_xfer3_q <= 1'b1;
    end
    always @(posedge clk) begin
        cover(rst_n && f_local_xfer[3] && f_seen_xfer3_q);
    end
`endif

endmodule
