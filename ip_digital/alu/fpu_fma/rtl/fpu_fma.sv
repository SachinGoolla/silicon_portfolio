// =============================================================================
// fpu_fma.sv  —  Fused Multiply-Add Pipeline  (4 stages)
// =============================================================================
//
// Computes:  result = (A × B) + C,  with sign adjustments for each op:
//
//   FADD   A + B           →  is_add_op=1  (product = A, C = B)
//   FSUB   A − B           →  is_add_op=1, negate_c=1
//   FMUL   A × B           →  is_mul_op=1  (C forced to +0)
//   FMADD  +(A×B) + C      →  negate_p=0, negate_c=0
//   FMSUB  +(A×B) − C      →  negate_p=0, negate_c=1
//   FNMADD −(A×B) − C      →  negate_p=1, negate_c=1
//   FNMSUB −(A×B) + C      →  negate_p=1, negate_c=0
//
// 4-stage pipeline:
//   EX1: Decode, unpack, classify, start multiply
//   EX2: Multiply lands, align operands to same exponent
//   EX3: Signed add, leading-zero detect
//   EX4: Normalize, round (via fpu_round), pack output
//
// =============================================================================

module fpu_fma #(
    parameter int FLEN = 32,
    localparam int EW   = (FLEN == 64) ? 11 : 8,
    localparam int MW   = FLEN - EW - 1,
    /* verilator lint_off UNUSEDPARAM */
    localparam int BIAS = (FLEN == 64) ? 1023 : 127
    /* verilator lint_on UNUSEDPARAM */
) (
    input  logic              clk,
    input  logic              rst_n,

    input  logic              valid_i,
    input  logic [3:0]        op_i,     // sub-opcode within FMA unit
    input  logic [2:0]        rm_i,     // rounding mode
    input  logic [FLEN-1:0]   src_a_i,
    input  logic [FLEN-1:0]   src_b_i,
    input  logic [FLEN-1:0]   src_c_i,  // 0 for FMUL; src_b for FADD/FSUB

    output logic              valid_o,
    output logic [FLEN-1:0]   result_o,
    output logic [4:0]        fflags_o
);

    // op sub-codes within the FMA unit
    localparam logic [3:0] OP_FADD   = 4'b0000;
    localparam logic [3:0] OP_FSUB   = 4'b0001;
    localparam logic [3:0] OP_FMUL   = 4'b0010;
    /* verilator lint_off UNUSEDPARAM */
    localparam logic [3:0] OP_FMADD  = 4'b0011;
    localparam logic [3:0] OP_FMSUB  = 4'b0100;
    localparam logic [3:0] OP_FNMADD = 4'b0101;
    localparam logic [3:0] OP_FNMSUB = 4'b0110;
    /* verilator lint_on UNUSEDPARAM */

    // Bias as EW+3 bit wire — generated per-format to get the exact literal width.
    // FP32: EW+3=11 bits; FP64: EW+3=14 bits.  Avoids parameterized casts.
    logic [EW+2:0] BIAS_VAL;
    generate
        if (FLEN == 64) begin : g_bias64
            assign BIAS_VAL = {3'b0, 11'd1023};   // 14 bits for FP64
        end else begin : g_bias32
            assign BIAS_VAL = {3'b0,  8'd127};    // 11 bits for FP32
        end
    endgenerate

    // Product mantissa width: (MW+1) × (MW+1) → 2*(MW+1) bits
    localparam int PMANT_W = 2 * (MW + 1);

    // Extended mantissa: MW+1 fraction bits + 3 GRS bits = MW+4 bits
    localparam int EMANT_W = MW + 4;

    // Canonical NaN for this format
    logic [FLEN-1:0] CANONICAL_NAN;
    generate
        if (FLEN == 64) begin : g_cnan64
            assign CANONICAL_NAN = 64'h7FF8_0000_0000_0000;
        end else begin : g_cnan32
            assign CANONICAL_NAN = 32'h7FC0_0000;
        end
    endgenerate

    // =========================================================================
    // Utility: unpack one FP operand into sign / biased-exp / mantissa-with-hidden.
    // The hidden bit is 1 for normal numbers, 0 for subnormals.
    // For subnormals, we adjust the effective exponent to 1 (not 0) so that
    // subsequent arithmetic sees a consistent representation.
    //
    // We output:
    //   sign  [0]         : sign bit
    //   exp   [EW:0]      : EW+1 bits, biased exponent (subnormal → 1)
    //   mant  [MW:0]      : MW+1 bits, {hidden_bit, fraction}
    //   flags [3:0]       : {is_zero, is_inf, is_nan, is_snan}
    // =========================================================================

    // Helper: one unpacker per operand — macro-style via task-less design
    // We just inline three copies (A, B, C) since tasks can't return signals.

    // ── Unpack A ─────────────────────────────────────────────────────────────
    logic              s1_sign_a;
    logic [EW:0]       s1_exp_a;      // EW+1 bits
    logic [MW:0]       s1_mant_a;     // MW+1 bits (with hidden)
    logic              s1_a_is_zero, s1_a_is_inf, s1_a_is_nan, s1_a_is_snan;
    logic [EW-1:0]     s1_exp_a_raw;
    logic [MW-1:0]     s1_mant_a_raw;

    assign s1_sign_a     = src_a_i[FLEN-1];
    assign s1_exp_a_raw  = src_a_i[FLEN-2 -: EW];
    assign s1_mant_a_raw = src_a_i[MW-1   -: MW];

    assign s1_a_is_zero  =  (s1_exp_a_raw == '0) &  (s1_mant_a_raw == '0);
    assign s1_a_is_inf   =  (s1_exp_a_raw == '1) &  (s1_mant_a_raw == '0);
    assign s1_a_is_nan   =  (s1_exp_a_raw == '1) & ~(s1_mant_a_raw == '0);
    assign s1_a_is_snan  =  s1_a_is_nan & ~s1_mant_a_raw[MW-1];

    // Subnormal: hidden=0, effective biased exp = 1
    assign s1_mant_a = {~(s1_exp_a_raw == '0), s1_mant_a_raw};
    assign s1_exp_a  = {1'b0, (s1_exp_a_raw == '0) ? EW'(1) : s1_exp_a_raw};

    // ── Unpack B ─────────────────────────────────────────────────────────────
    logic              s1_sign_b;
    logic [EW:0]       s1_exp_b;
    logic [MW:0]       s1_mant_b;
    logic              s1_b_is_zero, s1_b_is_inf, s1_b_is_nan, s1_b_is_snan;
    logic [EW-1:0]     s1_exp_b_raw;
    logic [MW-1:0]     s1_mant_b_raw;

    assign s1_sign_b     = src_b_i[FLEN-1];
    assign s1_exp_b_raw  = src_b_i[FLEN-2 -: EW];
    assign s1_mant_b_raw = src_b_i[MW-1   -: MW];

    assign s1_b_is_zero  =  (s1_exp_b_raw == '0) &  (s1_mant_b_raw == '0);
    assign s1_b_is_inf   =  (s1_exp_b_raw == '1) &  (s1_mant_b_raw == '0);
    assign s1_b_is_nan   =  (s1_exp_b_raw == '1) & ~(s1_mant_b_raw == '0);
    assign s1_b_is_snan  =  s1_b_is_nan & ~s1_mant_b_raw[MW-1];

    assign s1_mant_b = {~(s1_exp_b_raw == '0), s1_mant_b_raw};
    assign s1_exp_b  = {1'b0, (s1_exp_b_raw == '0) ? EW'(1) : s1_exp_b_raw};

    // ── Decode op → control signals ──────────────────────────────────────────
    logic s1_is_add_op;    // FADD/FSUB: product = A (no multiply)
    logic s1_is_mul_op;    // FMUL: C = +0
    logic s1_negate_prod;  // flip sign of product (FNMADD, FNMSUB)
    logic s1_negate_c;     // flip sign of C (FSUB, FMSUB, FNMADD)

    assign s1_is_add_op   = (op_i == OP_FADD) | (op_i == OP_FSUB);
    assign s1_is_mul_op   = (op_i == OP_FMUL);
    assign s1_negate_prod = (op_i == OP_FNMADD) | (op_i == OP_FNMSUB);
    assign s1_negate_c    = (op_i == OP_FSUB)   | (op_i == OP_FMSUB) | (op_i == OP_FNMADD);

    // ── Unpack C (or B for FADD/FSUB, or +0 for FMUL) ───────────────────────
    logic [FLEN-1:0]  s1_c_word;
    assign s1_c_word = s1_is_add_op ? src_b_i :
                       s1_is_mul_op ? '0       : src_c_i;

    logic              s1_sign_c_raw, s1_sign_c;
    logic [EW:0]       s1_exp_c;
    logic [MW:0]       s1_mant_c;
    logic              s1_c_is_zero, s1_c_is_inf, s1_c_is_nan, s1_c_is_snan;
    logic [EW-1:0]     s1_exp_c_raw;
    logic [MW-1:0]     s1_mant_c_raw;

    assign s1_sign_c_raw = s1_c_word[FLEN-1];
    assign s1_exp_c_raw  = s1_c_word[FLEN-2 -: EW];
    assign s1_mant_c_raw = s1_c_word[MW-1   -: MW];

    assign s1_c_is_zero  =  (s1_exp_c_raw == '0) &  (s1_mant_c_raw == '0);
    assign s1_c_is_inf   =  (s1_exp_c_raw == '1) &  (s1_mant_c_raw == '0);
    assign s1_c_is_nan   =  (s1_exp_c_raw == '1) & ~(s1_mant_c_raw == '0);
    assign s1_c_is_snan  =  s1_c_is_nan & ~s1_mant_c_raw[MW-1];

    assign s1_mant_c = {~(s1_exp_c_raw == '0), s1_mant_c_raw};
    assign s1_exp_c  = {1'b0, (s1_exp_c_raw == '0) ? EW'(1) : s1_exp_c_raw};
    assign s1_sign_c = s1_sign_c_raw ^ s1_negate_c;

    // ── Product sign ─────────────────────────────────────────────────────────
    logic s1_sign_prod;
    // FADD/FSUB: product = A only (no multiply), so B's sign is not part of product sign.
    assign s1_sign_prod = s1_is_add_op
                        ? (s1_sign_a ^ s1_negate_prod)
                        : (s1_sign_a ^ s1_sign_b ^ s1_negate_prod);

    // ── Special-case detection ───────────────────────────────────────────────
    //
    // Priority: sNaN > qNaN > Inf×0 > Inf−Inf > Inf > 0 > normal
    logic s1_any_snan, s1_any_nan;
    logic s1_inf_times_zero;  // Inf × 0 = invalid
    logic s1_inf_sub_inf;     // ∞ + (−∞) = invalid (product and C have opposite signs)
    logic s1_prod_would_be_inf;   // A (or A×B) is infinite
    logic s1_prod_would_be_zero;  // product is 0

    assign s1_any_snan = s1_a_is_snan
                       | (~s1_is_add_op & s1_b_is_snan)
                       | s1_c_is_snan;
    assign s1_any_nan  = s1_a_is_nan
                       | (~s1_is_add_op & s1_b_is_nan)
                       | s1_c_is_nan;

    assign s1_prod_would_be_inf  = s1_a_is_inf | (~s1_is_add_op & s1_b_is_inf);
    assign s1_prod_would_be_zero = s1_a_is_zero | (~s1_is_add_op & s1_b_is_zero);

    // Inf × 0: one of A, B is Inf and the other is 0 (for multiply path only)
    assign s1_inf_times_zero = ~s1_is_add_op
                             & ((s1_a_is_inf & s1_b_is_zero) | (s1_a_is_zero & s1_b_is_inf));

    // ∞ + (−∞): only when product is Inf AND C is Inf with opposite sign
    assign s1_inf_sub_inf = s1_prod_would_be_inf & s1_c_is_inf
                          & (s1_sign_prod != s1_sign_c);

    // Final special-case outputs for this operation
    logic s1_result_is_nan, s1_result_is_inf, s1_result_is_zero;
    logic s1_set_nv;
    logic s1_inf_sign, s1_zero_sign;

    assign s1_result_is_nan  = s1_any_nan | s1_inf_times_zero | s1_inf_sub_inf;
    assign s1_set_nv         = s1_any_snan | s1_inf_times_zero | s1_inf_sub_inf;
    assign s1_result_is_inf  = ~s1_result_is_nan
                             & (s1_prod_would_be_inf | s1_c_is_inf);
    assign s1_inf_sign       = s1_prod_would_be_inf ? s1_sign_prod : s1_sign_c;
    assign s1_result_is_zero = ~s1_result_is_nan & ~s1_result_is_inf
                             & s1_prod_would_be_zero & s1_c_is_zero;
    assign s1_zero_sign      = s1_sign_prod & s1_sign_c;  // −0+−0 = −0

    // ── Product exponent ─────────────────────────────────────────────────────
    // exp_prod = exp_a + exp_b - BIAS  (for multiply path)
    // exp_prod = exp_a                  (for FADD/FSUB: product = A)
    // Use EW+3 bits (signed) to safely hold the full range.
    logic signed [EW+2:0] s1_exp_prod;

    always_comb begin
        if (s1_is_add_op) begin
            s1_exp_prod = $signed({3'b0, s1_exp_a[EW-1:0]});
        end else begin
            // exp_a + exp_b - BIAS; all values are EW+1 bits (unsigned)
            s1_exp_prod = $signed({3'b0, s1_exp_a[EW-1:0]})
                        + $signed({3'b0, s1_exp_b[EW-1:0]})
                        - $signed(BIAS_VAL);
        end
    end

    // ── Mantissa multiplication ───────────────────────────────────────────────
    // FADD/FSUB: product mantissa = mant_a, placed in the upper half (no multiply)
    // Others:    (MW+1) × (MW+1) → PMANT_W bits
    logic [PMANT_W-1:0] s1_prod_mant;

    always_comb begin
        if (s1_is_add_op) begin
            // For FADD/FSUB: product = A (no multiply).
            // Place mant_a with a leading 0 so it sits at bit PMANT_W-2, NOT PMANT_W-1.
            // This makes s2_prod_overflow = 0 and prevents a spurious +1 on the exponent.
            // Format: {0, mant_a[MW:0], MW zeros} = PMANT_W bits
            s1_prod_mant = {1'b0, s1_mant_a, {MW{1'b0}}};
        end else begin
            s1_prod_mant = s1_mant_a * s1_mant_b;
        end
    end

    // ── EX1 → EX2 pipeline register ──────────────────────────────────────────
    logic                 r1_valid;
    logic [2:0]           r1_rm;
    logic                 r1_sign_prod, r1_sign_c;
    logic signed [EW+2:0] r1_exp_prod;
    logic [EW:0]          r1_exp_c;
    logic [PMANT_W-1:0]   r1_prod_mant;
    logic [MW:0]          r1_mant_c;
    logic                 r1_result_is_nan, r1_result_is_inf, r1_result_is_zero;
    logic                 r1_set_nv, r1_inf_sign, r1_zero_sign;
    logic                 r1_is_add_op;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            r1_valid          <= 1'b0;
            r1_rm             <= 3'b0;
            r1_sign_prod      <= 1'b0;
            r1_sign_c         <= 1'b0;
            r1_exp_prod       <= '0;
            r1_exp_c          <= '0;
            r1_prod_mant      <= '0;
            r1_mant_c         <= '0;
            r1_result_is_nan  <= 1'b0;
            r1_result_is_inf  <= 1'b0;
            r1_result_is_zero <= 1'b0;
            r1_set_nv         <= 1'b0;
            r1_inf_sign       <= 1'b0;
            r1_zero_sign      <= 1'b0;
            r1_is_add_op      <= 1'b0;
        end else begin
            r1_valid          <= valid_i;
            r1_rm             <= rm_i;
            r1_sign_prod      <= s1_sign_prod;
            r1_sign_c         <= s1_sign_c;
            r1_exp_prod       <= s1_exp_prod;
            r1_exp_c          <= s1_exp_c;
            r1_prod_mant      <= s1_prod_mant;
            r1_mant_c         <= s1_mant_c;
            r1_result_is_nan  <= s1_result_is_nan;
            r1_result_is_inf  <= s1_result_is_inf;
            r1_result_is_zero <= s1_result_is_zero;
            r1_set_nv         <= s1_set_nv;
            r1_inf_sign       <= s1_inf_sign;
            r1_zero_sign      <= s1_zero_sign;
            r1_is_add_op      <= s1_is_add_op;
        end
    end

    // =========================================================================
    // EX2: Multiply result, normalize product MSB, align C
    // =========================================================================
    //
    // After 1.xxx × 1.xxx, the product can be in [1.0, 4.0):
    //   01.xxx... format (MSB=0) → true exponent = exp_prod
    //   1x.xxx... format (MSB=1) → true exponent = exp_prod + 1
    //
    // We normalize to 1.xxx by checking the MSB and adjusting.
    // Then we align the smaller-exponent operand by right-shifting.

    // Normalize product MSB
    logic s2_prod_overflow;
    assign s2_prod_overflow = r1_prod_mant[PMANT_W-1];

    logic signed [EW+2:0] s2_exp_prod_norm;
    assign s2_exp_prod_norm = r1_exp_prod + $signed({{EW+2{1'b0}}, s2_prod_overflow});

    // Extended product mantissa: EMANT_W = MW+4 bits = {hidden, MW frac, G, R, S}
    // Take the top EMANT_W bits of the normalized product, accumulate sticky below.
    // prod_mant is PMANT_W = 2*(MW+1) bits.
    // Normalized top bit is at PMANT_W-1 if overflow, PMANT_W-2 if not.
    logic [EMANT_W-1:0] s2_prod_emant;
    logic               s2_prod_sticky_extra;

    always_comb begin
        if (s2_prod_overflow) begin
            // Take bits [PMANT_W-1 : PMANT_W-EMANT_W]
            s2_prod_emant       = r1_prod_mant[PMANT_W-1 -: EMANT_W];
            // Sticky = OR of remaining bits below
            s2_prod_sticky_extra = |(r1_prod_mant[PMANT_W-1-EMANT_W:0]);
        end else begin
            // Take bits [PMANT_W-2 : PMANT_W-1-EMANT_W]
            s2_prod_emant       = r1_prod_mant[PMANT_W-2 -: EMANT_W];
            s2_prod_sticky_extra = |(r1_prod_mant[PMANT_W-2-EMANT_W:0]);
        end
    end

    // C extended mantissa: EMANT_W bits = {hidden, MW frac, 3'b0}
    // (r1_mant_c is MW+1 bits; place the 3 GRS bits as 0 below it)
    logic [EMANT_W-1:0] s2_c_emant_unshifted;
    assign s2_c_emant_unshifted = {r1_mant_c, 3'b000};  // MW+1 + 3 = EMANT_W ✓

    // Alignment:
    //   delta = exp_prod_norm - exp_c
    //   delta > 0: product has larger exp → right-shift C by delta
    //   delta < 0: C has larger exp → right-shift product by |delta|
    //
    // We pre-compute both shifted versions as wires and select in the register.
    // Sticky via reconstruction trick: v_sticky = (v != (v >> n) << n)
    logic signed [EW+2:0] s2_delta;
    assign s2_delta = s2_exp_prod_norm - $signed({2'b0, r1_exp_c[EW-1:0]});

    logic s2_c_needs_shift;    // 1 = shift C right; 0 = shift product right
    assign s2_c_needs_shift = ~s2_delta[EW+2];  // MSB = sign; 0 = non-negative

    // Absolute delta: -s2_delta gives the positive version when delta is negative
    logic signed [EW+2:0] s2_neg_delta;
    assign s2_neg_delta = -s2_delta;

    // Shift amounts (unsigned, 7 bits handles up to 127 which exceeds EMANT_W)
    logic [6:0] s2_shift_c, s2_shift_prod;
    assign s2_shift_c    = s2_c_needs_shift ? s2_delta[6:0]     : 7'b0;
    assign s2_shift_prod = s2_c_needs_shift ? 7'b0 : s2_neg_delta[6:0];

    // Shifted versions
    logic [EMANT_W-1:0] s2_c_shifted, s2_prod_shifted;
    assign s2_c_shifted    = s2_c_emant_unshifted >> s2_shift_c;
    assign s2_prod_shifted = s2_prod_emant        >> s2_shift_prod;

    // Sticky using reconstruction: if (v >> n) << n != v, bits were lost
    logic [EMANT_W-1:0] s2_c_reconstruct, s2_prod_reconstruct;
    assign s2_c_reconstruct    = s2_c_shifted    << s2_shift_c;
    assign s2_prod_reconstruct = s2_prod_shifted << s2_shift_prod;

    logic s2_c_sticky, s2_prod_sticky;
    assign s2_c_sticky    = (s2_c_emant_unshifted != s2_c_reconstruct);
    assign s2_prod_sticky = (s2_prod_emant != s2_prod_reconstruct) | s2_prod_sticky_extra;

    // Result exponent = the larger of the two (both EW+3 bits signed)
    logic signed [EW+2:0] s2_exp_result;
    assign s2_exp_result = s2_c_needs_shift ? s2_exp_prod_norm
                                            : $signed({3'b0, r1_exp_c[EW-1:0]});

    // Final aligned mantissas
    logic [EMANT_W-1:0] s2_prod_emant_aligned, s2_c_emant_aligned;
    assign s2_prod_emant_aligned = s2_c_needs_shift ? s2_prod_emant   : s2_prod_shifted;
    assign s2_c_emant_aligned    = s2_c_needs_shift ? s2_c_shifted    : s2_c_emant_unshifted;

    // EX2 → EX3 pipeline register
    logic                 r2_valid;
    logic [2:0]           r2_rm;
    logic                 r2_sign_prod, r2_sign_c;
    logic signed [EW+2:0] r2_exp_result;
    logic [EMANT_W-1:0]   r2_prod_emant, r2_c_emant;
    logic                 r2_prod_sticky, r2_c_sticky;
    logic                 r2_result_is_nan, r2_result_is_inf, r2_result_is_zero;
    logic                 r2_set_nv, r2_inf_sign, r2_zero_sign;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            r2_valid          <= 1'b0;
            r2_rm             <= 3'b0;
            r2_sign_prod      <= 1'b0;
            r2_sign_c         <= 1'b0;
            r2_exp_result     <= '0;
            r2_prod_emant     <= '0;
            r2_c_emant        <= '0;
            r2_prod_sticky    <= 1'b0;
            r2_c_sticky       <= 1'b0;
            r2_result_is_nan  <= 1'b0;
            r2_result_is_inf  <= 1'b0;
            r2_result_is_zero <= 1'b0;
            r2_set_nv         <= 1'b0;
            r2_inf_sign       <= 1'b0;
            r2_zero_sign      <= 1'b0;
        end else begin
            r2_valid          <= r1_valid;
            r2_rm             <= r1_rm;
            r2_sign_prod      <= r1_sign_prod;
            r2_sign_c         <= r1_sign_c;
            r2_exp_result     <= s2_exp_result;
            r2_prod_emant     <= s2_prod_emant_aligned;
            r2_c_emant        <= s2_c_emant_aligned;
            r2_prod_sticky    <= s2_prod_sticky;
            r2_c_sticky       <= s2_c_sticky;
            r2_result_is_nan  <= r1_result_is_nan;
            r2_result_is_inf  <= r1_result_is_inf;
            r2_result_is_zero <= r1_result_is_zero;
            r2_set_nv         <= r1_set_nv;
            r2_inf_sign       <= r1_inf_sign;
            r2_zero_sign      <= r1_zero_sign;
        end
    end

    // =========================================================================
    // EX3: Signed add and leading-zero detect
    // =========================================================================
    //
    // Both r2_prod_emant and r2_c_emant are EMANT_W-bit magnitudes.
    // We convert to two's-complement (signed), add, then extract sign+magnitude.
    //
    // Result can be up to EMANT_W+1 bits (carry out of the top).
    //
    // Leading-zero count on the EMANT_W+1 bit magnitude determines how
    // many left-shifts are needed to normalize (get a 1.xxx format).

    // Use unsigned magnitude-based add/subtract to avoid signed overflow.
    // Same sign → add magnitudes (can produce EMANT_W+1 bits, fits in MAGW).
    // Diff sign → subtract smaller from larger (always fits in EMANT_W bits ≤ MAGW).
    logic [EMANT_W:0]  s3_abs_prod, s3_abs_c;
    assign s3_abs_prod = {1'b0, r2_prod_emant};
    assign s3_abs_c    = {1'b0, r2_c_emant};

    // Combined sticky: lower LSBs from each operand
    logic s3_sticky;
    assign s3_sticky = r2_prod_sticky | r2_c_sticky;

    // Sign and magnitude of the sum
    logic              s3_sign;
    logic [EMANT_W:0]  s3_mag;   // EMANT_W+1 = MAGW bits
    always_comb begin
        if (r2_sign_prod == r2_sign_c) begin
            s3_sign = r2_sign_prod;
            s3_mag  = s3_abs_prod + s3_abs_c;
        end else if (s3_abs_prod >= s3_abs_c) begin
            s3_sign = r2_sign_prod;
            s3_mag  = s3_abs_prod - s3_abs_c;
        end else begin
            s3_sign = r2_sign_c;
            s3_mag  = s3_abs_c - s3_abs_prod;
        end
    end

    logic s3_is_zero;
    assign s3_is_zero = (s3_mag == '0);

    // Leading-zero count on s3_mag (EMANT_W+1 bits)
    // We use a behavioral for-loop; synthesis converts this to a priority encoder tree.
    localparam int MAGW = EMANT_W + 1;   // width of s3_mag
    localparam int LZDW = $clog2(MAGW) + 1;  // enough bits for 0..MAGW

    logic [LZDW-1:0] s3_lzd;
    always_comb begin
        s3_lzd = LZDW'(MAGW);    // default: all zeros (return max count)
        for (int i = 0; i < MAGW; i++) begin
            if (s3_mag[i]) s3_lzd = LZDW'(MAGW - 1 - i);
        end
    end

    // EX3 → EX4 pipeline register
    logic                 r3_valid;
    logic [2:0]           r3_rm;
    logic                 r3_sign;
    logic signed [EW+2:0] r3_exp_result;
    logic [MAGW-1:0]      r3_mag;
    logic                 r3_sticky;
    logic [LZDW-1:0]      r3_lzd;
    logic                 r3_is_zero;
    logic                 r3_result_is_nan, r3_result_is_inf, r3_result_is_zero;
    logic                 r3_set_nv, r3_inf_sign, r3_zero_sign;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            r3_valid          <= 1'b0;
            r3_rm             <= 3'b0;
            r3_sign           <= 1'b0;
            r3_exp_result     <= '0;
            r3_mag            <= '0;
            r3_sticky         <= 1'b0;
            r3_lzd            <= '0;
            r3_is_zero        <= 1'b0;
            r3_result_is_nan  <= 1'b0;
            r3_result_is_inf  <= 1'b0;
            r3_result_is_zero <= 1'b0;
            r3_set_nv         <= 1'b0;
            r3_inf_sign       <= 1'b0;
            r3_zero_sign      <= 1'b0;
        end else begin
            r3_valid          <= r2_valid;
            r3_rm             <= r2_rm;
            r3_sign           <= s3_sign;
            r3_exp_result     <= r2_exp_result;
            r3_mag            <= s3_mag;
            r3_sticky         <= s3_sticky;
            r3_lzd            <= s3_lzd;
            r3_is_zero        <= s3_is_zero;
            r3_result_is_nan  <= r2_result_is_nan;
            r3_result_is_inf  <= r2_result_is_inf;
            r3_result_is_zero <= r2_result_is_zero | s3_is_zero;
            r3_set_nv         <= r2_set_nv;
            r3_inf_sign       <= r2_inf_sign;
            r3_zero_sign      <= r2_zero_sign | (s3_is_zero & r2_sign_prod & r2_sign_c);
        end
    end

    // =========================================================================
    // EX4: Normalize, round, pack
    // =========================================================================
    //
    // Left-shift r3_mag by r3_lzd positions to get 1.xxx format.
    // Adjust exponent: exp_norm = r3_exp_result - r3_lzd + 1
    //   The +1 corrects for the fact that exp_result was set at the
    //   "integer bit = position MAGW-1" level, but after normalization
    //   the integer bit moves to the hidden-bit position.
    //
    // We double-width the shift so no bits are lost:
    //   {r3_mag, zeros} << r3_lzd  → top MW+4 bits → fpu_round

    localparam int SMAGW = 2 * MAGW;   // double-width for safe shift
    logic [SMAGW-1:0] s4_shifted;
    assign s4_shifted = {r3_mag, {MAGW{1'b0}}} << r3_lzd;

    // Take the top EMANT_W = MW+4 bits as the mantissa for rounding
    logic [EMANT_W-1:0] s4_mant_rnd;
    assign s4_mant_rnd = s4_shifted[SMAGW-1 -: EMANT_W];

    // Sticky from bits below the kept portion, PLUS any accumulated sticky
    // The kept portion occupies s4_shifted[SMAGW-1 : SMAGW-EMANT_W]
    // Below = s4_shifted[SMAGW-EMANT_W-1 : 0]
    logic s4_sticky_below;
    assign s4_sticky_below = |(s4_shifted[SMAGW-EMANT_W-1:0]);

    // Incorporate into S bit (bit 0) of mant_rnd
    logic [EMANT_W-1:0] s4_mant_final;
    assign s4_mant_final = {s4_mant_rnd[EMANT_W-1:1],
                            s4_mant_rnd[0] | s4_sticky_below | r3_sticky};

    // Final exponent: subtract lzd, add 1 for hidden-bit correction.
    // Zero-extend r3_lzd to EW+3 bits before signed arithmetic.
    logic signed [EW+2:0] s4_exp_norm;
    logic [EW+2:0] s4_lzd_ext;
    assign s4_lzd_ext  = {{(EW+3-LZDW){1'b0}}, r3_lzd};
    assign s4_exp_norm = r3_exp_result
                       - $signed(s4_lzd_ext)
                       + $signed({{EW+2{1'b0}}, 1'b1});

    // Sign and special-case flags for fpu_round
    logic s4_sign;
    assign s4_sign = r3_result_is_inf  ? r3_inf_sign  :
                     r3_result_is_zero ? r3_zero_sign : r3_sign;

    // Instantiate rounding module
    logic [FLEN-1:0] s4_result;
    logic [4:0]      s4_flags;

    fpu_round #(.FLEN(FLEN)) u_round (
        .sign_i      (s4_sign),
        .exp_i       (s4_exp_norm[EW:0]),    // take lower EW+1 bits
        .mant_i      (s4_mant_final),
        .rm_i        (r3_rm),
        .is_nan_i    (r3_result_is_nan),
        .is_inf_i    (r3_result_is_inf),
        .is_zero_i   (r3_result_is_zero),
        .result_o    (s4_result),
        .fflags_o    (s4_flags)
    );

    // Stage 4 output register
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            valid_o  <= 1'b0;
            result_o <= '0;
            fflags_o <= 5'b0;
        end else begin
            valid_o  <= r3_valid;
            result_o <= s4_result;
            // NV from upstream special-case detection OR from rounding
            fflags_o <= {(r3_set_nv | s4_flags[4]), s4_flags[3:0]};
        end
    end

    // =========================================================================
    // Suppress unused signals
    // =========================================================================
    /* verilator lint_off UNUSEDSIGNAL */
    logic _unused;
    assign _unused = ^CANONICAL_NAN ^ r1_is_add_op ^ r3_is_zero
                   ^ s4_exp_norm[EW+2] ^ s4_exp_norm[EW+1]
                   ^ s1_exp_a[EW] ^ s1_exp_b[EW]
                   ^ s2_neg_delta[EW+2] ^ s2_neg_delta[EW+1]
                   ^ s2_neg_delta[EW]   ^ s2_neg_delta[EW-1]
                   ^ r1_exp_c[EW];
    /* verilator lint_on UNUSEDSIGNAL */

    // =========================================================================
    // Formal: basic sanity properties
    // =========================================================================
`ifdef FORMAL
    logic f_past_reset;
    initial f_past_reset = 0;
    always_ff @(posedge clk or negedge rst_n)
        if (!rst_n) f_past_reset <= 1'b1;

    always_comb begin
        if (f_past_reset) begin
            if (!valid_o) assert(fflags_o == 5'b0);
        end
    end
    always_comb begin
        cover(valid_o);
        cover(valid_o && fflags_o[0]);  // NX reachable
        cover(valid_o && fflags_o[4]);  // NV reachable
    end
`endif

endmodule
