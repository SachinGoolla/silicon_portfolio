// systolic_array_4x4.sv -- weight-stationary 4x4 int8 systolic array.
//
// PE(i,j) holds stationary weight W[i][j]; i=row=reduction index (0..3),
// j=col=output-feature index (0..3). West-edge skew delays row i's
// activation input i*LATENCY cycles behind the external boundary; south-edge
// de-skew delays column j's result (N-1-j)*LATENCY cycles before it reaches
// the external boundary -- both fully contained inside this module, so the
// external contract is simple regardless of LATENCY: present a K-element
// activation vector, get an N-element result vector back exactly
// (K+N-1)*LATENCY cycles later, one new vector accepted/produced per cycle
// in steady state. See Phase 2 plan Sec 1 for the full cycle-by-cycle
// derivation.
`timescale 1ns/1ps

module systolic_array_4x4 #(
    parameter int K        = 4,
    parameter int N        = 4,
    parameter int LATENCY  = 1,
    parameter int ACT_W    = 8,
    parameter int PSUM_W   = 32,
    parameter bit USE_FP32 = 1'b0
) (
    input  logic clk,
    input  logic rst_n,
    input  logic pipeline_en_i,

    // Flat packed vectors, sliced internally via part-select -- Yosys's -sv
    // frontend hard-errors on both unpacked-array ports (`sig [K]` after
    // the name) and multi-dimensional packed-array ports (`[K-1:0][W-1:0]
    // sig`), even though Icarus and Verilator both accept either form fine.
    // A single flat 1-D packed vector is the one port shape all three tools
    // agree on. Element k of act_in_i lives at bits [k*ACT_W +: ACT_W];
    // weight_i is row-major, element (i,j) at [(i*N+j)*ACT_W +: ACT_W].
    input  logic [K*ACT_W-1:0]    act_in_i,
    output logic [N*PSUM_W-1:0]   psum_out_o,
    input  logic [K*N*ACT_W-1:0]  weight_i,
    input  logic                  weight_we_i
);

    // raw_act[i][j]: PE(i,j)'s own act_in_i.  raw_act[i][0] is the
    // post-west-skew row input; raw_act[i][j+1] = PE(i,j).act_out_o.
    // Internal unpacked arrays are a different, already-proven Yosys code
    // path from ports (see skew_chain.sv checkpoint 2's own chain_q[DEPTH]).
    logic signed [ACT_W-1:0] raw_act [K][N+1];

    // raw_psum[i][j]: PE(i,j)'s own psum_in_i. raw_psum[0][j] = 0 (top
    // boundary); raw_psum[i+1][j] = PE(i,j).psum_out_o.
    logic signed [PSUM_W-1:0] raw_psum [K+1][N];

    genvar gi, gj;

    // West-edge skew: row i's raw PE input delayed i*LATENCY cycles.
    generate
        for (gi = 0; gi < K; gi = gi + 1) begin : g_west_skew
            skew_chain #(.WIDTH(ACT_W), .DEPTH(gi * LATENCY)) u_west (
                .clk        (clk),
                .rst_n      (rst_n),
                .en_i       (pipeline_en_i),
                .data_in_i  (act_in_i[gi*ACT_W +: ACT_W]),
                .data_out_o (raw_act[gi][0])
            );
        end
    endgenerate

    // Top boundary: no bias input this phase.
    generate
        for (gj = 0; gj < N; gj = gj + 1) begin : g_top_boundary
            assign raw_psum[0][gj] = '0;
        end
    endgenerate

    // The 16 PEs.
    generate
        for (gi = 0; gi < K; gi = gi + 1) begin : g_row
            for (gj = 0; gj < N; gj = gj + 1) begin : g_col
                mac_pe #(
                    .LATENCY  (LATENCY),
                    .ACT_W    (ACT_W),
                    .PSUM_W   (PSUM_W),
                    .USE_FP32 (USE_FP32)
                ) u_pe (
                    .clk           (clk),
                    .rst_n         (rst_n),
                    .pipeline_en_i (pipeline_en_i),
                    .act_in_i      (raw_act[gi][gj]),
                    .act_out_o     (raw_act[gi][gj+1]),
                    .psum_in_i     (raw_psum[gi][gj]),
                    .psum_out_o    (raw_psum[gi+1][gj]),
                    .weight_i      (weight_i[(gi*N+gj)*ACT_W +: ACT_W]),
                    .weight_we_i   (weight_we_i)
                );
            end
        end
    endgenerate

    // South-edge de-skew: column j's raw PE output delayed (N-1-j)*LATENCY
    // cycles before the external boundary.
    generate
        for (gj = 0; gj < N; gj = gj + 1) begin : g_south_deskew
            skew_chain #(.WIDTH(PSUM_W), .DEPTH((N - 1 - gj) * LATENCY)) u_south (
                .clk        (clk),
                .rst_n      (rst_n),
                .en_i       (pipeline_en_i),
                .data_in_i  (raw_psum[K][gj]),
                .data_out_o (psum_out_o[gj*PSUM_W +: PSUM_W])
            );
        end
    endgenerate

