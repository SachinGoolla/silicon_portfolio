// =============================================================================
// fpu_noncomp.sv  —  FPU Non-Computing Operations
// =============================================================================
//
// ── WHAT IS THIS? ────────────────────────────────────────────────────────────
//   These are FPU operations that DON'T need IEEE 754 rounding or any real
//   arithmetic.  They just look at or rearrange the bits of FP numbers.
//   Because of this, they are SINGLE CYCLE — result ready on the next clock.
//
// ── OPERATIONS COVERED ───────────────────────────────────────────────────────
//
//   ┌─────────┬──────────────────────────────────────────────────────────────┐
//   │ Op      │ What it does                                                 │
//   ├─────────┼──────────────────────────────────────────────────────────────┤
//   │ FCLASS  │ "What kind of FP number is this?"                            │
//   │         │ Returns a 10-bit one-hot integer describing the type         │
//   ├─────────┼──────────────────────────────────────────────────────────────┤
//   │ FSGNJ   │ Copy the SIGN from src_b to src_a (keep src_a's magnitude)  │
//   │ FSGNJN  │ Copy the NEGATED sign from src_b to src_a                   │
//   │ FSGNJX  │ XOR the signs of src_a and src_b, apply to src_a            │
//   │         │ Used for: abs(x) = FSGNJ(x, +0.0), neg(x) = FSGNJN(x, x)  │
//   ├─────────┼──────────────────────────────────────────────────────────────┤
//   │ FEQ     │ 1 if A == B, else 0  (sets NV only for sNaN inputs)         │
//   │ FLT     │ 1 if A <  B, else 0  (sets NV for any NaN input)            │
//   │ FLE     │ 1 if A <= B, else 0  (sets NV for any NaN input)            │
//   ├─────────┼──────────────────────────────────────────────────────────────┤
//   │ FMIN    │ min(A, B) — if one input is NaN, returns the OTHER one       │
//   │ FMAX    │ max(A, B) — same NaN rule                                    │
//   └─────────┴──────────────────────────────────────────────────────────────┘
//
// ── KEY IEEE 754 RULES IMPLEMENTED HERE ──────────────────────────────────────
//
//   1. NaN comparison: comparing with NaN always returns FALSE (for FLT/FLE)
//      or 0 (for FEQ), EXCEPT sNaN inputs also set the NV (invalid) flag.
//      FEQ is "quiet" — it does NOT set NV for quiet NaN inputs.
//      FLT and FLE ARE NOT quiet — any NaN sets NV.
//
//   2. Signed zero: −0.0 and +0.0 are EQUAL (FEQ returns 1).
//      But for FMIN: FMIN(−0, +0) = −0  (negative zero is "more negative")
//          for FMAX: FMAX(−0, +0) = +0
//
//   3. NaN propagation in FMIN/FMAX (IEEE 754-2019 minNum rules):
//      If ONE input is NaN → return the OTHER (non-NaN) input.
//      If BOTH are NaN → return the canonical quiet NaN (0x7FC00000 for FP32).
//      This is different from max(NaN, x) = NaN in many programming languages!
//
//   4. Canonical NaN: RISC-V defines a single "canonical" NaN bit pattern:
//      FP32: 0x7FC00000  (positive quiet NaN with mantissa bit 22 set)
//      FP64: 0x7FF8000000000000
//
// ── LATENCY ──────────────────────────────────────────────────────────────────
//   All operations are combinational inside but the result is REGISTERED.
//   → 1 clock cycle from valid_i to valid_o.
//
// ── OPCODE ENCODING (op_i) ───────────────────────────────────────────────────
//   op_i is the 4-bit sub-opcode WITHIN the non-compute unit.
//   The top 2 bits of the 6-bit FPU opcode (from fpu_top) say "use noncomp".
//   Here we receive only the bottom 4 bits.
//
//   4'b0000  FCLASS    classify operand A
//   4'b0001  FSGNJ     sign injection
//   4'b0010  FSGNJN    negated sign injection
//   4'b0011  FSGNJX    XOR sign injection
//   4'b0100  FEQ       equal comparison → int result
//   4'b0101  FLT       less-than → int result
//   4'b0110  FLE       less-than-or-equal → int result
//   4'b0111  FMIN      floating-point minimum → FP result
//   4'b1000  FMAX      floating-point maximum → FP result
//
// ── OUTPUT ROUTING ───────────────────────────────────────────────────────────
//   result_o     [FLEN-1:0]  — FP result (FSGNJ / FMIN / FMAX use this)
//   int_result_o [XLEN-1:0]  — Integer result (FCLASS / FEQ / FLT / FLE)
//   For each op, only ONE of these carries the meaningful answer.
//   fpu_top knows which to use based on op_i.
//
// =============================================================================

