// axi4stream_ctrl.sv -- glue FSM around systolic_array_4x4: TDATA pack/
// unpack, s_axis/MMIO accept-side mutual exclusion, weight-load gating,
// and an occupancy/TLAST tag chain that rides through the array in lockstep
// with its own pipeline_en_i.
//
// Two input sources (external s_axis, internal MMIO push) are mutually
// exclusive via input_src_mmio_i, a mode bit latched once for the whole
// session by mac_tile_axi -- never both live. In external mode the array
// runs fully pipelined (1 vector/cycle steady state), freezing only when
// the output axis_skid can't accept another result. In MMIO mode the array
// never holds more than one vector in flight at all (software-polled,
// one-at-a-time by design -- see Phase 2 plan Sec 5), so it never needs to
// freeze.
`timescale 1ns/1ps

module axi4stream_ctrl #(
    parameter int K       = 4,
    parameter int N       = 4,
    parameter int LATENCY = 1,
    parameter int ACT_W   = 8,
    parameter int PSUM_W  = 32
) (
    input  logic clk,
    input  logic rst_n,

    // External AXI4-Stream slave port (activations in).
    input  logic                 s_axis_tvalid_i,
    output logic                 s_axis_tready_o,
    input  logic [K*ACT_W-1:0]   s_axis_tdata_i,
    input  logic                 s_axis_tlast_i,

    // External AXI4-Stream master port (results out).
    output logic                 m_axis_tvalid_o,
    input  logic                 m_axis_tready_i,
    output logic [N*PSUM_W-1:0]  m_axis_tdata_o,
    output logic                 m_axis_tlast_o,

    // MMIO push/pop bridge (mac_tile_axi's own CPU-facing path).
    input  logic                 mmio_data_in_valid_i,
    output logic                 mmio_data_in_ready_o,
    input  logic [K*ACT_W-1:0]   mmio_data_in_i,
    input  logic                 mmio_tlast_next_i,
    // Explicit software acknowledge for the latched MMIO result -- a new
    // push CANNOT implicitly clear it (mmio_data_in_ready_o is itself
    // gated on the prior result already being clear, so waiting for "the
    // next push" to clear it is a same-cycle deadlock; see mac_tile_axi.sv's
    // header comment for the full incident this was caught from).
    input  logic                 mmio_result_ack_i,

    output logic                 mmio_result_valid_o,
    output logic [N*PSUM_W-1:0]  mmio_result_data_o,
    output logic                 mmio_result_last_o,

    input  logic                 input_src_mmio_i,

    // Weight load -- raw LOAD_WEIGHTS pulse, gated on !busy internally.
    input  logic [K*N*ACT_W-1:0] weight_i,
    input  logic                 weight_we_i,
    output logic                 weights_loaded_o,

    output logic                 busy_o
);

    localparam int TRANSIT_DEPTH = (K + N - 1) * LATENCY;  // 7 at LATENCY=1

    // -----------------------------------------------------------------
    // Accept-side arbitration.
    // -----------------------------------------------------------------
    logic array_pipeline_en;
    logic skid_s_ready;
    logic mmio_result_valid_q;

    assign s_axis_tready_o      = !input_src_mmio_i && array_pipeline_en;
    // One vector in flight at a time on the MMIO path: don't accept a new
    // push while the previous MMIO result hasn't been read yet.
    assign mmio_data_in_ready_o =  input_src_mmio_i && array_pipeline_en && !mmio_result_valid_q;

    // Accept = valid && ready, derived from the SAME ready_o signals
    // exposed externally -- not a separately re-derived condition. An
    // earlier draft computed mmio_accept from array_pipeline_en directly
    // (omitting the !mmio_result_valid_q term mmio_data_in_ready_o
    // includes), which would have silently accepted a same-cycle MMIO
    // push even while mmio_data_in_ready_o was reporting not-ready --
    // caught before it ever reached simulation by re-deriving this
    // against the register-map wiring in mac_tile_axi.sv.
    wire s_axis_accept = s_axis_tvalid_i && s_axis_tready_o;
    wire mmio_accept   = mmio_data_in_valid_i && mmio_data_in_ready_o;

    logic [K*ACT_W-1:0] accept_data;
    logic                accept_tlast;
    logic                accept_valid;
    assign accept_valid = s_axis_accept || mmio_accept;
    assign accept_data  = s_axis_accept ? s_axis_tdata_i : mmio_data_in_i;
    assign accept_tlast = s_axis_accept ? s_axis_tlast_i : mmio_tlast_next_i;

    // MMIO mode never has more than one vector in flight (see
    // mmio_data_in_ready_o above), so it never needs to freeze; external
    // mode freezes whenever the output skid can't accept another result.
    assign array_pipeline_en = input_src_mmio_i ? 1'b1 : skid_s_ready;

    // -----------------------------------------------------------------
    // The array itself.
    // -----------------------------------------------------------------
    logic [N*PSUM_W-1:0] array_psum_out;
    logic                 weight_we_gated;

    systolic_array_4x4 #(
        .K       (K),
        .N       (N),
        .LATENCY (LATENCY),
        .ACT_W   (ACT_W),
        .PSUM_W  (PSUM_W)
    ) u_array (
        .clk           (clk),
        .rst_n         (rst_n),
        .pipeline_en_i (array_pipeline_en),
        .act_in_i      (accept_data),
        .psum_out_o    (array_psum_out),
        .weight_i      (weight_i),
        .weight_we_i   (weight_we_gated)
    );

    // -----------------------------------------------------------------
    // Occupancy / TLAST tag chain -- tracks, at each of the array's
    // TRANSIT_DEPTH internal cycle-stages, whether a real (non-bubble)
    // vector occupies that stage and its TLAST tag. Rides through in
    // lockstep with the array's own pipeline_en_i, so the tag and the
    // data it describes always emerge together. Hand-rolled here (not an
    // instance of skew_chain.sv) because busy_o needs visibility into
    // EVERY stage (an OR-reduce across the whole chain), not just the
    // final tap skew_chain's own interface exposes.
    // -----------------------------------------------------------------
    logic occ_q       [TRANSIT_DEPTH];
    logic tlast_tag_q [TRANSIT_DEPTH];
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (int k = 0; k < TRANSIT_DEPTH; k++) begin
                occ_q[k]       <= 1'b0;
                tlast_tag_q[k] <= 1'b0;
            end
        end else if (array_pipeline_en) begin
            occ_q[0]       <= accept_valid;
            tlast_tag_q[0] <= accept_tlast;
            for (int k = 1; k < TRANSIT_DEPTH; k++) begin
                occ_q[k]       <= occ_q[k-1];
                tlast_tag_q[k] <= tlast_tag_q[k-1];
            end
        end
    end

    wire drain_valid = occ_q[TRANSIT_DEPTH-1];
    wire drain_tlast = tlast_tag_q[TRANSIT_DEPTH-1];

    logic busy_comb;
    always_comb begin
        busy_comb = 1'b0;
        for (int k = 0; k < TRANSIT_DEPTH; k++) busy_comb = busy_comb | occ_q[k];
    end
    assign busy_o = busy_comb;

    // -----------------------------------------------------------------
    // Weight load: dropped while busy (Phase 2 plan Sec 4) -- a
    // LOAD_WEIGHTS pulse arriving mid-transit would let vectors already
    // in flight see mixed old/new weights.
    // -----------------------------------------------------------------
    assign weight_we_gated = weight_we_i && !busy_comb;

    logic weights_loaded_q;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n)                    weights_loaded_q <= 1'b0;
        else if (weight_we_gated)      weights_loaded_q <= 1'b1;
    end
    assign weights_loaded_o = weights_loaded_q;

    // -----------------------------------------------------------------
    // Drain side -- routed to whichever path matches the currently-active
    // mode. Mode is latched for a whole session (mac_tile_axi.sv), so this
    // is never ambiguous for any vector actually in flight: every vector
    // that entered did so under the mode active at accept-time, and the
    // mode cannot change while anything is in flight (input_src_mmio_i is
    // set once, before any streaming begins).
    // -----------------------------------------------------------------
    logic                 skid_s_valid;
    logic [N*PSUM_W:0]    skid_s_data;   // {tlast, psum vector}
    logic [N*PSUM_W:0]    skid_m_data;

    assign skid_s_valid = !input_src_mmio_i && drain_valid;
    assign skid_s_data  = {drain_tlast, array_psum_out};

    axis_skid #(.WIDTH(N*PSUM_W + 1)) u_out_skid (
        .clk       (clk),
        .rst_n     (rst_n),
        .s_valid_i (skid_s_valid),
        .s_ready_o (skid_s_ready),
        .s_data_i  (skid_s_data),
        .m_valid_o (m_axis_tvalid_o),
        .m_ready_i (m_axis_tready_i),
        .m_data_o  (skid_m_data)
    );
    assign {m_axis_tlast_o, m_axis_tdata_o} = skid_m_data;

    logic [N*PSUM_W-1:0] mmio_result_data_q;
    logic                 mmio_result_last_q;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            mmio_result_valid_q <= 1'b0;
            mmio_result_data_q  <= '0;
            mmio_result_last_q  <= 1'b0;
        end else begin
            if (input_src_mmio_i && drain_valid) begin
                mmio_result_valid_q <= 1'b1;
                mmio_result_data_q  <= array_psum_out;
                mmio_result_last_q  <= drain_tlast;
            end else if (mmio_accept || mmio_result_ack_i) begin
                // mmio_accept can only ever fire AFTER mmio_result_ack_i
                // already cleared the flag on a prior cycle -- it is kept
                // here only as a belt-and-suspenders same-cycle clear, not
                // as the primary mechanism (see mac_tile_axi.sv's header
                // comment: relying on mmio_accept alone is the exact
                // deadlock this port was added to fix, since
                // mmio_data_in_ready_o -- and therefore mmio_accept -- is
                // itself gated on mmio_result_valid_q already being clear).
                mmio_result_valid_q <= 1'b0;
            end
        end
    end
    assign mmio_result_valid_o = mmio_result_valid_q;
    assign mmio_result_data_o  = mmio_result_data_q;
    assign mmio_result_last_o  = mmio_result_last_q;

`ifdef FORMAL
    initial assume(!rst_n);

    // Mutual exclusion at the accept side: the two input sources never
    // both fire the same cycle -- the exact "two things racing for one
    // resource" bug class Phase 1's adversarial review caught once
    // already (rv32i_addr_decoder).
    always_comb begin
        if (rst_n) assert(!(s_axis_accept && mmio_accept));
    end

    // Weight-load-dropped-while-busy: the gated pulse only ever fires
    // when busy_comb was 0.
    always_comb begin
        if (rst_n && weight_we_gated) assert(!busy_comb);
    end

    // busy_o is exactly the OR-reduce of the occupancy chain (checked
    // directly against an independently-computed reduction, not by
    // re-reading the same busy_comb variable the RTL itself assigns from
    // -- that would be circular. Recomputed fresh here.).
    logic f_busy_expect;
    always_comb begin
        f_busy_expect = 1'b0;
        for (int k = 0; k < TRANSIT_DEPTH; k++) f_busy_expect = f_busy_expect | occ_q[k];
    end
    always_comb begin
        if (rst_n) assert(busy_o == f_busy_expect);
    end

    // weights_loaded_o is sticky: never clears once set (no reset event
    // in this window).
    logic f_wl_d;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) f_wl_d <= 1'b0;
        else        f_wl_d <= weights_loaded_o;
    end
    always_comb begin
        if (rst_n && f_wl_d) assert(weights_loaded_o);
    end

    // mmio_data_in_ready_o never asserts while a prior MMIO result is
    // still unread (the one-vector-at-a-time contract).
    always_comb begin
        if (rst_n && mmio_result_valid_q) assert(!mmio_data_in_ready_o);
    end

    // Recoverability: the exact liveness gap whose absence let the
    // one-shot MMIO deadlock ship silently (see mac_tile_axi.sv's header
    // comment for the full incident) -- the safety property above holds
    // on a permanently-deadlocked design too, so it alone can't catch this
    // class of bug. These cover points only become reachable if
    // mmio_result_ack_i genuinely restores mmio_data_in_ready_o and a
    // SECOND mmio_accept genuinely follows a first -- unreachable on the
    // pre-fix RTL (mmio_data_in_ready_o could never return to 1 after the
    // first result latched).
    logic f_seen_first_accept_q;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) f_seen_first_accept_q <= 1'b0;
        else if (mmio_accept) f_seen_first_accept_q <= 1'b1;
    end

    always_comb begin
        cover(rst_n && s_axis_accept);
        cover(rst_n && mmio_accept);
        cover(rst_n && drain_valid);
        cover(rst_n && weight_we_gated);
        cover(rst_n && mmio_result_ack_i && mmio_result_valid_q);
        cover(rst_n && f_seen_first_accept_q && mmio_data_in_ready_o);
        cover(rst_n && f_seen_first_accept_q && mmio_accept);
    end
`endif

endmodule
