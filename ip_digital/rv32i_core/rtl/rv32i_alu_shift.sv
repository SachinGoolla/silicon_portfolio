// rv32i_alu_shift.sv — SLL/SRL/SRA. See rv32i_alu.sv's header for why this
// is a separate file rather than a case-branch in one monolithic ALU —
// this is also the group that exposed a confirmed Yosys bug: a $signed()
// cast written directly inside an assert() argument is silently dropped
// during elaboration (verified via the generated netlist: the RTL's own
// $signed(a_i)>>>shamt lowers correctly to $sshr, but the identical text
// inside assert(result_o == ($signed(a_i)>>>shamt)) lowers to a plain,
// unsigned a_i>>>shamt instead — a false counterexample that a direct
// Icarus simulation of the same inputs does not reproduce). Fixed by
// computing the $signed() reference through an external signed wire,
// declared outside the assert, where the cast is honored correctly.
`timescale 1ns/1ps

module rv32i_alu_shift (
    input  logic [31:0] a_i,
    input  logic [31:0] b_i,
    input  logic [1:0]  op_i,   // 0=SLL, 1=SRL, 2=SRA
    output logic [31:0] result_o
);

    wire [4:0] shamt = b_i[4:0];

    /* verilator lint_off UNUSEDSIGNAL */
    // Only the low 5 bits of b_i (the shift amount) are meaningful here.
    wire _unused = ^b_i[31:5];
    /* verilator lint_on UNUSEDSIGNAL */

    always_comb begin
        unique case (op_i)
            2'd0: result_o = a_i << shamt;
            2'd1: result_o = a_i >> shamt;
            2'd2: result_o = $signed(a_i) >>> shamt;
            default: result_o = 32'd0;
        endcase
    end

`ifdef FORMAL
    logic signed [31:0] sra_ref;
    assign sra_ref = $signed(a_i) >>> shamt;

    always_comb begin
        if (op_i == 2'd0) assert(result_o == (a_i << shamt));
        if (op_i == 2'd1) assert(result_o == (a_i >> shamt));
        if (op_i == 2'd2) assert(result_o == sra_ref);
    end

    always_comb cover(op_i == 2'd2 && a_i[31]);  // negative-operand SRA reachable
`endif

endmodule
