// =============================================================================
// fpu_clk_gate_ctrl.sv  —  ICG Enable Generation
// =============================================================================
//
// Generates per-unit clock-gate enable signals from the incoming opcode.
// These enable signals feed ICG cells (latch-based, glitch-free) upstream of
// each sub-unit's clock tree.  When a unit is idle its enable is LOW and the
// ICG prevents any rising edge from propagating — all registers in that unit
// hold state and draw only leakage power.
//
// WHY A SEPARATE MODULE?
//   Synthesis tools must see the enable logic as combinational feeding a
//   dedicated ICG cell port.  Mixing enable generation with datapath logic
//   can prevent the synthesizer from recognising the ICG pattern and may
//   introduce hold-time violations.  Keeping it isolated makes the
//   clock-gate intent unambiguous to both the synthesis tool and the STA
//   engine.
//
// Phase 4 note: div_clk_en must stay HIGH while a FDIV/FSQRT is iterating
//   (busy_div = 1) even when no new valid_i arrives, so the partial-remainder
//   register can clock every cycle until completion.
//
// =============================================================================

module fpu_clk_gate_ctrl (
    input  logic       valid_i,
    input  logic [5:0] op_i,
    input  logic       busy_div,    // high while FDIV/FSQRT iterates (Phase 4)

    output logic       fma_clk_en,
    output logic       div_clk_en,
    output logic       cvt_clk_en,
    output logic       ncomp_clk_en
);
    // op_i[5:4] encodes the destination unit:
    //   2'b00  FMA       (FADD/FSUB/FMUL/FMADD/FMSUB/FNMADD/FNMSUB)
    //   2'b01  Div/Sqrt  (FDIV/FSQRT)
    //   2'b10  Conversion(FCVT, FMV)
    //   2'b11  Non-compute (FCLASS, FSGNJ, compare, FMIN/FMAX)
    // op_i[3:0] is the sub-opcode — used by the addressed unit, not here.
    /* verilator lint_off UNUSEDSIGNAL */
    logic _unused_subop;
    assign _unused_subop = ^op_i[3:0];
    /* verilator lint_on UNUSEDSIGNAL */
    assign fma_clk_en   = valid_i & (op_i[5:4] == 2'b00);
    assign div_clk_en   = (valid_i & (op_i[5:4] == 2'b01)) | busy_div;
    assign cvt_clk_en   = valid_i & (op_i[5:4] == 2'b10);
    assign ncomp_clk_en = valid_i & (op_i[5:4] == 2'b11);

endmodule
