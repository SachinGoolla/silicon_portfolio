// =============================================================================
// fpu_round.sv  —  IEEE 754 Rounding and Result Packing
// =============================================================================
//
// After FP arithmetic you have more bits of precision than IEEE 754 stores.
// Three extra bits (Guard, Round, Sticky) track what was lost below the last
// representable bit.  This module decides whether to round up, handles
// over/underflow, and packs the final IEEE 754 word.
//
// GRS bits:
//   G = guard:  bit immediately below the last kept bit
//   R = round:  next bit below G
//   S = sticky: OR of everything below R (any non-zero remainder)
//
// Rounding modes (rm_i):
//   000 RNE  Round to Nearest, ties to Even   (IEEE 754 default)
//   001 RTZ  Round toward Zero  (truncate)
//   010 RDN  Round toward -Inf  (floor)
//   011 RUP  Round toward +Inf  (ceiling)
//   100 RMM  Round to Nearest, ties away from Zero
//
// Interface:
//   sign_i             : sign of the result
//   exp_i  [EW:0]      : biased exponent, EW+1 bits (signed interpretation OK)
//                        values <= 0 → subnormal/zero; values >= 2^EW-1 → overflow
//   mant_i [MW+3:0]    : MW+4 bits: {hidden_bit=1, MW frac bits, G, R, S}
//   is_nan_i           : bypass: return canonical NaN
//   is_inf_i           : bypass: return ±Infinity
//   is_zero_i          : bypass: return ±Zero
//   result_o           : packed IEEE 754 result
//   fflags_o [4:0]     : {NV, DZ, OF, UF, NX}  (NV and DZ never set here)
//
// =============================================================================