module fpu_noncomp #(
    parameter int FLEN = 32,   // FP register width (32 or 64)
    parameter int XLEN = 32    // integer register width (32 or 64)
) (
    input  logic              clk,
    input  logic              rst_n,

    // ── Handshake ──────────────────────────────────────────────────────────
    input  logic              valid_i,      // upstream: operands are ready

    // ── Operation select ──────────────────────────────────────────────────
    input  logic [3:0]        op_i,         // 4-bit noncomp sub-opcode (see above)
    input  logic [1:0]        fmt_i,        // format: 2'b00=FP32, 2'b01=FP64

    // ── Operands ──────────────────────────────────────────────────────────
    input  logic [FLEN-1:0]   src_a_i,      // operand A
    input  logic [FLEN-1:0]   src_b_i,      // operand B (for sign/compare ops)

    // ── Registered results (1-cycle latency) ──────────────────────────────
    output logic              valid_o,       // result is ready
    output logic [FLEN-1:0]   result_o,      // FP result (FSGNJ / FMIN / FMAX)
    output logic [XLEN-1:0]   int_result_o,  // integer result (FCLASS / compare)
    output logic [4:0]        fflags_o       // {NV, DZ, OF, UF, NX} — only NV used here
);

    // =========================================================================
    // Opcode constants — named so the code is self-documenting
    // =========================================================================
    localparam logic [3:0] OP_FCLASS  = 4'b0000;
    localparam logic [3:0] OP_FSGNJ   = 4'b0001;
    localparam logic [3:0] OP_FSGNJN  = 4'b0010;
    localparam logic [3:0] OP_FSGNJX  = 4'b0011;
    localparam logic [3:0] OP_FEQ     = 4'b0100;
    localparam logic [3:0] OP_FLT     = 4'b0101;
    localparam logic [3:0] OP_FLE     = 4'b0110;
    localparam logic [3:0] OP_FMIN    = 4'b0111;
    localparam logic [3:0] OP_FMAX    = 4'b1000;

    // =========================================================================
    // IEEE 754 field widths, derived from FLEN at compile time.
    // We only support FP32 (FLEN=32) and FP64 (FLEN=64) for now.
    // =========================================================================
    //   FP32:  sign=bit31, exponent=bits[30:23] (8 bits), mantissa=bits[22:0] (23 bits)
    //   FP64:  sign=bit63, exponent=bits[62:52] (11 bits), mantissa=bits[51:0] (52 bits)
    localparam int EW   = (FLEN == 64) ? 11 : 8;   // exponent field width
    localparam int MW   = FLEN - EW - 1;             // mantissa field width
    localparam int MMSB = MW - 1;                    // index of mantissa MSB (the quiet bit)

    // The "all-ones" exponent pattern that signals NaN or Infinity
    localparam logic [EW-1:0] EXP_ALL_ONES  = '1;
    localparam logic [EW-1:0] EXP_ALL_ZEROS = '0;

    // The RISC-V canonical quiet NaN for each format.
    // Using generate so each branch has an exact-width literal — avoids the
    // width-mismatch warning a ternary would produce, and avoids replication
    // counts that some tools reject in localparam definitions.
    //   FP32: 0_11111111_10000...0  = 0x7FC0_0000
    //   FP64: 0_11111111111_10...0  = 0x7FF8_0000_0000_0000
    logic [FLEN-1:0] CANONICAL_NAN;
    generate
        if (FLEN == 64) begin : g_cnan64
            assign CANONICAL_NAN = 64'h7FF8_0000_0000_0000;
        end else begin : g_cnan32
            assign CANONICAL_NAN = 32'h7FC0_0000;
        end
    endgenerate

    // =========================================================================
    // Step 1: Unpack both operands into sign, exponent, mantissa.
    //
    // The `-: EW` syntax means "EW bits starting at position X, going down."
    //   src_a_i[FLEN-2 -: EW]  =  src_a_i[FLEN-2 : FLEN-2-EW+1]
    //                           =  src_a_i[FLEN-2 : MW]          ← the exponent field
    //   src_a_i[MW-1 -: MW]    =  src_a_i[MW-1 : 0]             ← the mantissa field
    // Using -: keeps the bit ranges as CONSTANTS even though EW/MW are localparams.
    // =========================================================================
    logic              sign_a, sign_b;
    logic [EW-1:0]     exp_a,  exp_b;
    logic [MW-1:0]     mant_a, mant_b;

    assign sign_a = src_a_i[FLEN-1];
    assign exp_a  = src_a_i[FLEN-2 -: EW];
    assign mant_a = src_a_i[MW-1   -: MW];

    assign sign_b = src_b_i[FLEN-1];
    assign exp_b  = src_b_i[FLEN-2 -: EW];
    assign mant_b = src_b_i[MW-1   -: MW];

    // =========================================================================
    // Step 2: Classify both operands.
    //
    // We inline the classification logic here for self-containment.
    // (The standalone fpu_classify module is used by fpu_fma in Phase 2.)
    // =========================================================================

    // -- Operand A classification --
    logic a_exp_all0, a_exp_all1, a_mant_all0;
    assign a_exp_all0  = (exp_a  == EXP_ALL_ZEROS);
    assign a_exp_all1  = (exp_a  == EXP_ALL_ONES);
    assign a_mant_all0 = (mant_a == '0);

    logic a_is_zero, a_is_sub, a_is_normal, a_is_inf, a_is_nan, a_is_qnan, a_is_snan;
    assign a_is_zero   =  a_exp_all0 &  a_mant_all0;
    assign a_is_sub    =  a_exp_all0 & ~a_mant_all0;
    assign a_is_normal = ~a_exp_all0 & ~a_exp_all1;
    assign a_is_inf    =  a_exp_all1 &  a_mant_all0;
    assign a_is_nan    =  a_exp_all1 & ~a_mant_all0;
    assign a_is_qnan   =  a_is_nan   &  mant_a[MMSB];   // quiet bit = MSB of mantissa
    assign a_is_snan   =  a_is_nan   & ~mant_a[MMSB];   // signaling = MSB=0, mant≠0

    // -- Operand B classification --
    logic b_exp_all0, b_exp_all1, b_mant_all0;
    assign b_exp_all0  = (exp_b  == EXP_ALL_ZEROS);
    assign b_exp_all1  = (exp_b  == EXP_ALL_ONES);
    assign b_mant_all0 = (mant_b == '0);

    logic b_is_zero, b_is_sub, b_is_normal, b_is_inf, b_is_nan, b_is_qnan, b_is_snan;
    assign b_is_zero   =  b_exp_all0 &  b_mant_all0;
    assign b_is_sub    =  b_exp_all0 & ~b_mant_all0;
    assign b_is_normal = ~b_exp_all0 & ~b_exp_all1;
    assign b_is_inf    =  b_exp_all1 &  b_mant_all0;
    assign b_is_nan    =  b_exp_all1 & ~b_mant_all0;
    assign b_is_qnan   =  b_is_nan   &  mant_b[MMSB];
    assign b_is_snan   =  b_is_nan   & ~mant_b[MMSB];

    // Pre-extract payload (all bits except sign bit) as a wire.
    // This avoids parameterized range selects inside always_comb blocks,
    // which Icarus Verilog does not support ("constant selects in always_*").
    logic [FLEN-2:0] payload_a;
    assign payload_a = src_a_i[FLEN-2:0];

    // Suppress unused-signal warnings for signals reserved for Phase 2+ ops.
    /* verilator lint_off UNUSEDSIGNAL */
    logic _unused;
    assign _unused = a_is_sub | a_is_normal | b_is_sub | b_is_normal
                   | b_is_inf | b_is_qnan | ^fmt_i;
    /* verilator lint_on UNUSEDSIGNAL */

    // =========================================================================
    // Step 3: FCLASS — build the 10-bit one-hot classification integer.
    //
    // RISC-V ISA Manual §11.2 defines bit positions:
    //   Bit 9: quiet NaN          Bit 8: signaling NaN
    //   Bit 7: negative infinity   Bit 6: negative normal number
    //   Bit 5: negative subnormal  Bit 4: negative zero
    //   Bit 3: positive zero       Bit 2: positive subnormal
    //   Bit 1: positive normal     Bit 0: positive infinity
    //
    // Exactly one bit is set for any valid FP input.
    // =========================================================================
    logic [9:0] fclass_result;
    always_comb begin
        fclass_result = 10'b0;
        if      (a_is_qnan)              fclass_result[9] = 1'b1;
        else if (a_is_snan)              fclass_result[8] = 1'b1;
        else if (a_is_inf  &&  sign_a)   fclass_result[7] = 1'b1;   // -inf
        else if (a_is_normal && sign_a)  fclass_result[6] = 1'b1;   // -normal
        else if (a_is_sub  &&  sign_a)   fclass_result[5] = 1'b1;   // -subnormal
        else if (a_is_zero &&  sign_a)   fclass_result[4] = 1'b1;   // -zero
        else if (a_is_zero && !sign_a)   fclass_result[3] = 1'b1;   // +zero
        else if (a_is_sub  && !sign_a)   fclass_result[2] = 1'b1;   // +subnormal
        else if (a_is_normal && !sign_a) fclass_result[1] = 1'b1;   // +normal
        else if (a_is_inf  && !sign_a)   fclass_result[0] = 1'b1;   // +infinity
    end

    // =========================================================================
    // Step 4: FSGNJ / FSGNJN / FSGNJX — sign injection operations.
    //
    // These just replace the SIGN BIT of src_a with some function of the signs
    // of src_a and src_b.  The exponent and mantissa of src_a are untouched.
    //
    //   FSGNJ:  new_sign = sign_b               (copy src_b's sign to src_a)
    //   FSGNJN: new_sign = ~sign_b              (flip src_b's sign, apply to src_a)
    //   FSGNJX: new_sign = sign_a XOR sign_b    (toggle src_a's sign based on src_b)
    //
    // This trick is used by compilers to implement:
    //   fabs(x)  = FSGNJ(x, 0.0)     — force positive
    //   fneg(x)  = FSGNJN(x, x)      — flip sign
    //   copysign = FSGNJ(x, y)        — copy sign from y to x
    // =========================================================================
    logic new_sign;
    always_comb begin
        unique case (op_i)
            OP_FSGNJ:  new_sign = sign_b;
            OP_FSGNJN: new_sign = ~sign_b;
            OP_FSGNJX: new_sign = sign_a ^ sign_b;
            default:   new_sign = sign_a;
        endcase
    end

    // Reconstruct the FP word with the new sign bit, keeping all other bits unchanged.
    // The payload (exp + mant) occupies bits [FLEN-2:0] for any format.
    logic [FLEN-1:0] fsgnj_result;
    assign fsgnj_result = {new_sign, src_a_i[FLEN-2:0]};

    // =========================================================================
    // Step 5: Numeric comparison (FEQ, FLT, FLE, FMIN, FMAX)
    //
    // Comparing FP numbers as unsigned integers WORKS for same-sign numbers
    // because IEEE 754 was cleverly designed so that:
    //   • Positive FP: larger bit pattern = larger value
    //   • Negative FP: larger bit pattern = SMALLER value (more negative)
    //
    // So we compare the MAGNITUDE (= all bits except sign) as unsigned, then
    // apply sign rules.  Special cases: ±0 are equal, NaN comparisons are false.
    // =========================================================================

    // The "magnitude" for comparison: exponent concatenated with mantissa.
    // Larger magnitude → further from zero.
    logic [FLEN-2:0] mag_a, mag_b;
    assign mag_a = src_a_i[FLEN-2:0];
    assign mag_b = src_b_i[FLEN-2:0];

    // Is A numerically LESS THAN B?   (NaN inputs: caller must check first)
    logic is_a_lt_b;
    always_comb begin
        if (a_is_zero && b_is_zero) begin
            // −0 and +0 are equal; neither is less than the other
            is_a_lt_b = 1'b0;
        end else if (sign_a && !sign_b) begin
            // A is negative, B is positive → A < B (always)
            is_a_lt_b = 1'b1;
        end else if (!sign_a && sign_b) begin
            // A is positive, B is negative → A > B (never A < B)
            is_a_lt_b = 1'b0;
        end else if (!sign_a && !sign_b) begin
            // Both positive: larger magnitude = larger value
            is_a_lt_b = (mag_a < mag_b);
        end else begin
            // Both negative: larger magnitude = SMALLER value (more negative = less)
            is_a_lt_b = (mag_a > mag_b);
        end
    end

    // Is A numerically EQUAL TO B?
    logic is_a_eq_b;
    always_comb begin
        if (a_is_zero && b_is_zero) begin
            // −0 == +0 is a fundamental IEEE 754 rule
            is_a_eq_b = 1'b1;
        end else begin
            // For non-zero: equal if all bits are identical
            is_a_eq_b = (src_a_i == src_b_i);
        end
    end

    // =========================================================================
    // Step 6: FEQ / FLT / FLE — build compare results and NV (invalid) flag.
    //
    // NV (Invalid Operation) flag rules:
    //   FEQ: NV=1 only if either input is a SIGNALING NaN (sNaN).
    //        qNaN inputs → FEQ returns 0 BUT no NV flag. This is "quiet" compare.
    //   FLT: NV=1 if EITHER input is ANY kind of NaN (quiet or signaling).
    //   FLE: NV=1 if EITHER input is ANY kind of NaN.
    //
    // Mnemonic: "FEQ is quiet, FLT/FLE are signaling comparisons."
    // =========================================================================
    logic feq_result, flt_result, fle_result;
    logic feq_nv, flt_nv, fle_nv;

    // FEQ: false if either input is NaN
    assign feq_result = (a_is_nan | b_is_nan) ? 1'b0 : is_a_eq_b;
    assign feq_nv     = a_is_snan | b_is_snan;   // only sNaN triggers NV for FEQ

    // FLT: false if either input is NaN
    assign flt_result = (a_is_nan | b_is_nan) ? 1'b0 : is_a_lt_b;
    assign flt_nv     = a_is_nan | b_is_nan;      // ANY NaN triggers NV for FLT

    // FLE: false if either input is NaN
    assign fle_result = (a_is_nan | b_is_nan) ? 1'b0 : (is_a_lt_b | is_a_eq_b);
    assign fle_nv     = a_is_nan | b_is_nan;      // ANY NaN triggers NV for FLE

    // =========================================================================
    // Step 7: FMIN / FMAX
    //
    // IEEE 754-2019 minNum/maxNum rules (also adopted in RISC-V ISA):
    //   • If A is NaN, return B (as long as B is not NaN).
    //   • If B is NaN, return A (as long as A is not NaN).
    //   • If BOTH are NaN, return canonical qNaN.
    //   • FMIN(−0, +0) = −0   (negative zero is "more negative")
    //   • FMAX(−0, +0) = +0
    //   • sNaN inputs set the NV flag (even though the non-NaN operand is returned).
    //
    // This "return the non-NaN" rule is DIFFERENT from IEEE 754-2008 (which
    // said min(x, NaN) = NaN).  RISC-V follows the 2019 revision.
    // =========================================================================
    logic [FLEN-1:0] fmin_result, fmax_result;
    logic             fmin_nv, fmax_nv;

    always_comb begin
        // ── FMIN ──────────────────────────────────────────────────────────
        if (a_is_nan && b_is_nan) begin
            fmin_result = CANONICAL_NAN;       // both NaN → canonical NaN
        end else if (a_is_nan) begin
            fmin_result = src_b_i;             // A is NaN → return B
        end else if (b_is_nan) begin
            fmin_result = src_a_i;             // B is NaN → return A
        end else if (a_is_zero && b_is_zero) begin
            fmin_result = {1'b1, payload_a};  // FMIN(±0,±0) = −0 (set sign=1)
        end else begin
            fmin_result = is_a_lt_b ? src_a_i : src_b_i;
        end
        fmin_nv = a_is_snan | b_is_snan;      // sNaN input → NV even though ignored

        // ── FMAX ──────────────────────────────────────────────────────────
        if (a_is_nan && b_is_nan) begin
            fmax_result = CANONICAL_NAN;
        end else if (a_is_nan) begin
            fmax_result = src_b_i;
        end else if (b_is_nan) begin
            fmax_result = src_a_i;
        end else if (a_is_zero && b_is_zero) begin
            fmax_result = {1'b0, payload_a};  // FMAX(±0,±0) = +0 (set sign=0)
        end else begin
            fmax_result = is_a_lt_b ? src_b_i : src_a_i;
        end
        fmax_nv = a_is_snan | b_is_snan;
    end

    // =========================================================================
    // Step 8: Combinational result MUX — pick the right answer based on op_i.
    // All computations above run IN PARALLEL; we just select the right one.
    // =========================================================================
    logic [FLEN-1:0]  comb_result;
    logic [XLEN-1:0]  comb_int_result;
    logic             comb_nv;   // Invalid Operation exception flag

    always_comb begin
        comb_result     = '0;
        comb_int_result = '0;
        comb_nv         = 1'b0;

        unique case (op_i)
            OP_FCLASS: begin
                comb_int_result = XLEN'(fclass_result);  // 10-bit → zero-extend to XLEN
            end
            OP_FSGNJ, OP_FSGNJN, OP_FSGNJX: begin
                comb_result = fsgnj_result;
            end
            OP_FEQ: begin
                comb_int_result = XLEN'(feq_result);
                comb_nv         = feq_nv;
            end
            OP_FLT: begin
                comb_int_result = XLEN'(flt_result);
                comb_nv         = flt_nv;
            end
            OP_FLE: begin
                comb_int_result = XLEN'(fle_result);
                comb_nv         = fle_nv;
            end
            OP_FMIN: begin
                comb_result = fmin_result;
                comb_nv     = fmin_nv;
            end
            OP_FMAX: begin
                comb_result = fmax_result;
                comb_nv     = fmax_nv;
            end
            default: begin
                comb_result     = '0;
                comb_int_result = '0;
            end
        endcase
    end

    // =========================================================================
    // Step 9: Register the outputs — this is what makes it "1-cycle latency".
    //
    // We compute everything combinationally above (no clock needed),
    // then latch the result on the rising clock edge.
    // This improves timing: the register "breaks" the combinational path,
    // allowing a higher clock frequency.
    // =========================================================================
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            valid_o      <= 1'b0;
            result_o     <= '0;
            int_result_o <= '0;
            fflags_o     <= 5'b0;
        end else begin
            valid_o      <= valid_i;
            result_o     <= comb_result;
            int_result_o <= comb_int_result;
            // fflags_o = {NV, DZ, OF, UF, NX}
            // Non-compute ops can only generate NV (invalid operation).
            // DZ, OF, UF, NX are impossible here — no division or rounding.
            // Gate flags with valid_i: exception flags are only meaningful when
            // the operation itself was valid. Without this gate, sNaN bit patterns
            // sitting on idle inputs would spuriously set NV even when no op fired.
            fflags_o     <= {(valid_i & comb_nv), 4'b0000};
        end
    end

    // =========================================================================
    // Formal verification properties
    // =========================================================================
`ifdef FORMAL
    // Track whether reset has ever occurred (required for induction to converge)
    logic f_was_reset;
    initial f_was_reset = 0;
    always_ff @(posedge clk or negedge rst_n)
        if (!rst_n) f_was_reset <= 1'b1;

    always_comb begin
        if (f_was_reset) begin
            // valid_o follows valid_i with exactly 1-cycle delay
            // (we prove this via assume/assert on the inputs in the .sby)

            // FCLASS result must always be exactly one-hot (exactly 1 bit set)
            // when the previous cycle had valid_i=1 and op=FCLASS
            // (we check this in the testbench; formal covers protocol)

            // NV flag can only be set when valid_o is high
            if (!valid_o) assert(fflags_o[4] == 1'b0);
        end
    end

    // Cover: NV flag should be reachable (e.g., sNaN input to FEQ)
    always_comb begin
        cover(valid_o && fflags_o[4]);   // NV was set
        cover(valid_o && result_o == CANONICAL_NAN);  // canonical NaN produced
    end
`endif

endmodule
