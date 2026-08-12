// rv32i_alu_compare.sv — SLT/SLTU. See rv32i_alu.sv's header for why this
// is a separate file rather than a case-branch in one monolithic ALU. Also
// affected by the $signed()-in-assert Yosys bug documented in
// rv32i_alu_shift.sv — SLT needs a signed comparison, fixed the same way
// (external signed reference wires, not an inline $signed() in the assert).
`timescale 1ns/1ps

module rv32i_alu_compare (
    input  logic [31:0] a_i,
    input  logic [31:0] b_i,
    input  logic         sltu_i,   // 0=SLT (signed), 1=SLTU (unsigned)
    output logic [31:0] result_o
);

    assign result_o = sltu_i ? {31'd0, a_i < b_i}
                              : {31'd0, $signed(a_i) < $signed(b_i)};

`ifdef FORMAL
    logic signed [31:0] a_s, b_s;
    assign a_s = $signed(a_i);
    assign b_s = $signed(b_i);

    always_comb begin
        if (!sltu_i) assert(result_o == {31'd0, a_s < b_s});
        if (sltu_i)  assert(result_o == {31'd0, a_i < b_i});
    end
`endif

endmodule
