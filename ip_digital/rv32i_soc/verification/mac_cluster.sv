// mac_cluster.sv -- top-level composition: 4x mac_tile_axi + 4x tile_ni +
// mesh_2x2, behind an internal 5-way AXI4-Lite address decoder (4 tile
// pages + 1 shared NI-CSR page). Exposes ONE external AXI4-Lite slave
// port, matching mac_tile_axi's own external port shape, so this whole
// cluster drops into rv32i_soc's own decoder the same way Phase 2's
// single-tile mac_tile_axi did (Phase 3 plan §7).
//
// Address map (ADDR_WIDTH=11, addr[10:8]=sub-slave select, addr[7:0]
// passed through -- same "page field, registered select latch, DECERR
// default" discipline as rv32i_addr_decoder.sv, resized for this
// cluster's own 5 internal slaves, written inline rather than as a
// separate reusable module since this decode is specific to this IP's own
// internal wiring, not a general-purpose N-way interconnect):
//   page 0 : tile 0's mac_tile_axi (weight load / control)
//   page 1 : tile 1's mac_tile_axi
//   page 2 : tile 2's mac_tile_axi
//   page 3 : tile 3's mac_tile_axi
//   page 4 : shared NI-CSR block (8 registers per tile, word offset
//            tile*8: +0 NI_CTRL +1 NI_STATUS +2 NI_DEST +3 NI_ENTRY_DATA
//            +4..+7 NI_EXIT_RESULT0-3)
//   else   : DECERR
//
// NI_STATUS bit layout: [0]=ENTRY_BUSY [1]=EXIT_VALID [2]=EXIT_LAST
// [3]=EXIT_SEQ. EXIT_SEQ is REQUIRED reading, not optional: EXIT_VALID
// alone cannot distinguish a genuinely new result from a stale echo of one
// already read+acked -- tile_ni.sv's own header comment on exit_seq_q has
// the full mechanism. SW MUST track the seq value it last consumed per
// tile and only trust EXIT_VALID=1 readings whose EXIT_SEQ differs from
// that. Both this cluster's own TBs (test_mac_cluster.py,
// tb_mac_cluster.sv) implement this; a poller that ignores EXIT_SEQ can
// silently re-read/misinterpret an already-consumed result under
// back-to-back-ready producer traffic (see REPORT.md).
//
// Every mac_tile_axi instance's own INPUT_SRC_MMIO stays at its reset
// default (0, external AXI4-Stream mode) permanently -- tile_ni.sv's own
// header explains why (axi4stream_ctrl.sv's INPUT_SRC_MMIO forks BOTH
// s_axis and m_axis together, so a cluster tile cannot use mac_tile_axi's
// own MMIO bridge and stream its result out at the same time). Each
// mac_tile_axi's own DATA_IN/RESULT0-3/CTRL.RESULT_ACK registers go
// entirely unused here; tile_ni owns CPU entry/exit instead.
`timescale 1ns/1ps

module mac_cluster #(
    parameter int DATA_WIDTH    = 32,
    parameter int ADDR_WIDTH    = 11,
    parameter int MESH_DIM      = 2,
    parameter int K             = 4,
    parameter int N             = 4,
    parameter int ACT_W         = 8,
    parameter int PSUM_W        = 32,
    parameter int LATENCY       = 1,
    parameter int REQUANT_SHIFT = 4
) (
    input  logic clk,
    input  logic rst_n,

    input  logic                      awvalid_i,
    output logic                      awready_o,
    input  logic [ADDR_WIDTH-1:0]     awaddr_i,
    input  logic [2:0]                awprot_i,

    input  logic                      wvalid_i,
    output logic                      wready_o,
    input  logic [DATA_WIDTH-1:0]     wdata_i,
    input  logic [(DATA_WIDTH/8)-1:0] wstrb_i,

    output logic                      bvalid_o,
    input  logic                      bready_i,
    output logic [1:0]                bresp_o,

    input  logic                      arvalid_i,
    output logic                      arready_o,
    input  logic [ADDR_WIDTH-1:0]     araddr_i,
    input  logic [2:0]                arprot_i,

    output logic                      rvalid_o,
    input  logic                      rready_i,
    output logic [DATA_WIDTH-1:0]     rdata_o,
    output logic [1:0]                rresp_o
);

    localparam int CW = 1;  // $clog2(MESH_DIM), MESH_DIM=2 this phase
    localparam int FLIT_W = 2 + 4*CW + N*PSUM_W;  // 134 at defaults
    localparam int TILE_ADDR_WIDTH = 8;  // matches mac_tile_axi's own default

    // -----------------------------------------------------------------
    // Internal 5-way address decoder -- registered select latches
    // captured at AW/AR, held through B/R, self-contained DECERR
    // generator. Same discipline as rv32i_addr_decoder.sv, sized for 5
    // slaves; see that file's own header for the full rationale (an
    // earlier version of THAT decoder had a real vacuous-proof bug and a
    // real address-aliasing bug, both fixed).
    //
    // Unlike rv32i_addr_decoder.sv, no per-slave in-bounds gate is needed
    // here: this decoder's own page size (256B, addr[7:0]) is chosen to
    // exactly match every sub-slave's real ADDR_WIDTH=8 -- there is no
    // "in-page but past the slave's real width" slack to alias into (the
    // aliasing bug that fix pattern guards against). A first draft of this
    // file copied that pattern verbatim anyway (`awaddr_i[7:TILE_ADDR_WIDTH]`
    // with TILE_ADDR_WIDTH=8, i.e. `[7:8]`) -- a backwards, always-true-by-
    // construction range Verilator's own SELRANGE warning caught
    // immediately. Removed rather than patched: the check was checking a
    // condition that can never be false given how this decoder's own page
    // size was chosen, not a real correctness gap.
    // -----------------------------------------------------------------
    localparam logic [2:0] SEL_T0 = 3'd0, SEL_T1 = 3'd1, SEL_T2 = 3'd2,
                            SEL_T3 = 3'd3, SEL_CSR = 3'd4, SEL_NONE = 3'd5;

    wire [2:0] awaddr_page = awaddr_i[10:8];
    wire [2:0] araddr_page = araddr_i[10:8];

    logic [2:0] wsel_decode;
    always_comb begin
        unique case (awaddr_page)
            SEL_T0:  wsel_decode = SEL_T0;
            SEL_T1:  wsel_decode = SEL_T1;
            SEL_T2:  wsel_decode = SEL_T2;
            SEL_T3:  wsel_decode = SEL_T3;
            SEL_CSR: wsel_decode = SEL_CSR;
            default: wsel_decode = SEL_NONE;
        endcase
    end
    logic [2:0] rsel_decode;
    always_comb begin
        unique case (araddr_page)
            SEL_T0:  rsel_decode = SEL_T0;
            SEL_T1:  rsel_decode = SEL_T1;
            SEL_T2:  rsel_decode = SEL_T2;
            SEL_T3:  rsel_decode = SEL_T3;
            SEL_CSR: rsel_decode = SEL_CSR;
            default: rsel_decode = SEL_NONE;
        endcase
    end

    logic [2:0] wsel_q, rsel_q;
    logic wbusy_q, rbusy_q;
    logic [2:0] wsel_active, rsel_active;
    always_comb wsel_active = wbusy_q ? wsel_q : wsel_decode;
    always_comb rsel_active = rbusy_q ? rsel_q : rsel_decode;

    // Per-slave AXI4-Lite signals (internal, non-port unpacked arrays --
    // fine on every tool, only module PORTS need the flat-vector
    // treatment). Index 0-3 = tiles, 4 = shared CSR block.
    logic [4:0] s_awvalid, s_awready, s_wvalid, s_wready;
    logic [4:0] s_bvalid, s_bready;
    logic [1:0] s_bresp [5];
    logic [4:0] s_arvalid, s_arready, s_rvalid, s_rready;
    logic [1:0] s_rresp [5];
    logic [DATA_WIDTH-1:0] s_rdata [5];
    logic [TILE_ADDR_WIDTH-1:0] s_awaddr [5];
    logic [TILE_ADDR_WIDTH-1:0] s_araddr [5];

    logic decerr_aw_pend_q, decerr_w_pend_q, decerr_bvalid_q;
    wire  decerr_wcommit = decerr_aw_pend_q && decerr_w_pend_q &&
                            (!decerr_bvalid_q || bready_i);

    always_comb begin
        for (int i = 0; i < 5; i++) begin
            s_awvalid[i] = awvalid_i && (wsel_active == i[2:0]);
            s_wvalid[i]  = wvalid_i  && (wsel_active == i[2:0]);
            s_awaddr[i]  = awaddr_i[TILE_ADDR_WIDTH-1:0];
            s_arvalid[i] = arvalid_i && (rsel_active == i[2:0]);
            s_araddr[i]  = araddr_i[TILE_ADDR_WIDTH-1:0];
        end
    end

    assign awready_o = (wsel_active == SEL_T0)  ? s_awready[0] :
                        (wsel_active == SEL_T1)  ? s_awready[1] :
                        (wsel_active == SEL_T2)  ? s_awready[2] :
                        (wsel_active == SEL_T3)  ? s_awready[3] :
                        (wsel_active == SEL_CSR) ? s_awready[4] :
                        !decerr_aw_pend_q;
    assign wready_o  = (wsel_active == SEL_T0)  ? s_wready[0] :
                        (wsel_active == SEL_T1)  ? s_wready[1] :
                        (wsel_active == SEL_T2)  ? s_wready[2] :
                        (wsel_active == SEL_T3)  ? s_wready[3] :
                        (wsel_active == SEL_CSR) ? s_wready[4] :
                        !decerr_w_pend_q;

    assign bvalid_o = (wsel_q == SEL_T0)  ? (wbusy_q && s_bvalid[0]) :
                       (wsel_q == SEL_T1)  ? (wbusy_q && s_bvalid[1]) :
                       (wsel_q == SEL_T2)  ? (wbusy_q && s_bvalid[2]) :
                       (wsel_q == SEL_T3)  ? (wbusy_q && s_bvalid[3]) :
                       (wsel_q == SEL_CSR) ? (wbusy_q && s_bvalid[4]) :
                       decerr_bvalid_q;
    assign bresp_o  = (wsel_q == SEL_T0)  ? s_bresp[0] :
                       (wsel_q == SEL_T1)  ? s_bresp[1] :
                       (wsel_q == SEL_T2)  ? s_bresp[2] :
                       (wsel_q == SEL_T3)  ? s_bresp[3] :
                       (wsel_q == SEL_CSR) ? s_bresp[4] :
                       2'b11;
    always_comb begin
        for (int i = 0; i < 5; i++) s_bready[i] = bready_i && wbusy_q && (wsel_q == i[2:0]);
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wbusy_q <= 1'b0; wsel_q <= SEL_NONE;
        end else begin
            if (!wbusy_q && awvalid_i && awready_o) begin
                wbusy_q <= 1'b1; wsel_q <= wsel_decode;
            end else if (wbusy_q && bvalid_o && bready_i) begin
                wbusy_q <= 1'b0;
            end
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            decerr_aw_pend_q <= 1'b0; decerr_w_pend_q <= 1'b0; decerr_bvalid_q <= 1'b0;
        end else begin
            if (awvalid_i && awready_o && (wsel_active == SEL_NONE)) decerr_aw_pend_q <= 1'b1;
            else if (decerr_wcommit) decerr_aw_pend_q <= 1'b0;

            if (wvalid_i && wready_o && (wsel_active == SEL_NONE)) decerr_w_pend_q <= 1'b1;
            else if (decerr_wcommit) decerr_w_pend_q <= 1'b0;

            if (decerr_wcommit) decerr_bvalid_q <= 1'b1;
            else if (decerr_bvalid_q && bready_i) decerr_bvalid_q <= 1'b0;
        end
    end

    assign arready_o = (rsel_active == SEL_T0)  ? s_arready[0] :
                        (rsel_active == SEL_T1)  ? s_arready[1] :
                        (rsel_active == SEL_T2)  ? s_arready[2] :
                        (rsel_active == SEL_T3)  ? s_arready[3] :
                        (rsel_active == SEL_CSR) ? s_arready[4] :
                        !(rbusy_q && rsel_q == SEL_NONE);

    assign rvalid_o = (rsel_q == SEL_T0)  ? (rbusy_q && s_rvalid[0]) :
                       (rsel_q == SEL_T1)  ? (rbusy_q && s_rvalid[1]) :
                       (rsel_q == SEL_T2)  ? (rbusy_q && s_rvalid[2]) :
                       (rsel_q == SEL_T3)  ? (rbusy_q && s_rvalid[3]) :
                       (rsel_q == SEL_CSR) ? (rbusy_q && s_rvalid[4]) :
                       decerr_rvalid_q;
    assign rdata_o = (rsel_q == SEL_T0)  ? s_rdata[0] :
                      (rsel_q == SEL_T1)  ? s_rdata[1] :
                      (rsel_q == SEL_T2)  ? s_rdata[2] :
                      (rsel_q == SEL_T3)  ? s_rdata[3] :
                      (rsel_q == SEL_CSR) ? s_rdata[4] :
                      '0;
    assign rresp_o = (rsel_q == SEL_T0)  ? s_rresp[0] :
                      (rsel_q == SEL_T1)  ? s_rresp[1] :
                      (rsel_q == SEL_T2)  ? s_rresp[2] :
                      (rsel_q == SEL_T3)  ? s_rresp[3] :
                      (rsel_q == SEL_CSR) ? s_rresp[4] :
                      2'b11;
    always_comb begin
        for (int i = 0; i < 5; i++) s_rready[i] = rready_i && rbusy_q && (rsel_q == i[2:0]);
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rbusy_q <= 1'b0; rsel_q <= SEL_NONE;
        end else begin
            if (!rbusy_q && arvalid_i && arready_o) begin
                rbusy_q <= 1'b1; rsel_q <= rsel_decode;
            end else if (rbusy_q && rvalid_o && rready_i) begin
                rbusy_q <= 1'b0;
            end
        end
    end

    /* verilator lint_off UNUSEDSIGNAL */
    // awprot_i/arprot_i -- not decoded by this file or any sub-slave
    // (matches this repo's established convention, e.g. rv32i_addr_decoder
    // and mac_tile_axi's own axi_lite_slave usage never inspect *prot_i
    // either -- PROT is an AXI4-Lite privilege hint this portfolio's own
    // designs don't act on).
    logic _unused;
    assign _unused = ^{awprot_i, arprot_i};
    /* verilator lint_on UNUSEDSIGNAL */

    logic decerr_rvalid_q;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            decerr_rvalid_q <= 1'b0;
        end else begin
            if (arvalid_i && arready_o && (rsel_active == SEL_NONE)) decerr_rvalid_q <= 1'b1;
            else if (decerr_rvalid_q && rready_i) decerr_rvalid_q <= 1'b0;
        end
    end

    // -----------------------------------------------------------------
    // 4x mac_tile_axi, each with its own AXI4-Lite port (page 0-3) and
    // s_axis/m_axis wired to its own tile_ni; 4x tile_ni bridging each
    // tile to mesh_2x2's own Local ports; the shared NI-CSR block.
    // -----------------------------------------------------------------
    logic [4*FLIT_W-1:0] mesh_local_in_flit;
    logic [3:0]          mesh_local_in_valid;
    logic [3:0]          mesh_local_in_ready;
    logic [4*FLIT_W-1:0] mesh_local_out_flit;
    logic [3:0]          mesh_local_out_valid;
    logic [3:0]          mesh_local_out_ready;

    mesh_2x2 #(.MESH_DIM(MESH_DIM), .PAYLOAD_W(N*PSUM_W), .CW(CW), .FLIT_W(FLIT_W)) u_mesh (
        .clk(clk), .rst_n(rst_n),
        .local_in_flit_i  (mesh_local_in_flit),
        .local_in_valid_i (mesh_local_in_valid),
        .local_in_ready_o (mesh_local_in_ready),
        .local_out_flit_o (mesh_local_out_flit),
        .local_out_valid_o(mesh_local_out_valid),
        .local_out_ready_i(mesh_local_out_ready)
    );

    // Shared NI-CSR block: 32 registers, 8 per tile.
    logic [32*DATA_WIDTH-1:0] csr_regfile;
    logic [31:0]              csr_we;
    logic [32*DATA_WIDTH-1:0] csr_hw_wdata;
    logic [31:0]              csr_hw_we;

    axi_lite_slave #(.DATA_WIDTH(DATA_WIDTH), .ADDR_WIDTH(TILE_ADDR_WIDTH), .NUM_REGS(32)) u_csr (
        .clk(clk), .rst_n(rst_n),
        .awvalid_i(s_awvalid[4]), .awready_o(s_awready[4]), .awaddr_i(s_awaddr[4]), .awprot_i(3'b0),
        .wvalid_i(s_wvalid[4]),   .wready_o(s_wready[4]),   .wdata_i(wdata_i), .wstrb_i(wstrb_i),
        .bvalid_o(s_bvalid[4]),   .bready_i(s_bready[4]),   .bresp_o(s_bresp[4]),
        .arvalid_i(s_arvalid[4]), .arready_o(s_arready[4]), .araddr_i(s_araddr[4]), .arprot_i(3'b0),
        .rvalid_o(s_rvalid[4]),   .rready_i(s_rready[4]),   .rdata_o(s_rdata[4]), .rresp_o(s_rresp[4]),
        .regfile_o(csr_regfile),  .reg_we_o(csr_we),
        .hw_wdata_i(csr_hw_wdata), .hw_we_i(csr_hw_we)
    );

    // Registered write-commit pulse per tile's own NI_CTRL register
    // (offset ti*8+0) -- same ctrl_we_q pattern fpu_axi_periph.sv/
    // mac_tile_axi.sv both already established.
    logic [3:0] ctrl_we_q;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) ctrl_we_q <= 4'b0;
        else for (int t = 0; t < 4; t++) ctrl_we_q[t] <= csr_we[t*8+0];
    end

    genvar ti;
    generate
        for (ti = 0; ti < 4; ti = ti + 1) begin : g_tile
            logic                 t_s_axis_tvalid, t_s_axis_tready, t_s_axis_tlast;
            logic [K*ACT_W-1:0]   t_s_axis_tdata;
            logic                 t_m_axis_tvalid, t_m_axis_tready, t_m_axis_tlast;
            logic [N*PSUM_W-1:0]  t_m_axis_tdata;
            logic                 ni_entry_busy, ni_exit_valid, ni_exit_last, ni_exit_seq;
            logic [N*PSUM_W-1:0]  ni_exit_result;

            mac_tile_axi #(.DATA_WIDTH(DATA_WIDTH), .ADDR_WIDTH(TILE_ADDR_WIDTH),
                            .K(K), .N(N), .LATENCY(LATENCY), .ACT_W(ACT_W), .PSUM_W(PSUM_W)) u_tile (
                .clk(clk), .rst_n(rst_n),
                .awvalid_i(s_awvalid[ti]), .awready_o(s_awready[ti]), .awaddr_i(s_awaddr[ti]), .awprot_i(3'b0),
                .wvalid_i(s_wvalid[ti]),   .wready_o(s_wready[ti]),   .wdata_i(wdata_i), .wstrb_i(wstrb_i),
                .bvalid_o(s_bvalid[ti]),   .bready_i(s_bready[ti]),   .bresp_o(s_bresp[ti]),
                .arvalid_i(s_arvalid[ti]), .arready_o(s_arready[ti]), .araddr_i(s_araddr[ti]), .arprot_i(3'b0),
                .rvalid_o(s_rvalid[ti]),   .rready_i(s_rready[ti]),   .rdata_o(s_rdata[ti]), .rresp_o(s_rresp[ti]),
                .s_axis_tvalid_i(t_s_axis_tvalid), .s_axis_tready_o(t_s_axis_tready),
                .s_axis_tdata_i(t_s_axis_tdata),   .s_axis_tlast_i(t_s_axis_tlast),
                .m_axis_tvalid_o(t_m_axis_tvalid), .m_axis_tready_i(t_m_axis_tready),
                .m_axis_tdata_o(t_m_axis_tdata),   .m_axis_tlast_o(t_m_axis_tlast)
            );

            tile_ni #(.MESH_DIM(MESH_DIM), .PAYLOAD_W(N*PSUM_W), .CW(CW), .FLIT_W(FLIT_W),
                       .K(K), .N(N), .ACT_W(ACT_W), .PSUM_W(PSUM_W), .REQUANT_SHIFT(REQUANT_SHIFT),
                       .MY_X(ti % MESH_DIM), .MY_Y(ti / MESH_DIM)) u_ni (
                .clk(clk), .rst_n(rst_n),
                .mesh_in_flit_i  (mesh_local_out_flit[ti*FLIT_W +: FLIT_W]),
                .mesh_in_valid_i (mesh_local_out_valid[ti]),
                .mesh_in_ready_o (mesh_local_out_ready[ti]),
                .mesh_out_flit_o (mesh_local_in_flit[ti*FLIT_W +: FLIT_W]),
                .mesh_out_valid_o(mesh_local_in_valid[ti]),
                .mesh_out_ready_i(mesh_local_in_ready[ti]),
                .tile_s_axis_tvalid_o(t_s_axis_tvalid), .tile_s_axis_tready_i(t_s_axis_tready),
                .tile_s_axis_tdata_o(t_s_axis_tdata),   .tile_s_axis_tlast_o(t_s_axis_tlast),
                .tile_m_axis_tvalid_i(t_m_axis_tvalid), .tile_m_axis_tready_o(t_m_axis_tready),
                .tile_m_axis_tdata_i(t_m_axis_tdata),   .tile_m_axis_tlast_i(t_m_axis_tlast),
                .entry_push_i     (ctrl_we_q[ti] && csr_regfile[(ti*8+0)*DATA_WIDTH+0]),
                .tlast_next_i     (csr_regfile[(ti*8+0)*DATA_WIDTH+1]),
                .entry_data_i     (csr_regfile[(ti*8+3)*DATA_WIDTH +: K*ACT_W]),
                .mesh_egress_en_i (csr_regfile[(ti*8+0)*DATA_WIDTH+2]),
                .dest_x_i         (csr_regfile[(ti*8+2)*DATA_WIDTH+0 +: CW]),
                .dest_y_i         (csr_regfile[(ti*8+2)*DATA_WIDTH+1 +: CW]),
                .exit_ack_i       (ctrl_we_q[ti] && csr_regfile[(ti*8+0)*DATA_WIDTH+3]),
                .entry_busy_o     (ni_entry_busy),
                .exit_valid_o     (ni_exit_valid),
                .exit_last_o      (ni_exit_last),
                .exit_result_o    (ni_exit_result),
                .exit_seq_o       (ni_exit_seq)
            );

            // HW-write-only NI_STATUS/NI_EXIT_RESULT0-3 -- continuous
            // mirror, same discipline as mac_tile_axi.sv's own STATUS reg.
            // NI_STATUS bit3=EXIT_SEQ: REQUIRED reading for SW, see this
            // file's own header comment and tile_ni.sv's exit_seq_q.
            always_comb begin
                csr_hw_we[ti*8+1] = 1'b1;
                csr_hw_wdata[(ti*8+1)*DATA_WIDTH +: DATA_WIDTH] =
                    {{(DATA_WIDTH-4){1'b0}}, ni_exit_seq, ni_exit_last, ni_exit_valid, ni_entry_busy};

                csr_hw_we[ti*8+4]  = ni_exit_valid;
                csr_hw_we[ti*8+5]  = ni_exit_valid;
                csr_hw_we[ti*8+6]  = ni_exit_valid;
                csr_hw_we[ti*8+7]  = ni_exit_valid;
                csr_hw_wdata[(ti*8+4)*DATA_WIDTH +: DATA_WIDTH] = ni_exit_result[0*PSUM_W +: PSUM_W];
                csr_hw_wdata[(ti*8+5)*DATA_WIDTH +: DATA_WIDTH] = ni_exit_result[1*PSUM_W +: PSUM_W];
                csr_hw_wdata[(ti*8+6)*DATA_WIDTH +: DATA_WIDTH] = ni_exit_result[2*PSUM_W +: PSUM_W];
                csr_hw_wdata[(ti*8+7)*DATA_WIDTH +: DATA_WIDTH] = ni_exit_result[3*PSUM_W +: PSUM_W];

                csr_hw_we[ti*8+0] = 1'b0;
                csr_hw_we[ti*8+2] = 1'b0;
                csr_hw_we[ti*8+3] = 1'b0;
                csr_hw_wdata[(ti*8+0)*DATA_WIDTH +: DATA_WIDTH] = '0;
                csr_hw_wdata[(ti*8+2)*DATA_WIDTH +: DATA_WIDTH] = '0;
                csr_hw_wdata[(ti*8+3)*DATA_WIDTH +: DATA_WIDTH] = '0;
            end
        end
    endgenerate

`ifdef FORMAL
    initial assume(!rst_n);

    // Non-tautological cluster sub-decode properties: literal page
    // constants, not this file's own SEL_* localparams -- same
    // anti-vacuity discipline as rv32i_addr_decoder.sv:511-549, applied
    // fresh to THIS file's own new decode logic (decode logic in this
    // repo is two-for-two on shipping a real bug the first time it's
    // written -- Phase 3 plan §6 risk 5 names this explicitly).
    always_comb begin
        if (rst_n) begin
            if (awaddr_page == 3'd0) assert(wsel_decode == 3'd0);
            if (awaddr_page == 3'd1) assert(wsel_decode == 3'd1);
            if (awaddr_page == 3'd2) assert(wsel_decode == 3'd2);
            if (awaddr_page == 3'd3) assert(wsel_decode == 3'd3);
            if (awaddr_page == 3'd4) assert(wsel_decode == 3'd4);
            if (awaddr_page > 3'd4)  assert(wsel_decode == 3'd5);

            assert($onehot0({s_awvalid[0], s_awvalid[1], s_awvalid[2], s_awvalid[3], s_awvalid[4]}));
            assert($onehot0({s_arvalid[0], s_arvalid[1], s_arvalid[2], s_arvalid[3], s_arvalid[4]}));
        end
    end

    always_comb begin
        cover(rst_n && bvalid_o && bready_i && bresp_o == 2'b11);
        cover(rst_n && s_bvalid[0] && s_bready[0]);
        cover(rst_n && s_bvalid[4] && s_bready[4]);
    end
`endif

endmodule
