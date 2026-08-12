// rv32i_alu.sv — RV32I integer ALU: a thin result mux composing four
// independently-verified op-group units (rv32i_alu_arith/_logic/_shift/
// _compare). Reused for branch-condition evaluation in EX, not just
// arithmetic: BEQ/BNE read `zero_o` off an ALU_SUB; BLT/BGE/BLTU/BGEU read
// the low bit of an ALU_SLT/ALU_SLTU result. This avoids a second
// comparator block — standard RISC-V 5-stage pipeline design.
//
// Originally one monolithic case statement (10 ops, one always_comb). Its
// formal proof hung z3 in the presat check for minutes with zero progress,
// regardless of which properties were actually being asserted -- Yosys's
// case-to-mux lowering computes every op's result as a parallel
// combinational path feeding one final select, so the full circuit
// (including all three barrel shifters) was part of the model even when
// only checking, say, ADD/SUB. Splitting into four small per-group MODULES
// (not just four ifdef-guarded property groups on the same big module) is
// what actually shrinks each proof's circuit -- confirmed by measurement,
// not assumption: the ifdef-only split still hung identically.
`timescale 1ns/1ps

module rv32i_alu (
    input  logic [31:0] a_i,
    input  logic [31:0] b_i,
    input  logic [3:0]  alu_op_i,
    output logic [31:0] result_o,
    output logic         zero_o
);

    localparam logic [3:0] ALU_ADD  = 4'h0;
    localparam logic [3:0] ALU_SUB  = 4'h1;
    localparam logic [3:0] ALU_AND  = 4'h2;
    localparam logic [3:0] ALU_OR   = 4'h3;
    localparam logic [3:0] ALU_XOR  = 4'h4;
    localparam logic [3:0] ALU_SLL  = 4'h5;
    localparam logic [3:0] ALU_SRL  = 4'h6;
    localparam logic [3:0] ALU_SRA  = 4'h7;
    localparam logic [3:0] ALU_SLT  = 4'h8;
    localparam logic [3:0] ALU_SLTU = 4'h9;

    logic [31:0] arith_result, logic_result, shift_result, compare_result;

    rv32i_alu_arith u_arith (
        .a_i (a_i), .b_i (b_i),
        .sub_i (alu_op_i == ALU_SUB),
        .result_o (arith_result)
    );

    rv32i_alu_logic u_logic (
        .a_i (a_i), .b_i (b_i),
        .op_i ((alu_op_i == ALU_OR) ? 2'd1 : (alu_op_i == ALU_XOR) ? 2'd2 : 2'd0),
        .result_o (logic_result)
    );

    rv32i_alu_shift u_shift (
        .a_i (a_i), .b_i (b_i),
        .op_i ((alu_op_i == ALU_SRL) ? 2'd1 : (alu_op_i == ALU_SRA) ? 2'd2 : 2'd0),
        .result_o (shift_result)
    );

    rv32i_alu_compare u_compare (
        .a_i (a_i), .b_i (b_i),
        .sltu_i (alu_op_i == ALU_SLTU),
        .result_o (compare_result)
    );

    always_comb begin
        unique case (alu_op_i)
            ALU_ADD,  ALU_SUB:               result_o = arith_result;
            ALU_AND,  ALU_OR,   ALU_XOR:      result_o = logic_result;
            ALU_SLL,  ALU_SRL,  ALU_SRA:      result_o = shift_result;
            ALU_SLT,  ALU_SLTU:               result_o = compare_result;
            default:                          result_o = 32'd0;
        endcase
    end

    assign zero_o = (result_o == 32'd0);

    // -----------------------------------------------------------------
    // Formal verification — mux correctness only. u_arith/u_logic/
    // u_shift/u_compare are already independently signed off by their own
    // standalone proofs (rv32i_alu_arith.sby etc.) — anyseq-stubbed here
    // (rv32i_alu_formal_stub.sv) so this proof stays small, the same
    // cone-of-influence discipline fpu_axi_periph/fpu_top established.
    // -----------------------------------------------------------------
`ifdef FORMAL
    always_comb begin
        if (alu_op_i == ALU_ADD  || alu_op_i == ALU_SUB)  assert(result_o == arith_result);
        if (alu_op_i == ALU_AND  || alu_op_i == ALU_OR || alu_op_i == ALU_XOR)
            assert(result_o == logic_result);
        if (alu_op_i == ALU_SLL  || alu_op_i == ALU_SRL || alu_op_i == ALU_SRA)
            assert(result_o == shift_result);
        if (alu_op_i == ALU_SLT  || alu_op_i == ALU_SLTU) assert(result_o == compare_result);
        assert(zero_o == (result_o == 32'd0));
    end
`endif

endmodule
