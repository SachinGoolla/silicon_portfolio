// =============================================================================
// fpu_top.sv  —  Floating-Point Unit Top-Level  (Phase 4)
// =============================================================================
//
// OPCODE ROUTING   op_i[5:4]
//   2'b00  FMA unit    (FADD/FSUB/FMUL/FMADD/FMSUB/FNMADD/FNMSUB)
//   2'b01  Div/Sqrt    (FDIV, FSQRT)
//   2'b10  Conversion  (FCVT.W.S, FCVT.WU.S, FCVT.S.W, FCVT.S.WU, FMV.X.W, FMV.W.X)
//   2'b11  Non-compute (FCLASS, FSGNJ, compare, FMIN/FMAX)
//
// HANDSHAKE:
//   Upstream:   valid_i & ready_o → transfer accepted
//   Downstream: valid_o & ready_i → result consumed
//   busy_o=1 during FDIV/FSQRT iteration; ready_o = ~busy_o
// =============================================================================

module fpu_top #(
    parameter int  FLEN          = 32,
    parameter int  XLEN          = 32,
    parameter bit  FTZ           = 1'b0,  // Flush-to-zero: subnormal inputs/outputs → ±0
    parameter bit  NAN_BOX_CHECK = 1'b1   // RISC-V NaN-boxing: FP32-in-FP64 validation
) (
    input  logic              clk,
    input  logic              rst_n,
    input  logic              valid_i,
    output logic              ready_o,
    input  logic [5:0]        op_i,
    input  logic [1:0]        fmt_i,
    input  logic [2:0]        rm_i,
    input  logic [FLEN-1:0]   src_a_i,
    input  logic [FLEN-1:0]   src_b_i,
    input  logic [FLEN-1:0]   src_c_i,
    input  logic [XLEN-1:0]   int_src_i,
    input  logic              ready_i,
    output logic [FLEN-1:0]   result_o,
    output logic [XLEN-1:0]   int_result_o,
    output logic              valid_o,
    output logic              busy_o,
    output logic [4:0]        fflags_o
);

    /* verilator lint_off UNUSEDSIGNAL */
    logic _unused_ports;
    assign _unused_ports = ^ready_i ^ ^fmt_i;
    /* verilator lint_on UNUSEDSIGNAL */

    // =========================================================================
    // Exponent/mantissa widths (derived from FLEN)
    // =========================================================================
    localparam int EW = (FLEN == 64) ? 11 : (FLEN == 16) ? 5 : 8;  // exponent bits
    localparam int MW = FLEN - EW - 1;                               // mantissa bits

    // =========================================================================
    // NaN-boxing check (RISC-V spec: FP32-in-FP64 — upper 32 bits must be 1s)
    // Active only when FLEN=64 && NAN_BOX_CHECK=1; transparent for FLEN=32
    // =========================================================================
    localparam logic [31:0] CANON_NAN32 = {1'b0, 8'hFF, 22'h0, 1'b1}; // 0x7FC00001
    logic [FLEN-1:0] src_a_nb, src_b_nb;
    generate
        if (FLEN == 64 && NAN_BOX_CHECK) begin : g_nanbox
            wire fp32_op = (fmt_i == 2'b00);
            assign src_a_nb = (fp32_op && src_a_i[63:32] != 32'hFFFF_FFFF) ?
                               {{32{1'b1}}, CANON_NAN32} : src_a_i;
            assign src_b_nb = (fp32_op && src_b_i[63:32] != 32'hFFFF_FFFF) ?
                               {{32{1'b1}}, CANON_NAN32} : src_b_i;
        end else begin : g_nanbox
            assign src_a_nb = src_a_i;
            assign src_b_nb = src_b_i;
        end
    endgenerate

    // =========================================================================
    // FTZ — flush subnormal inputs to ±0 before dispatch
    // Subnormal: exponent field = 0 AND mantissa ≠ 0 (exact zero has mant=0)
    // =========================================================================
    logic [FLEN-1:0] src_a_f, src_b_f, src_c_f;
    generate
        if (FTZ) begin : g_ftz_in
            logic sub_a, sub_b, sub_c;
            assign sub_a = (src_a_nb[FLEN-2 -: EW] == '0) && (src_a_nb[MW-1:0] != '0);
            assign sub_b = (src_b_nb[FLEN-2 -: EW] == '0) && (src_b_nb[MW-1:0] != '0);
            assign sub_c = (src_c_i [FLEN-2 -: EW] == '0) && (src_c_i [MW-1:0] != '0);
            assign src_a_f = sub_a ? {src_a_nb[FLEN-1], {(FLEN-1){1'b0}}} : src_a_nb;
            assign src_b_f = sub_b ? {src_b_nb[FLEN-1], {(FLEN-1){1'b0}}} : src_b_nb;
            assign src_c_f = sub_c ? {src_c_i [FLEN-1], {(FLEN-1){1'b0}}} : src_c_i;
        end else begin : g_ftz_in
            assign src_a_f = src_a_nb;
            assign src_b_f = src_b_nb;
            assign src_c_f = src_c_i;
        end
    endgenerate

    // =========================================================================
    // Decode
    // =========================================================================
    logic sel_fma, sel_div, sel_cvt, sel_noncomp;
    assign sel_fma     = (op_i[5:4] == 2'b00);
    assign sel_div     = (op_i[5:4] == 2'b01);
    assign sel_cvt     = (op_i[5:4] == 2'b10);
    assign sel_noncomp = (op_i[5:4] == 2'b11);

    // =========================================================================
    // Clock-gate enables
    // =========================================================================
    logic fma_clk_en, div_clk_en, cvt_clk_en, ncomp_clk_en;
    logic div_busy;   // from divsqrt unit

    fpu_clk_gate_ctrl u_clk_gate_ctrl (
        .valid_i     (valid_i),
        .op_i        (op_i),
        .busy_div    (div_busy),
        .fma_clk_en  (fma_clk_en),
        .div_clk_en  (div_clk_en),
        .cvt_clk_en  (cvt_clk_en),
        .ncomp_clk_en(ncomp_clk_en)
    );

    /* verilator lint_off UNUSEDSIGNAL */
    logic _unused_clk_en;
    assign _unused_clk_en = fma_clk_en | ncomp_clk_en | div_clk_en | cvt_clk_en;
    /* verilator lint_on UNUSEDSIGNAL */

    // =========================================================================
    // busy / ready
    // =========================================================================
    assign busy_o  = div_busy;
    assign ready_o = ~busy_o;

    // =========================================================================
    // Non-Compute Unit
    // =========================================================================
    logic              ncomp_valid_out;
    logic [FLEN-1:0]   ncomp_result;
    logic [XLEN-1:0]   ncomp_int_result;
    logic [4:0]        ncomp_fflags;

    fpu_noncomp #(.FLEN(FLEN), .XLEN(XLEN)) u_noncomp (
        .clk          (clk),
        .rst_n        (rst_n),
        .valid_i      (valid_i & sel_noncomp),
        .op_i         (op_i[3:0]),
        .fmt_i        (fmt_i),
        .src_a_i      (src_a_f),
        .src_b_i      (src_b_f),
        .valid_o      (ncomp_valid_out),
        .result_o     (ncomp_result),
        .int_result_o (ncomp_int_result),
        .fflags_o     (ncomp_fflags)
    );

    // =========================================================================
    // FMA Unit
    // =========================================================================
    logic              fma_valid_out;
    logic [FLEN-1:0]   fma_result;
    logic [4:0]        fma_fflags;

    fpu_fma #(.FLEN(FLEN)) u_fma (
        .clk      (clk),
        .rst_n    (rst_n),
        .valid_i  (valid_i & sel_fma),
        .op_i     (op_i[3:0]),
        .rm_i     (rm_i),
        .src_a_i  (src_a_f),
        .src_b_i  (src_b_f),
        .src_c_i  (src_c_f),
        .valid_o  (fma_valid_out),
        .result_o (fma_result),
        .fflags_o (fma_fflags)
    );

    // =========================================================================
    // Div/Sqrt Unit
    // =========================================================================
    logic              div_valid_out;
    logic [FLEN-1:0]   div_result;
    logic [4:0]        div_fflags;

    fpu_divsqrt #(.FLEN(FLEN)) u_divsqrt (
        .clk      (clk),
        .rst_n    (rst_n),
        .valid_i  (valid_i & sel_div & ~div_busy),
        .op_i     (op_i[3:0]),
        .rm_i     (rm_i),
        .src_a_i  (src_a_f),
        .src_b_i  (src_b_f),
        .busy_o   (div_busy),
        .valid_o  (div_valid_out),
        .result_o (div_result),
        .fflags_o (div_fflags)
    );

    // =========================================================================
    // CVT Unit
    // =========================================================================
    logic              cvt_valid_out;
    logic [FLEN-1:0]   cvt_result;
    logic [XLEN-1:0]   cvt_int_result;
    logic [4:0]        cvt_fflags;

    fpu_cvt #(.FLEN(FLEN), .XLEN(XLEN)) u_cvt (
        .clk          (clk),
        .rst_n        (rst_n),
        .valid_i      (valid_i & sel_cvt),
        .op_i         (op_i[3:0]),
        .rm_i         (rm_i),
        .src_a_i      (src_a_f),
        .int_src_i    (int_src_i),
        .valid_o      (cvt_valid_out),
        .result_o     (cvt_result),
        .int_result_o (cvt_int_result),
        .fflags_o     (cvt_fflags)
    );

    // =========================================================================
    // Result arbitration
    // =========================================================================
    logic [FLEN-1:0] result_mux_raw;

    fpu_result_mux #(.FLEN(FLEN), .XLEN(XLEN)) u_result_mux (
        .fma_valid_i        (fma_valid_out),
        .fma_result_i       (fma_result),
        .fma_fflags_i       (fma_fflags),
        .ncomp_valid_i      (ncomp_valid_out),
        .ncomp_result_i     (ncomp_result),
        .ncomp_int_result_i (ncomp_int_result),
        .ncomp_fflags_i     (ncomp_fflags),
        .div_valid_i        (div_valid_out),
        .div_result_i       (div_result),
        .div_fflags_i       (div_fflags),
        .cvt_valid_i        (cvt_valid_out),
        .cvt_result_i       (cvt_result),
        .cvt_int_result_i   (cvt_int_result),
        .cvt_fflags_i       (cvt_fflags),
        .valid_o            (valid_o),
        .result_o           (result_mux_raw),
        .int_result_o       (int_result_o),
        .fflags_o           (fflags_o)
    );

    // =========================================================================
    // FTZ output flush — subnormal results → ±0 (preserves sign)
    // NaN-box output — FP32 result in FP64 context: upper 32 bits = all 1s
    // Both inactive at default parameters (FTZ=0, FLEN=32)
    // =========================================================================
    logic [FLEN-1:0] result_ftz;
    generate
        if (FTZ) begin : g_ftz_out
            logic sub_out;
            assign sub_out  = (result_mux_raw[FLEN-2 -: EW] == '0) &&
                               (result_mux_raw[MW-1:0] != '0);
            assign result_ftz = sub_out ?
                {result_mux_raw[FLEN-1], {(FLEN-1){1'b0}}} : result_mux_raw;
        end else begin : g_ftz_out
            assign result_ftz = result_mux_raw;
        end
    endgenerate

    generate
        if (FLEN == 64 && NAN_BOX_CHECK) begin : g_box_out
            // FP32 results boxed: upper 32 = 0xFFFFFFFF; FP64 pass-through
            assign result_o = (fmt_i == 2'b00) ?
                {{32{1'b1}}, result_ftz[31:0]} : result_ftz;
        end else begin : g_box_out
            assign result_o = result_ftz;
        end
    endgenerate

    // =========================================================================
    // Formal properties (protocol invariants)
    // =========================================================================
`ifdef FORMAL
    // Force BMC's basecase through an actual reset before anything is
    // checked. The previous `initial f_was_reset = 0;` flop relied on a
    // plain register's `initial` value being honored for its own
    // power-on state, which this Yosys build does not reliably do
    // (confirmed with a minimal repro — see project memory
    // feedback_formal_sby / CLAUDE.md "Formal verification idioms").
    // `initial assume(!rst_n);` is the confirmed-working idiom. (This
    // specific property — ready_o==~busy_o — is a pure combinational
    // tautology and was never actually at risk from the old idiom; fixed
    // anyway so this file matches the rest of the portfolio's house
    // style and doesn't model the anti-pattern for future properties
    // added here that might not be tautologies.)
    initial assume(!rst_n);

    always_comb begin
        // ready_o is always the complement of busy_o
        if (rst_n) begin
            assert(ready_o == ~busy_o);
        end
    end

    always_comb begin
        cover(valid_o);
        cover(valid_o && (op_i[5:4] == 2'b11));
        cover(valid_o && (op_i[5:4] == 2'b00));
        cover(valid_o && (op_i[5:4] == 2'b10));
    end
`endif

endmodule
