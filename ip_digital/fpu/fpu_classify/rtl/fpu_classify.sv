// =============================================================================
// fpu_classify.sv  —  IEEE 754 Floating-Point Operand Unpacker & Classifier
// =============================================================================
//
// ── WHAT IS THIS? ────────────────────────────────────────────────────────────
//   Every floating-point operation starts here.  Before we can add, compare,
//   or multiply two FP numbers, we need to UNPACK the raw bit pattern and ask:
//   "What kind of number is this?"  That's exactly what this module does.
//
// ── HOW DOES IEEE 754 STORE A NUMBER? ────────────────────────────────────────
//   IEEE 754 splits a floating-point number into three fields:
//
//   ┌────┬───────────────┬────────────────────────────────┐
//   │ S  │   Exponent    │           Mantissa             │
//   │ 1b │   EW bits     │           MW bits              │
//   └────┴───────────────┴────────────────────────────────┘
//    MSB                                               LSB
//
//   S (sign):      0 = positive, 1 = negative
//   Exponent:      stored as a BIASED integer (actual value = stored − bias)
//                  bias = 2^(EW−1) − 1   →  127 for FP32, 1023 for FP64
//   Mantissa:      the fractional digits.  For NORMAL numbers the leading "1."
//                  is NOT stored (the "hidden bit") — it's implied.
//                  Example: stored mantissa 0x400000 = 0b01000...0
//                           → actual significand = 1.01000...0 in binary = 1.25
//
// ── FORMAT TABLE ─────────────────────────────────────────────────────────────
//   Format  FLEN   Sign  Exponent  Mantissa   Bias   fmt_i
//   ──────  ─────  ────  ────────  ────────   ────   ─────
//   FP32     32     1b    8 bits    23 bits    127    2'b00
//   FP64     64     1b   11 bits    52 bits   1023    2'b01
//   FP16     16     1b    5 bits    10 bits     15    2'b10
//
// ── SPECIAL VALUES ───────────────────────────────────────────────────────────
//   All of these use extreme exponent values (all-0s or all-1s):
//
//   Zero:        exp=0x00, mant=0          → the number 0.0 (or −0.0)
//   Subnormal:   exp=0x00, mant≠0          → very small number, no hidden bit
//   Infinity:    exp=0xFF, mant=0          → overflow result (or 1/0)
//   Quiet NaN:   exp=0xFF, mant[MSB]=1    → "Not a Number", propagates silently
//   Signaling NaN: exp=0xFF, mant[MSB]=0, mant≠0 → NaN that triggers exception
//   Normal:      exp = 0x01..0xFE          → ordinary number
//
// ── THE QUIET BIT ────────────────────────────────────────────────────────────
//   The MSB of the mantissa field distinguishes quiet vs. signaling NaN.
//   quiet NaN (qNaN):     mantissa[MSB] = 1  — just propagates, no exception
//   signaling NaN (sNaN): mantissa[MSB] = 0  — triggers "Invalid Operation" flag
//
// ── NaN-BOXING (RISC-V §11.3) ────────────────────────────────────────────────
//   In RISC-V, floating-point registers are always FLEN bits wide.
//   When a 32-bit float lives in a 64-bit register, the CPU must fill
//   the upper 32 bits with all 1s.  If those bits are NOT all 1s, the
//   hardware must treat the value as a canonical NaN.
//   This prevents accidental reinterpretation of integer values as floats.
//
// ── OUTPUTS ──────────────────────────────────────────────────────────────────
//   This module is PURELY COMBINATIONAL — no clock, no state.
//   Results appear within a single gate delay of the inputs.
//
// =============================================================================

