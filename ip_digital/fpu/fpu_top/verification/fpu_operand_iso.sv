// =============================================================================
// fpu_operand_iso.sv  —  Operand Isolation for Idle FPU Sub-Units
// =============================================================================
//
// When an FPU sub-unit is idle (its clock is gated) all of its registers
// hold state, but the COMBINATIONAL inputs — particularly the mantissa
// lines feeding the Booth encoder and the CSA tree — can still toggle in
// response to unrelated bus activity on src_a / src_b.  Without isolation
// those toggling inputs ripple through thousands of XOR / AND gates inside
// the multiplier and cause unnecessary dynamic power dissipation.
//
// This module zeroes the operand buses feeding each sub-unit when its
// enable is LOW.  Because the downstream unit is clock-gated, its output
// registers will never capture the zeroed value, but the SWITCHING inside
// the combinational tree is eliminated.
//
// POWER IMPACT (estimated):
//   FMA Dadda tree is ~40% of total FPU dynamic power.
//   Isolation when FMA is idle saves ~35% at a typical mixed workload.
//   Isolation cost: one AND gate per operand bit (< 0.1% of total area).
//
// USAGE NOTE:
//   The outputs of this module (fma_a_o, fma_b_o, fma_c_o, cvt_int_o) must
//   be routed directly to the corresponding sub-unit inputs.  Do NOT insert
//   any registered re-timing between this module and the sub-unit; doing so
//   would delay the isolation by one cycle and waste the first idle cycle's
//   savings.
//
// =============================================================================

module fpu_operand_iso #(
    parameter int FLEN = 32,
    parameter int XLEN = 32
) (
    // Per-unit enable signals from fpu_clk_gate_ctrl
    input  logic              fma_en,
    input  logic              cvt_en,

    // Raw (unmasked) operands from the upstream pipeline
    input  logic [FLEN-1:0]   src_a_i,
    input  logic [FLEN-1:0]   src_b_i,
    input  logic [FLEN-1:0]   src_c_i,
    input  logic [XLEN-1:0]   int_src_i,

    // Isolated FMA operands (zeroed when FMA unit is idle)
    output logic [FLEN-1:0]   fma_a_o,
    output logic [FLEN-1:0]   fma_b_o,
    output logic [FLEN-1:0]   fma_c_o,

    // Isolated CVT integer operand (zeroed when CVT unit is idle)
    output logic [XLEN-1:0]   cvt_int_o
);
    assign fma_a_o   = fma_en ? src_a_i  : '0;
    assign fma_b_o   = fma_en ? src_b_i  : '0;
    assign fma_c_o   = fma_en ? src_c_i  : '0;
    assign cvt_int_o = cvt_en ? int_src_i : '0;

endmodule
