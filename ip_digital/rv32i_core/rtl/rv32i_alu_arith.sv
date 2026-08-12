// rv32i_alu_arith.sv — ADD/SUB. Split out of a single monolithic ALU (see
// rv32i_alu.sv's header) because a combined 10-op ALU proof hung z3 in the
// presat check regardless of how many properties were actually asserted —
// the full case statement's parallel result candidates (especially the
// three barrel shifters) were part of the model either way. Splitting by
// FILE, not just by ifdef-guarded property, is what actually shrinks the
// circuit each proof has to reason about.
`timescale 1ns/1ps

module rv32i_alu_arith (
    input  logic [31:0] a_i,
    input  logic [31:0] b_i,
    input  logic        sub_i,   // 0=ADD, 1=SUB
    output logic [31:0] result_o
);

    assign result_o = sub_i ? (a_i - b_i) : (a_i + b_i);

`ifdef FORMAL
    always_comb begin
        if (!sub_i) assert(result_o == a_i + b_i);
        if (sub_i)  assert(result_o == a_i - b_i);
    end
`endif

endmodule
