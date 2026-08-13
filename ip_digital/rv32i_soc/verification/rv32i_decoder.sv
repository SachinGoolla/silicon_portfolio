// rv32i_decoder.sv — RV32I instruction decode: field extraction plus a
// thin composition of rv32i_imm_gen (immediate generation, formally
// verified standalone) and rv32i_ctrl_decode (ALU-op select + pipeline
// control signals, functional-test verified — see that file's header for
// why). Originally one monolithic module; split for the same reason as
// rv32i_alu.sv — the combined case-statement complexity hung z3 in the
// presat check regardless of which specific properties were being
// checked, even after every wide-equality-in-assert pathology this same
// debugging pass found elsewhere was already fixed.
`timescale 1ns/1ps

module rv32i_decoder (
    input  logic [31:0] instr_i,

    output logic [4:0]  rs1_addr_o,
    output logic [4:0]  rs2_addr_o,
    output logic [4:0]  rd_addr_o,
    output logic [31:0] imm_o,
    output logic [2:0]  funct3_o,

    output logic [3:0]  alu_op_o,
    output logic [1:0]  alu_src_a_o,
    output logic        alu_src_b_o,

    output logic        reg_write_o,
    output logic        mem_read_o,
    output logic        mem_write_o,
    output logic [1:0]  mem_width_o,
    output logic        mem_unsigned_o,

    output logic        branch_o,
    output logic        jump_o,
    output logic        jalr_o,
    output logic [1:0]  result_src_o,

    output logic        illegal_o
);

    assign rs1_addr_o = instr_i[19:15];
    assign rs2_addr_o = instr_i[24:20];
    assign rd_addr_o  = instr_i[11:7];
    assign funct3_o   = instr_i[14:12];

    rv32i_imm_gen u_imm_gen (
        .instr_i (instr_i),
        .imm_o   (imm_o)
    );

    rv32i_ctrl_decode u_ctrl (
        .opcode_i       (instr_i[6:0]),
        .funct3_i       (instr_i[14:12]),
        .funct7b5_i     (instr_i[30]),
        .alu_op_o       (alu_op_o),
        .alu_src_a_o    (alu_src_a_o),
        .alu_src_b_o    (alu_src_b_o),
        .reg_write_o    (reg_write_o),
        .mem_read_o     (mem_read_o),
        .mem_write_o    (mem_write_o),
        .mem_width_o    (mem_width_o),
        .mem_unsigned_o (mem_unsigned_o),
        .branch_o       (branch_o),
        .jump_o         (jump_o),
        .jalr_o         (jalr_o),
        .result_src_o   (result_src_o),
        .illegal_o      (illegal_o)
    );

endmodule
