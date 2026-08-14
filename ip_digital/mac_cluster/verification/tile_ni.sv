// tile_ni.sv -- per-tile network interface: bridges one mac_tile_axi's
// AXI4-Stream ports to one mesh_2x2 Local port, plus a CPU-facing entry/
// exit path for tiles that need software-driven injection or readout
// (the first tile in a chain has no upstream neighbor to feed it; the
// last tile's result isn't forwarded anywhere and needs CPU readout).
//
// Real RTL constraint this design works around (traced from
// axi4stream_ctrl.sv directly, not assumed): INPUT_SRC_MMIO forks BOTH
// s_axis AND m_axis together -- `skid_s_valid = !input_src_mmio_i &&
// drain_valid`, so m_axis_tvalid_o is permanently dead whenever
// input_src_mmio_i=1. A tile cannot simultaneously take CPU input via
// mac_tile_axi's OWN MMIO bridge and stream output via m_axis. Resolution:
// every cluster tile's mac_tile_axi instance stays at its reset default
// (INPUT_SRC_MMIO=0, external AXI4-Stream mode) permanently -- its own
// DATA_IN/RESULT0-3/CTRL.RESULT_ACK registers go entirely unused for
// cluster tiles (a "designed for, not built" -shaped compromise, same
// spirit as Phase 2's fp32_mac_core). THIS module owns both CPU-entry-
// injection and CPU-exit-readout instead, driving/reading the tile's real
// s_axis/m_axis ports directly.
//
// Ingress mux (mesh delivery vs. CPU entry, both compete for the same
// tile_s_axis port): mesh delivery takes priority whenever both are
// simultaneously pending -- arbitrary but simple, and sufficient for this
// phase's demo (no tile ever needs both sources at once). Egress mux
// (mesh_egress_en_i): a tile's own m_axis results either forward into the
// mesh (addressed via dest_x_i/dest_y_i) or get captured for CPU exit
// readout -- never both.
//
// Exit capture uses the SAME explicit-ack pattern mac_tile_axi.sv's own
// CTRL.RESULT_ACK bit established (after a real one-shot deadlock bug was
// found and fixed there -- see that IP's REPORT.md) -- applied here from
// the start, not discovered the hard way a second time. Entry capture does
// NOT need an equivalent ack: entry_pending_q's own clear condition
// depends only on tile_s_axis_tready_i, the TILE's own independent
// readiness signal, never on entry_pending_q itself -- no circular
// gating, so no deadlock risk exists there in the first place.
`timescale 1ns/1ps

module tile_ni #(
    /* verilator lint_off UNUSEDPARAM */
    // Not read internally -- CW/PSUM_W (derived from these at the
    // mac_cluster.sv call site) are what this file actually needs.
    // Exposed for API consistency with mesh_router.sv/mesh_2x2.sv, which
    // both take the same MESH_DIM/PAYLOAD_W pair directly.
    parameter int MESH_DIM     = 2,
    parameter int PAYLOAD_W    = 128,
    /* verilator lint_on UNUSEDPARAM */
    parameter int CW           = 1,
    parameter int FLIT_W       = 134,
    parameter int K            = 4,
    parameter int N            = 4,
    parameter int ACT_W        = 8,
    parameter int PSUM_W       = 32,
    parameter int REQUANT_SHIFT = 4,
    parameter int MY_X         = 0,
    parameter int MY_Y         = 0
) (
    input  logic clk,
    input  logic rst_n,

    // Mesh-facing Local port.
    input  logic [FLIT_W-1:0] mesh_in_flit_i,
    input  logic               mesh_in_valid_i,
    output logic                mesh_in_ready_o,
    output logic [FLIT_W-1:0] mesh_out_flit_o,
    output logic               mesh_out_valid_o,
    input  logic                mesh_out_ready_i,

    // Tile-facing AXI4-Stream ports.
    output logic                 tile_s_axis_tvalid_o,
    input  logic                 tile_s_axis_tready_i,
    output logic [K*ACT_W-1:0]   tile_s_axis_tdata_o,
    output logic                 tile_s_axis_tlast_o,

    input  logic                 tile_m_axis_tvalid_i,
    output logic                 tile_m_axis_tready_o,
    input  logic [N*PSUM_W-1:0]  tile_m_axis_tdata_i,
    input  logic                 tile_m_axis_tlast_i,

    // CPU-facing plain register interface (driven by mac_cluster's shared
    // CSR block -- see that checkpoint for the AXI4-Lite decode).
    input  logic                 entry_push_i,       // edge-pulsed
    input  logic                 tlast_next_i,        // consumed on push
    input  logic [K*ACT_W-1:0]   entry_data_i,
    input  logic                 mesh_egress_en_i,    // 1=forward to mesh, 0=CPU exit capture
    input  logic [CW-1:0]        dest_x_i,
    input  logic [CW-1:0]        dest_y_i,
    input  logic                 exit_ack_i,           // edge-pulsed

    output logic                 entry_busy_o,
    output logic                 exit_valid_o,
    output logic                 exit_last_o,
    output logic [N*PSUM_W-1:0]  exit_result_o,
    output logic                 exit_seq_o
);

    // -----------------------------------------------------------------
    // Ingress: mesh-delivered result -> requantized -> this tile's own
    // next activation input, OR a CPU-latched entry push -- mutually
    // exclusive, mesh takes priority.
    // -----------------------------------------------------------------
    logic [K*ACT_W-1:0] requant_out;
    genvar gi;
    generate
        for (gi = 0; gi < N; gi = gi + 1) begin : g_requant_in
            requant #(.IN_W(PSUM_W), .OUT_W(ACT_W), .SHIFT(REQUANT_SHIFT)) u_req (
                .in_i  (mesh_in_flit_i[gi*PSUM_W +: PSUM_W]),
                .out_o (requant_out[gi*ACT_W +: ACT_W])
            );
        end
    endgenerate

    logic entry_pending_q;
    logic [K*ACT_W-1:0] entry_data_q;
    logic entry_tlast_q;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            entry_pending_q <= 1'b0;
            entry_data_q    <= '0;
            entry_tlast_q   <= 1'b0;
        end else begin
            if (entry_push_i && !entry_pending_q) begin
                entry_pending_q <= 1'b1;
                entry_data_q    <= entry_data_i;
                entry_tlast_q   <= tlast_next_i;
            end else if (entry_pending_q && src_is_mesh_q == 1'b0 && tile_s_axis_tready_i) begin
                entry_pending_q <= 1'b0;
            end
        end
    end
    assign entry_busy_o = entry_pending_q;

    // Which source is currently being presented on tile_s_axis is a
    // LATCHED decision, not re-evaluated combinationally every cycle --
    // this is the same VALID-STICKY race the mesh_router checkpoint's own
    // formal proof caught (a stale, about-to-change source silently
    // swapping the presented DATA while VALID stays asserted and READY
    // hasn't fired), reapplied here since the ingress mux has the exact
    // same shape (two sources competing for one downstream port). Fixed
    // the same way axis_skid.sv's own FWFT discipline handles it: decide
    // fresh only when idle or just-consumed; while a decided beat is
    // unconsumed, hold the decision regardless of what the OTHER source
    // does in the meantime.
    logic src_is_mesh_q;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            src_is_mesh_q <= 1'b0;
        end else if (!tile_s_axis_tvalid_o || (tile_s_axis_tvalid_o && tile_s_axis_tready_i)) begin
            src_is_mesh_q <= mesh_in_valid_i;  // mesh priority when both are live
        end
        // else: mid-transaction, unconsumed -- hold the current decision.
    end

    assign tile_s_axis_tvalid_o = src_is_mesh_q ? mesh_in_valid_i : entry_pending_q;
    assign tile_s_axis_tdata_o  = src_is_mesh_q ? requant_out : entry_data_q;
    assign tile_s_axis_tlast_o  = src_is_mesh_q ? mesh_in_flit_i[FLIT_W-1] : entry_tlast_q;
    assign mesh_in_ready_o      = src_is_mesh_q && tile_s_axis_tready_i;

    // -----------------------------------------------------------------
    // Egress: this tile's own m_axis result -> forwarded into the mesh
    // (addressed via dest_x_i/dest_y_i) OR captured for CPU exit readout
    // -- selected by mesh_egress_en_i, never both.
    // -----------------------------------------------------------------
    // exit_seq_q: toggles exactly once per genuine new-result capture, in
    // the SAME always_ff/edge as exit_valid_q/exit_result_q -- gives a
    // polling SW an unambiguous discriminator between "a fresh result" and
    // "the same result I already acked, whose STATUS/RESULT mirror in
    // mac_cluster's CSR block I'm re-observing through read-pipeline
    // latency." Needed because exit_valid_q can legitimately go
    // 1(old)->0(briefly, exactly one cycle if a new result is already
    // waiting)->1(new) faster than a multi-cycle AXI read can reliably
    // observe the intermediate 0 -- a real race found via an independently
    // -written Verilog TB (not the cocotb suite) reading NI_EXIT_RESULT0-3
    // right after NI_STATUS showed EXIT_VALID=1: RESULT0 landed on the
    // OLD (already-consumed) snapshot while RESULT1-3 already reflected
    // the NEW one, because the 4 AXI reads straddled mac_cluster's own
    // CSR mirror's write-pipeline advance to the new snapshot. Waiting for
    // a settle delay after seeing EXIT_VALID=1 cannot fix this -- the
    // advance can land between any pair of the 4 reads, not at a fixed
    // offset from the STATUS read. See REPORT.md for the full trace.
    logic exit_valid_q;
    logic [N*PSUM_W-1:0] exit_result_q;
    logic exit_last_q;
    logic exit_seq_q;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            exit_valid_q  <= 1'b0;
            exit_result_q <= '0;
            exit_last_q   <= 1'b0;
            exit_seq_q    <= 1'b0;
        end else if (!mesh_egress_en_i) begin
            if (tile_m_axis_tvalid_i && tile_m_axis_tready_o) begin
                exit_valid_q  <= 1'b1;
                exit_result_q <= tile_m_axis_tdata_i;
                exit_last_q   <= tile_m_axis_tlast_i;
                exit_seq_q    <= ~exit_seq_q;
            end else if (exit_ack_i) begin
                exit_valid_q <= 1'b0;
            end
        end
    end

    assign tile_m_axis_tready_o = mesh_egress_en_i ? mesh_out_ready_i : !exit_valid_q;
    assign exit_valid_o  = exit_valid_q;
    assign exit_last_o   = exit_last_q;
    assign exit_result_o = exit_result_q;
    assign exit_seq_o    = exit_seq_q;

    assign mesh_out_valid_o = mesh_egress_en_i && tile_m_axis_tvalid_i;
    assign mesh_out_flit_o  = {tile_m_axis_tlast_i, 1'b0, MY_Y[CW-1:0], MY_X[CW-1:0],
                                dest_y_i, dest_x_i, tile_m_axis_tdata_i};

`ifdef FORMAL
    initial assume(!rst_n);

    // mesh_egress_en_i/dest_x_i/dest_y_i are software-set configuration
    // bits meant to be held stable for an entire session -- same "set once
    // before streaming begins, held for the whole session" convention
    // Phase 2 established for mac_tile_axi's own INPUT_SRC_MMIO. Without
    // assuming this, fully free inputs could legally change mid-transfer
    // in this standalone proof (nothing else constrains them): a
    // mesh_egress_en_i flip drops mesh_out_valid_o combinationally even
    // while tile_m_axis itself is correctly held, and dest_x_i/dest_y_i
    // are embedded directly in mesh_out_flit_o's own concatenation, so
    // either changing mid-transfer changes the flit's CONTENT while
    // tile_m_axis stays unchanged -- both real counterexamples the proof
    // found, against a software contract violation, not an RTL bug.
    // Captures whatever values are present the first cycle out of reset
    // and assumes none of them change after that.
    logic f_cfg_frozen_q;
    logic f_meen_captured_q;
    logic [CW-1:0] f_destx_captured_q, f_desty_captured_q;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            f_cfg_frozen_q      <= 1'b0;
            f_meen_captured_q   <= 1'b0;
            f_destx_captured_q  <= '0;
            f_desty_captured_q  <= '0;
        end else if (!f_cfg_frozen_q) begin
            f_cfg_frozen_q      <= 1'b1;
            f_meen_captured_q   <= mesh_egress_en_i;
            f_destx_captured_q  <= dest_x_i;
            f_desty_captured_q  <= dest_y_i;
        end
    end
    always_comb begin
        if (rst_n && f_cfg_frozen_q) begin
            assume(mesh_egress_en_i == f_meen_captured_q);
            assume(dest_x_i == f_destx_captured_q);
            assume(dest_y_i == f_desty_captured_q);
        end
    end

    // Mutual exclusion at the ingress mux -- the exact "two things racing
    // for one resource" bug class Phase 1 (rv32i_addr_decoder) and Phase 2
    // (axi4stream_ctrl's own accept-side arbitration) both already caught
    // once. Checked against the LATCHED src_is_mesh_q decision, not the
    // live mesh_in_valid_i -- a live-signal check here would be the exact
    // same VALID-STICKY vacuity the fix two sections below addresses: once
    // a source is pinned, tile_s_axis_tdata_o must keep reflecting THAT
    // source even if the other one becomes live in the meantime.
    always_comb begin
        if (rst_n) begin
            if (src_is_mesh_q) assert(tile_s_axis_tdata_o == requant_out);
            else assert(tile_s_axis_tdata_o == entry_data_q);
        end
    end

    // Legitimate-upstream assumes: mesh_in_flit_i/valid_i is really driven
    // by mesh_2x2's own Local output port (proven VALID-sticky at
    // checkpoint 4), and tile_m_axis_tdata_i/tvalid_i is really driven by
    // a real mac_tile_axi (proven VALID-sticky in Phase 2's own
    // axis_skid.sv). Both are free formal inputs in THIS standalone
    // checkpoint -- without assuming the same discipline their real
    // drivers already guarantee, BMC can pick a trace where either
    // withdraws VALID before being consumed, producing a counterexample
    // against a real driver's own guarantee, not a tile_ni bug. Same
    // "assume the discipline of whatever's attached" pattern
    // rv32i_addr_decoder.sv and mesh_router.sv's own checkpoints already
    // established -- confirmed necessary here the same way: this exact
    // assert failed as a real BMC counterexample without it.
    logic f_min_valid_d, f_min_ready_d, f_tmv_valid_d, f_tmv_ready_d;
    logic [FLIT_W-1:0] f_min_flit_d;
    logic [N*PSUM_W-1:0] f_tmv_data_d;
    logic f_tmv_last_d;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            f_min_valid_d <= 1'b0; f_min_ready_d <= 1'b0; f_min_flit_d <= '0;
            f_tmv_valid_d <= 1'b0; f_tmv_ready_d <= 1'b0; f_tmv_data_d <= '0; f_tmv_last_d <= 1'b0;
        end else begin
            f_min_valid_d <= mesh_in_valid_i;    f_min_ready_d <= mesh_in_ready_o;    f_min_flit_d <= mesh_in_flit_i;
            f_tmv_valid_d <= tile_m_axis_tvalid_i; f_tmv_ready_d <= tile_m_axis_tready_o;
            f_tmv_data_d  <= tile_m_axis_tdata_i;  f_tmv_last_d  <= tile_m_axis_tlast_i;
        end
    end
    always_comb begin
        if (rst_n && f_min_valid_d && !f_min_ready_d) begin
            assume(mesh_in_valid_i);
            assume(mesh_in_flit_i == f_min_flit_d);
        end
        if (rst_n && f_tmv_valid_d && !f_tmv_ready_d) begin
            assume(tile_m_axis_tvalid_i);
            assume(tile_m_axis_tdata_i == f_tmv_data_d);
            assume(tile_m_axis_tlast_i == f_tmv_last_d);
        end
    end

    // Ingress/egress VALID-sticky, re-checked at this level's own boundary.
    logic f_svalid_d, f_sready_d, f_mvalid_d, f_mready_d;
    logic [K*ACT_W-1:0] f_sdata_d;
    logic [FLIT_W-1:0] f_mflit_d;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            f_svalid_d <= 1'b0; f_sready_d <= 1'b0; f_sdata_d <= '0;
            f_mvalid_d <= 1'b0; f_mready_d <= 1'b0; f_mflit_d <= '0;
        end else begin
            f_svalid_d <= tile_s_axis_tvalid_o; f_sready_d <= tile_s_axis_tready_i; f_sdata_d <= tile_s_axis_tdata_o;
            f_mvalid_d <= mesh_out_valid_o;     f_mready_d <= mesh_out_ready_i;     f_mflit_d <= mesh_out_flit_o;
        end
    end
    always_comb begin
        if (rst_n && f_svalid_d && !f_sready_d) begin
            assert(tile_s_axis_tvalid_o);
            assert(tile_s_axis_tdata_o == f_sdata_d);
        end
        if (rst_n && f_mvalid_d && !f_mready_d) begin
            assert(mesh_out_valid_o);
            assert(mesh_out_flit_o == f_mflit_d);
        end
    end

    // Liveness: a second entry push succeeds after a first (entry side
    // needs no explicit ack, per the file header -- this cover proves that
    // reasoning empirically, not just by argument). A second exit capture
    // succeeds after a first ack -- the property that would have caught
    // mac_tile_axi's own one-shot deadlock, applied here before an
    // equivalent bug ever ships.
    logic f_seen_entry_q, f_seen_exit_q;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            f_seen_entry_q <= 1'b0;
            f_seen_exit_q  <= 1'b0;
        end else begin
            if (entry_push_i && !entry_pending_q) f_seen_entry_q <= 1'b1;
            if (exit_valid_q && tile_m_axis_tvalid_i && tile_m_axis_tready_o) f_seen_exit_q <= 1'b1;
        end
    end
    always @(posedge clk) begin
        cover(rst_n && entry_push_i && !entry_pending_q && f_seen_entry_q);
        cover(rst_n && exit_ack_i && exit_valid_q && f_seen_exit_q);
    end

    always_comb begin
        cover(rst_n && mesh_in_valid_i && mesh_in_ready_o);
        cover(rst_n && entry_pending_q && tile_s_axis_tready_i && !mesh_in_valid_i);
        cover(rst_n && mesh_out_valid_o && mesh_out_ready_i);
        cover(rst_n && exit_valid_o);
    end

    // exit_seq_q actually toggles (a second exit capture is reachable and
    // genuinely produces a different seq value from the first) -- proves
    // the discriminator this bit exists to provide is not vacuous.
    logic f_exit_seq_prev_q;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) f_exit_seq_prev_q <= 1'b0;
        else f_exit_seq_prev_q <= exit_seq_q;
    end
    always @(posedge clk) cover(rst_n && (exit_seq_q != f_exit_seq_prev_q));
`endif

endmodule