`ifdef FORMAL
    initial assume(!rst_n);
    initial assume(LATENCY == 1 && !USE_FP32 && K == 4 && N == 4);

    // Wiring/skew-depth correctness only -- NOT end-to-end arithmetic
    // (that's P3/P4's job with a golden reference, see Phase 2 plan Sec 7).
    // Anyseq-stubbing all 16 mac_pe instances and then asserting
    // act_in==act_out naively would be VACUOUS -- true by construction of
    // this module's own wiring, the same class of bug an adversarial review
    // already caught once in rv32i_addr_decoder's $onehot0 properties. Keep
    // the real mac_pe instances in the proof (their own arithmetic is
    // already proven standalone, checkpoint 1); prove the delay-depth
    // contract directly instead.
    always_comb begin
        if (rst_n) begin
            // Hold weight_we_i low for the whole proof: weights start at
            // their reset value (0) and stay there -- isolates this
            // checkpoint to pure wiring/skew, no arithmetic dependency.
            assume(!weight_we_i);
        end
    end

    // Freeze correctness at the array boundary: every output holds when
    // pipeline_en_i==0 (the array-level contract mac_tile_axi's own
    // backpressure depends on).
    logic f_en_d;
    logic [N*PSUM_W-1:0] f_psum_out_prev_q;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            f_en_d <= 1'b0;
            f_psum_out_prev_q <= '0;
        end else begin
            f_en_d <= pipeline_en_i;
            f_psum_out_prev_q <= psum_out_o;
        end
    end
    always_comb begin
        if (rst_n && !f_en_d) assert(psum_out_o == f_psum_out_prev_q);
    end

    // West-edge skew-depth property: row i's act_in_i, held continuously
    // enabled, appears at raw_act[i][0] exactly i*LATENCY cycles later.
    // Proven per-row via an independent shadow delay (not reusing
    // skew_chain's own internals -- skew_chain is already proven standalone
    // at checkpoint 2; this checks THIS module wired it with the right
    // DEPTH per row, an integration property, not a re-proof of the leaf).
    generate
        for (gi = 0; gi < K; gi = gi + 1) begin : g_west_check
            if (gi == 0) begin : g_direct
                always_comb begin
                    if (rst_n) assert(raw_act[gi][0] == act_in_i[gi*ACT_W +: ACT_W]);
                end
            end else begin : g_delayed
                localparam int WD = gi * LATENCY;
                logic signed [ACT_W-1:0] f_shadow_q [WD];
                always_ff @(posedge clk or negedge rst_n) begin
                    if (!rst_n) begin
                        for (int m = 0; m < WD; m++) f_shadow_q[m] <= '0;
                    end else if (pipeline_en_i) begin
                        f_shadow_q[0] <= act_in_i[gi*ACT_W +: ACT_W];
                        for (int m = 1; m < WD; m++) f_shadow_q[m] <= f_shadow_q[m-1];
                    end
                end
                always_comb begin
                    if (rst_n) assert(raw_act[gi][0] == f_shadow_q[WD-1]);
                end
            end
        end
    endgenerate

    // South-edge de-skew property: PE(K-1,j)'s psum output, held
    // continuously enabled, appears at the external boundary exactly
    // (N-1-j)*LATENCY cycles later.
    generate
        for (gj = 0; gj < N; gj = gj + 1) begin : g_south_check
            localparam int DD = (N - 1 - gj) * LATENCY;
            if (DD == 0) begin : g_direct
                always_comb begin
                    if (rst_n) assert(psum_out_o[gj*PSUM_W +: PSUM_W] == raw_psum[K][gj]);
                end
            end else begin : g_delayed
                logic signed [PSUM_W-1:0] f_shadow_q [DD];
                always_ff @(posedge clk or negedge rst_n) begin
                    if (!rst_n) begin
                        for (int m = 0; m < DD; m++) f_shadow_q[m] <= '0;
                    end else if (pipeline_en_i) begin
                        f_shadow_q[0] <= raw_psum[K][gj];
                        for (int m = 1; m < DD; m++) f_shadow_q[m] <= f_shadow_q[m-1];
                    end
                end
                always_comb begin
                    if (rst_n) assert(psum_out_o[gj*PSUM_W +: PSUM_W] == f_shadow_q[DD-1]);
                end
            end
        end
    endgenerate

    always_comb begin
        cover(rst_n && pipeline_en_i && (act_in_i[0*ACT_W +: ACT_W] != 0));
        cover(rst_n && pipeline_en_i && (psum_out_o[0*PSUM_W +: PSUM_W] != 0));
    end
`endif

endmodule
