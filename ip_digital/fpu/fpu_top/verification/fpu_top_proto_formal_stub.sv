// fpu_top_proto_formal_stub.sv — free (anyseq) stand-ins for EVERY fpu_top
// submodule, for the one property this .sby proves:
//
//   assert(ready_o == ~busy_o)   [fpu_top.sv, gated by f_was_reset]
//
// Structural trace (rtl/fpu_top.sv):
//   assign busy_o  = div_busy;      // from fpu_divsqrt's busy_o ONLY
//   assign ready_o = ~busy_o;
//
// This property is true for ANY value of div_busy — both sides reduce to
// `~div_busy` after substitution. It's a pure fact about fpu_top.sv's own
// wire assignments, provable without a single real submodule: fpu_divsqrt
// does NOT need to be real either, despite feeding the property directly.
//
// First attempt kept fpu_divsqrt real (stubbing only fpu_fma/cvt/noncomp/
// result_mux/clk_gate_ctrl) on the theory that FF count was the limiter.
// That got further (z3 stayed healthy well past the point where it used
// to crash on the full 767-FF design) but still hit a hard wall: z3
// reported "Solver Error: (error \"out of memory\")" explicitly, stuck at
// step 0 for 566s straight. fpu_divsqrt implements iterative FDIV/FSQRT —
// division/sqrt bit-vector arithmetic is one of the genuinely hard cases
// for SMT bit-blasting, independent of FF count. Since the property
// doesn't need fpu_divsqrt's correctness at all, stub it too.
//
// This file substitutes ONLY inside this formal target (see the .sby
// [files] section) — it never touches rtl/, so P1/P3/P4/P6/P7/P8 all
// build and verify against the real RTL. Every real submodule's own
// correctness is separately covered by P3/P4 functional tests + P7 LEC/P8
// GLS on the full design.

module fpu_fma #(
    parameter int FLEN = 32
) (
    input  logic              clk,
    input  logic              rst_n,
    input  logic              valid_i,
    input  logic [3:0]        op_i,
    input  logic [2:0]        rm_i,
    input  logic [FLEN-1:0]   src_a_i,
    input  logic [FLEN-1:0]   src_b_i,
    input  logic [FLEN-1:0]   src_c_i,
    output logic              valid_o,
    output logic [FLEN-1:0]   result_o,
    output logic [4:0]        fflags_o
);
    (* anyseq *) logic              f_valid;
    (* anyseq *) logic [FLEN-1:0]   f_result;
    (* anyseq *) logic [4:0]        f_fflags;
    assign valid_o  = f_valid;
    assign result_o = f_result;
    assign fflags_o = f_fflags;
endmodule

module fpu_cvt #(
    parameter int FLEN = 32,
    parameter int XLEN = 32
) (
    input  logic              clk,
    input  logic              rst_n,
    input  logic              valid_i,
    input  logic [3:0]        op_i,
    input  logic [2:0]        rm_i,
    input  logic [FLEN-1:0]   src_a_i,
    input  logic [XLEN-1:0]   int_src_i,
    output logic              valid_o,
    output logic [FLEN-1:0]   result_o,
    output logic [XLEN-1:0]   int_result_o,
    output logic [4:0]        fflags_o
);
    (* anyseq *) logic              f_valid;
    (* anyseq *) logic [FLEN-1:0]   f_result;
    (* anyseq *) logic [XLEN-1:0]   f_int_result;
    (* anyseq *) logic [4:0]        f_fflags;
    assign valid_o      = f_valid;
    assign result_o     = f_result;
    assign int_result_o = f_int_result;
    assign fflags_o     = f_fflags;
endmodule

module fpu_noncomp #(
    parameter int FLEN = 32,
    parameter int XLEN = 32
) (
    input  logic              clk,
    input  logic              rst_n,
    input  logic              valid_i,
    input  logic [3:0]        op_i,
    input  logic [1:0]        fmt_i,
    input  logic [FLEN-1:0]   src_a_i,
    input  logic [FLEN-1:0]   src_b_i,
    output logic              valid_o,
    output logic [FLEN-1:0]   result_o,
    output logic [XLEN-1:0]   int_result_o,
    output logic [4:0]        fflags_o
);
    (* anyseq *) logic              f_valid;
    (* anyseq *) logic [FLEN-1:0]   f_result;
    (* anyseq *) logic [XLEN-1:0]   f_int_result;
    (* anyseq *) logic [4:0]        f_fflags;
    assign valid_o      = f_valid;
    assign result_o     = f_result;
    assign int_result_o = f_int_result;
    assign fflags_o     = f_fflags;
endmodule

module fpu_result_mux #(
    parameter int FLEN = 32,
    parameter int XLEN = 32
) (
    input  logic              fma_valid_i,
    input  logic [FLEN-1:0]   fma_result_i,
    input  logic [4:0]        fma_fflags_i,
    input  logic              ncomp_valid_i,
    input  logic [FLEN-1:0]   ncomp_result_i,
    input  logic [XLEN-1:0]   ncomp_int_result_i,
    input  logic [4:0]        ncomp_fflags_i,
    input  logic              div_valid_i,
    input  logic [FLEN-1:0]   div_result_i,
    input  logic [4:0]        div_fflags_i,
    input  logic              cvt_valid_i,
    input  logic [FLEN-1:0]   cvt_result_i,
    input  logic [XLEN-1:0]   cvt_int_result_i,
    input  logic [4:0]        cvt_fflags_i,
    output logic              valid_o,
    output logic [FLEN-1:0]   result_o,
    output logic [XLEN-1:0]   int_result_o,
    output logic [4:0]        fflags_o
);
    (* anyseq *) logic              f_valid;
    (* anyseq *) logic [FLEN-1:0]   f_result;
    (* anyseq *) logic [XLEN-1:0]   f_int_result;
    (* anyseq *) logic [4:0]        f_fflags;
    assign valid_o      = f_valid;
    assign result_o     = f_result;
    assign int_result_o = f_int_result;
    assign fflags_o     = f_fflags;
endmodule

module fpu_divsqrt #(
    parameter int FLEN = 32
) (
    input  logic              clk,
    input  logic              rst_n,
    input  logic              valid_i,
    input  logic [3:0]        op_i,
    input  logic [2:0]        rm_i,
    input  logic [FLEN-1:0]   src_a_i,
    input  logic [FLEN-1:0]   src_b_i,
    output logic              busy_o,
    output logic              valid_o,
    output logic [FLEN-1:0]   result_o,
    output logic [4:0]        fflags_o
);
    (* anyseq *) logic              f_busy, f_valid;
    (* anyseq *) logic [FLEN-1:0]   f_result;
    (* anyseq *) logic [4:0]        f_fflags;
    assign busy_o   = f_busy;
    assign valid_o  = f_valid;
    assign result_o = f_result;
    assign fflags_o = f_fflags;
endmodule

module fpu_clk_gate_ctrl (
    input  logic       valid_i,
    input  logic [5:0] op_i,
    input  logic       busy_div,
    output logic       fma_clk_en,
    output logic       div_clk_en,
    output logic       cvt_clk_en,
    output logic       ncomp_clk_en
);
    (* anyseq *) logic f_fma, f_div, f_cvt, f_ncomp;
    assign fma_clk_en   = f_fma;
    assign div_clk_en   = f_div;
    assign cvt_clk_en   = f_cvt;
    assign ncomp_clk_en = f_ncomp;
endmodule