module fpu_classify #(
    parameter int FLEN = 32    // FP register width: 32 or 64
) (
    // ── Input: the raw bit pattern from the register file ──────────────────
    input  logic [FLEN-1:0]  operand_i,

    // ── Input: which IEEE 754 format are we using? ─────────────────────────
    //   2'b00 = FP32 (single precision, 32-bit)
    //   2'b01 = FP64 (double precision, 64-bit)  — requires FLEN=64
    //   2'b10 = FP16 (half precision, 16-bit)
    input  logic [1:0]       fmt_i,

    // ── Output: unpacked fields ────────────────────────────────────────────
    output logic             sign_o,      // 0=positive, 1=negative
    output logic [10:0]      exp_o,       // biased exponent (zero-padded to 11 bits)
    output logic [51:0]      mant_o,      // stored mantissa (zero-padded to 52 bits)

    // ── Output: what KIND of number is this? ──────────────────────────────
    output logic             is_zero_o,     // exactly ±0
    output logic             is_subnorm_o,  // denormalized (very small, exp=0, mant≠0)
    output logic             is_normal_o,   // ordinary number
    output logic             is_inf_o,      // ±infinity
    output logic             is_nan_o,      // any NaN (quiet OR signaling)
    output logic             is_qnan_o,     // quiet NaN  (silent propagation)
    output logic             is_snan_o,     // signaling NaN (triggers NV exception)
    output logic             is_nanbox_fail_o  // RISC-V NaN-box violation
);

    // =========================================================================
    // Derive format-specific widths using localparams
    // These are COMPILE-TIME constants — hardware is generated once per FLEN.
    // =========================================================================
    localparam int EW32 = 8;   localparam int MW32 = 23;
    localparam int EW64 = 11;  localparam int MW64 = 52;
    localparam int EW16 = 5;   localparam int MW16 = 10;

    // =========================================================================
    // Step 1: Extract sign, exponent, and mantissa for each possible format.
    // We do ALL formats in parallel using pure wire logic, then MUX at the end.
    // This avoids if/generate clutter and lets synthesis optimize away unused paths.
    // =========================================================================

    // ── FP32: bits 31:0 ────────────────────────────────────────────────────
    logic             fp32_sign;
    logic [10:0]      fp32_exp;
    logic [51:0]      fp32_mant;
    logic             fp32_exp_all0, fp32_exp_all1;
    logic             fp32_quiet_bit;   // mantissa[22] — the NaN quiet/signaling bit

    assign fp32_sign      = operand_i[31];
    assign fp32_exp       = 11'(operand_i[30:23]);   // zero-extend 8b→11b
    assign fp32_mant      = 52'(operand_i[22:0]);    // zero-extend 23b→52b
    assign fp32_exp_all0  = (operand_i[30:23] == 8'h00);
    assign fp32_exp_all1  = (operand_i[30:23] == 8'hFF);
    assign fp32_quiet_bit = operand_i[22];

    // ── FP64: bits 63:0 (only meaningful when FLEN=64) ─────────────────────
    logic             fp64_sign;
    logic [10:0]      fp64_exp;
    logic [51:0]      fp64_mant;
    logic             fp64_exp_all0, fp64_exp_all1;
    logic             fp64_quiet_bit;

    generate
        if (FLEN == 64) begin : gen_fp64_fields
            assign fp64_sign      = operand_i[63];
            assign fp64_exp       = operand_i[62:52];
            assign fp64_mant      = operand_i[51:0];
            assign fp64_exp_all0  = (operand_i[62:52] == 11'h000);
            assign fp64_exp_all1  = (operand_i[62:52] == 11'h7FF);
            assign fp64_quiet_bit = operand_i[51];
        end else begin : gen_fp64_fields_stub
            assign fp64_sign      = 1'b0;
            assign fp64_exp       = 11'h0;
            assign fp64_mant      = 52'h0;
            assign fp64_exp_all0  = 1'b1;
            assign fp64_exp_all1  = 1'b0;
            assign fp64_quiet_bit = 1'b0;
        end
    endgenerate

    // ── FP16: bits 15:0 ────────────────────────────────────────────────────
    logic             fp16_sign;
    logic [10:0]      fp16_exp;
    logic [51:0]      fp16_mant;
    logic             fp16_exp_all0, fp16_exp_all1;
    logic             fp16_quiet_bit;

    assign fp16_sign      = operand_i[15];
    assign fp16_exp       = 11'(operand_i[14:10]);   // zero-extend 5b→11b
    assign fp16_mant      = 52'(operand_i[9:0]);     // zero-extend 10b→52b
    assign fp16_exp_all0  = (operand_i[14:10] == 5'b00000);
    assign fp16_exp_all1  = (operand_i[14:10] == 5'b11111);
    assign fp16_quiet_bit = operand_i[9];

    // =========================================================================
    // Step 2: MUX — pick the right fields based on fmt_i
    // =========================================================================
    logic exp_all0, exp_all1, mant_all0, quiet_bit;

    always_comb begin
        unique case (fmt_i)
            2'b00: begin   // FP32
                sign_o   = fp32_sign;
                exp_o    = fp32_exp;
                mant_o   = fp32_mant;
                exp_all0 = fp32_exp_all0;
                exp_all1 = fp32_exp_all1;
                quiet_bit= fp32_quiet_bit;
            end
            2'b01: begin   // FP64
                sign_o   = fp64_sign;
                exp_o    = fp64_exp;
                mant_o   = fp64_mant;
                exp_all0 = fp64_exp_all0;
                exp_all1 = fp64_exp_all1;
                quiet_bit= fp64_quiet_bit;
            end
            2'b10: begin   // FP16
                sign_o   = fp16_sign;
                exp_o    = fp16_exp;
                mant_o   = fp16_mant;
                exp_all0 = fp16_exp_all0;
                exp_all1 = fp16_exp_all1;
                quiet_bit= fp16_quiet_bit;
            end
            default: begin
                sign_o   = 1'b0;
                exp_o    = 11'h0;
                mant_o   = 52'h0;
                exp_all0 = 1'b1;
                exp_all1 = 1'b0;
                quiet_bit= 1'b0;
            end
        endcase
    end

    assign mant_all0 = (mant_o == 52'h0);

    // =========================================================================
    // Step 3: Classification — derive each class from the extracted fields
    //
    // Truth table:
    //   exp_all0  exp_all1  mant_all0  |  Class
    //   ────────  ────────  ─────────  │  ─────────────────
    //      1         0          1      │  ±Zero
    //      1         0          0      │  Subnormal
    //      0         0          X      │  Normal
    //      0         1          1      │  ±Infinity
    //      0         1          0      │  NaN (quiet or signaling)
    // =========================================================================
    assign is_zero_o    =  exp_all0 & mant_all0;
    assign is_subnorm_o =  exp_all0 & ~mant_all0;
    assign is_normal_o  = ~exp_all0 & ~exp_all1;
    assign is_inf_o     =  exp_all1 & mant_all0;
    assign is_nan_o     =  exp_all1 & ~mant_all0;
    assign is_qnan_o    =  is_nan_o &  quiet_bit;   // mantissa MSB = 1 → quiet
    assign is_snan_o    =  is_nan_o & ~quiet_bit;   // mantissa MSB = 0 → signaling

    // =========================================================================
    // NaN-Boxing Check (RISC-V §11.3)
    // In RISC-V: when FLEN=64 and the CPU is running an FP32 instruction,
    // the upper 32 bits of the 64-bit register must be all 1s.
    // If NOT all 1s → the register was NOT properly NaN-boxed → treat as qNaN.
    // =========================================================================
    generate
        if (FLEN == 64) begin : gen_nanbox
            assign is_nanbox_fail_o = (fmt_i == 2'b00) &&   // FP32 operation
                                      (operand_i[63:32] != 32'hFFFF_FFFF);
        end else begin : gen_nanbox_none
            assign is_nanbox_fail_o = 1'b0;   // FLEN=32 can't have NaN-box issue
        end
    endgenerate

    // =========================================================================
    // Formal verification properties
    // These assertions are COMPILED AWAY in normal simulation —
    // they only activate when running SymbiYosys (`define FORMAL).
    // =========================================================================
`ifdef FORMAL
    always_comb begin
        // Every number must belong to exactly one base class
        assert((is_zero_o + is_subnorm_o + is_normal_o + is_inf_o + is_nan_o) == 5'd1);
        // qNaN and sNaN are mutually exclusive sub-cases of NaN
        if (is_nan_o) assert(is_qnan_o ^ is_snan_o);
        // Neither qnan nor snan can be set without is_nan being set
        assert(!(is_qnan_o && !is_nan_o));
        assert(!(is_snan_o && !is_nan_o));
    end
`endif

endmodule
