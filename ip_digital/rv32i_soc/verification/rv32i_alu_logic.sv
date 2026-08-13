// rv32i_alu_logic.sv — AND/OR/XOR. See rv32i_alu.sv's header for why this
// is a separate file rather than a case-branch in one monolithic ALU.
`timescale 1ns/1ps

module rv32i_alu_logic (
    input  logic [31:0] a_i,
    input  logic [31:0] b_i,
    input  logic [1:0]  op_i,   // 0=AND, 1=OR, 2=XOR
    output logic [31:0] result_o
);

    always_comb begin
        unique case (op_i)
            2'd0: result_o = a_i & b_i;
            2'd1: result_o = a_i | b_i;
            2'd2: result_o = a_i ^ b_i;
            default: result_o = 32'd0;
        endcase
    end

`ifdef FORMAL
    always_comb begin
        if (op_i == 2'd0) assert(result_o == (a_i & b_i));
        if (op_i == 2'd1) assert(result_o == (a_i | b_i));
        if (op_i == 2'd2) assert(result_o == (a_i ^ b_i));
    end
`endif

endmodule
