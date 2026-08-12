// rv32i_alu_formal_stub.sv — free (anyseq) stand-ins for
// rv32i_alu_arith/_logic/_shift/_compare, used ONLY by rv32i_alu's own
// (top-level mux) formal proof. All four are already signed off standalone
// by their own proofs (rv32i_alu_arith.sby etc.) — this proof checks only
// the result-select mux, following fpu_axi_periph_formal_stub.sv's
// pattern (anyseq, not blackbox — the SMT2 backend rejects blackbox
// modules outright).

module rv32i_alu_arith (
    input  logic [31:0] a_i,
    input  logic [31:0] b_i,
    input  logic        sub_i,
    output logic [31:0] result_o
);
    (* anyseq *) logic [31:0] f_result;
    assign result_o = f_result;
endmodule

module rv32i_alu_logic (
    input  logic [31:0] a_i,
    input  logic [31:0] b_i,
    input  logic [1:0]  op_i,
    output logic [31:0] result_o
);
    (* anyseq *) logic [31:0] f_result;
    assign result_o = f_result;
endmodule

module rv32i_alu_shift (
    input  logic [31:0] a_i,
    input  logic [31:0] b_i,
    input  logic [1:0]  op_i,
    output logic [31:0] result_o
);
    (* anyseq *) logic [31:0] f_result;
    assign result_o = f_result;
endmodule

module rv32i_alu_compare (
    input  logic [31:0] a_i,
    input  logic [31:0] b_i,
    input  logic        sltu_i,
    output logic [31:0] result_o
);
    (* anyseq *) logic [31:0] f_result;
    assign result_o = f_result;
endmodule