module fpu_round #(
    parameter int FLEN = 32,
    localparam int EW   = (FLEN == 64) ? 11 : 8,
    localparam int MW   = FLEN - EW - 1
) (
    input  logic              sign_i,
    input  logic [EW:0]       exp_i,       // biased exponent, EW+1 bits
    input  logic [MW+3:0]     mant_i,      // {hidden, MW frac, G, R, S}
    input  logic [2:0]        rm_i,        // rounding mode
    input  logic              is_nan_i,
    input  logic              is_inf_i,
    input  logic              is_zero_i,

    output logic [FLEN-1:0]   result_o,
    output logic [4:0]        fflags_o     // {NV=0, DZ=0, OF, UF, NX}
);

    // =========================================================================
    // Step 1: Split mant_i into kept bits and GRS.
    //
    // mant_i = { hidden[MW+3], frac[MW+2:3], G[2], R[1], S[0] }
    // mant_work = bits [MW+3:3] = MW+1 bits  (the bits we actually store)
    // =========================================================================
    // Pre-extract as wires so Icarus sees static widths outside always blocks.
    logic [MW:0] mant_work;    // MW+1 bits: [MW]=hidden, [MW-1:0]=fraction
    logic        guard_bit;
    logic        round_bit;
    logic        sticky_bit;

    assign mant_work  = mant_i[MW+3:3];   // constant bounds — OK outside always
    assign guard_bit  = mant_i[2];
    assign round_bit  = mant_i[1];
    assign sticky_bit = mant_i[0];

    logic any_remainder;
    assign any_remainder = guard_bit | round_bit | sticky_bit;

    // =========================================================================
    // Step 2: Rounding decision — should we increment the last kept bit?
    // =========================================================================
    logic round_up;
    always_comb begin
        unique case (rm_i)
            3'b000:  round_up = guard_bit & (round_bit | sticky_bit | mant_work[0]);
            3'b001:  round_up = 1'b0;
            3'b010:  round_up = any_remainder & sign_i;
            3'b011:  round_up = any_remainder & ~sign_i;
            3'b100:  round_up = guard_bit;
            default: round_up = 1'b0;
        endcase
    end

    // =========================================================================
    // Step 3: Apply round_up — add 1 to the least-significant kept bit.
    // The hidden bit is included so overflow carries through.
    // =========================================================================
    logic [MW+1:0] mant_sum;
    assign mant_sum = {1'b0, mant_work} + {{(MW+1){1'b0}}, round_up};

    logic        mant_carry;   // 1 if 1.xxx + 1 = 10.000  (mantissa overflow)
    logic [MW:0] mant_rounded; // MW+1 bits after carry

    assign mant_carry   = mant_sum[MW+1];
    assign mant_rounded = mant_carry ? {1'b1, {MW{1'b0}}} : mant_sum[MW:0];

    // =========================================================================
    // Step 4: Adjust exponent for rounding carry.
    // exp_adj is EW+1 bits; adding a 1-bit carry keeps the width safe.
    // =========================================================================
    logic [EW:0] exp_adj;
    assign exp_adj = exp_i + {{EW{1'b0}}, mant_carry};

    // =========================================================================
    // Step 5: Overflow / underflow detection.
    //
    // exp_adj is the biased exponent AFTER rounding.  Treat as unsigned:
    //   Overflow  : exp_adj >= 2^EW − 1  (all-ones exponent = NaN/Inf in IEEE)
    //   Underflow : exp_adj[EW] set (wrapped around zero) OR exp_adj == 0
    //               (exp = 0 reserved for subnormals in IEEE 754)
    //
    // We detect underflow as exp_adj being 0 or "negative" (bit EW set means
    // the addition of carry wrapped into the sign bit — shouldn't happen in
    // practice, but we guard for it).
    // =========================================================================
    localparam logic [EW:0] EXP_MAX = {1'b0, {EW{1'b1}}};  // all-ones biased exp

    logic is_overflow;
    logic is_underflow;

    // Overflow: biased exponent >= all-ones (only normal → inf path; Inf inputs bypass)
    assign is_overflow  = (exp_adj >= EXP_MAX);

    // Underflow: biased exponent == 0 (result needs subnormal representation)
    // Note: exp_adj < 0 (signed) would mean it wrapped, but since we start from
    // a non-negative biased exponent and add carry, the only sub-normal case is
    // exp_adj == 0 in the current design (exp_i == 0 input from upstream).
    assign is_underflow = (exp_adj == '0);

    // =========================================================================
    // Step 6: Subnormal path.
    //
    // When exp_adj == 0, the result is subnormal: the hidden bit becomes 0 and
    // is shifted into the fraction field.  We right-shift mant_rounded by 1
    // (since a true exponent of 0 means the value is 0.xxx * 2^(-126) for FP32).
    //
    // NOTE: For deeply subnormal results (exp_i was already very negative), the
    // FMA stage should have already handled the alignment shift.  Here we handle
    // only the boundary case where the result just barely underflows.
    //
    // After the 1-bit right-shift:
    //   - new guard = old mant_rounded[0] (the bit we shifted out)
    //   - new sticky = old guard | old round | old sticky
    // =========================================================================
    logic [MW:0]  mant_sub;         // subnormal mantissa after right-shift-by-1
    logic         sub_guard;        // guard bit for subnormal rounding
    logic         sub_sticky;       // sticky bit for subnormal rounding

    assign mant_sub    = {1'b0, mant_rounded[MW:1]};   // right shift by 1, hidden→0
    assign sub_guard   = mant_rounded[0];               // shifted-out bit
    assign sub_sticky  = any_remainder;                 // original GRS

    // Second rounding decision for the subnormal result
    logic sub_round_up;
    always_comb begin
        unique case (rm_i)
            3'b000:  sub_round_up = sub_guard & (sub_sticky | mant_sub[0]);
            3'b001:  sub_round_up = 1'b0;
            3'b010:  sub_round_up = (sub_guard | sub_sticky) & sign_i;
            3'b011:  sub_round_up = (sub_guard | sub_sticky) & ~sign_i;
            3'b100:  sub_round_up = sub_guard;
            default: sub_round_up = 1'b0;
        endcase
    end

    logic [MW:0] mant_sub_final;
    assign mant_sub_final = mant_sub + {{MW{1'b0}}, sub_round_up};

    // If subnormal rounding causes hidden bit to appear (1.0...0),
    // the result is actually the smallest normal number.
    logic sub_became_normal;
    assign sub_became_normal = mant_sub_final[MW];

    logic is_sub_zero;
    assign is_sub_zero = (mant_sub_final == '0);

    // =========================================================================
    // Step 7: Inexact flag (NX) — set if any precision was lost.
    // =========================================================================
    logic is_inexact_normal;
    logic is_inexact_sub;
    assign is_inexact_normal = any_remainder;
    assign is_inexact_sub    = sub_guard | sub_sticky;

    // =========================================================================
    // Step 8: Canonical NaN for this format.
    // =========================================================================
    logic [FLEN-1:0] CANONICAL_NAN;
    generate
        if (FLEN == 64) begin : g_cnan64
            assign CANONICAL_NAN = 64'h7FF8_0000_0000_0000;
        end else begin : g_cnan32
            assign CANONICAL_NAN = 32'h7FC0_0000;
        end
    endgenerate

    // =========================================================================
    // Step 9: Result mux — priority: NaN > Inf > zero/underflow > sub > normal.
    // =========================================================================
    logic [FLEN-1:0] result_inf;
    logic [FLEN-1:0] result_zero;
    logic [FLEN-1:0] result_sub;
    logic [FLEN-1:0] result_norm;

    assign result_inf  = {sign_i, {EW{1'b1}}, {MW{1'b0}}};
    assign result_zero = {sign_i, {(FLEN-1){1'b0}}};
    assign result_sub  = sub_became_normal
                       ? {sign_i, {{EW-1{1'b0}}, 1'b1}, mant_sub_final[MW-1:0]}
                       : {sign_i, {EW{1'b0}},           mant_sub_final[MW-1:0]};
    assign result_norm = {sign_i, exp_adj[EW-1:0], mant_rounded[MW-1:0]};

    always_comb begin
        if (is_nan_i) begin
            result_o = CANONICAL_NAN;
            fflags_o = 5'b0;          // NV is upstream's responsibility
        end else if (is_inf_i) begin
            result_o = result_inf;
            fflags_o = 5'b0;
        end else if (is_zero_i) begin
            result_o = result_zero;
            fflags_o = 5'b0;
        end else if (is_overflow) begin
            result_o = result_inf;
            fflags_o = 5'b00101;          // OF + NX on overflow
        end else if (is_underflow && is_sub_zero) begin
            result_o = result_zero;
            fflags_o = 5'b00011;      // UF + NX
        end else if (is_underflow) begin
            result_o = result_sub;
            fflags_o = {3'b0, is_inexact_sub, is_inexact_sub}; // UF + NX if inexact
        end else begin
            result_o = result_norm;
            fflags_o = {4'b0, is_inexact_normal};
        end
    end

    // =========================================================================
    // Formal properties
    // =========================================================================
`ifdef FORMAL
    always_comb begin
        if (is_nan_i)
            assert(result_o == CANONICAL_NAN);
        if (is_inf_i && !is_nan_i)
            assert(result_o == result_inf);
        if (is_zero_i && !is_nan_i && !is_inf_i)
            assert(result_o == result_zero);
        // NV and DZ are never set by this module
        assert(fflags_o[4] == 1'b0);
        assert(fflags_o[3] == 1'b0);
    end
`endif

endmodule
