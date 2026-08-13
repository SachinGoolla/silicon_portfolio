// rv32i_ctrl_decode.sv — RV32I ALU-op select + pipeline control signals.
// Pure combinational. Split out of rv32i_decoder.sv for the same reason
// as rv32i_imm_gen.sv (see that file's header) — keeping each formally-
// verified piece small enough for this toolchain to actually solve.
//
// Full opcode-space control-signal correctness is deliberately a
// functional-test concern (cocotb), exercised directly rather than
// exhaustively formalized — the same "formal proves structure, tests
// prove full coverage" boundary already established for the ALU/regfile
// in this core and for fpu_top's arithmetic elsewhere in this portfolio.
// rv32i_imm_gen.sv carries this module's formal budget for that reason.
// One narrow structural property IS formally proven here (see the
// FORMAL block below): mem_read_o and branch_o/jump_o are mutually
// exclusive. rv32i_core.sv's pipeline registers depend on this exact
// invariant to keep a load-use bubble and a control-hazard flush from
// ever needing to co-fire on the same instruction — found to be an
// unformalized assumption by a composition-level review, worth proving
// directly at its actual source rather than leaving it implicit.
//
// Reuses rv32i_alu for branch-condition evaluation (see rv32i_alu.sv's
// header): BEQ/BNE decode to ALU_SUB (EX stage reads zero_o); BLT/BGE to
// ALU_SLT; BLTU/BGEU to ALU_SLTU. This module only decodes which ALU op;
// the EX stage/hazard_unit applies the branch's polarity from funct3_o
// (funct3[0]=1 means "invert" — BNE/BGE/BGEU are the inverted forms of
// BEQ/BLT/BLTU respectively, a direct RV32I encoding property).
//
// LUI/AUIPC are folded into the normal ALU_ADD datapath rather than given
// their own result-source case: LUI is ADD(0, imm), AUIPC is ADD(pc, imm)
// — see alu_src_a_o's ASRC_A_ZERO/ASRC_A_PC encoding below.
`timescale 1ns/1ps

module rv32i_ctrl_decode (
    input  logic [6:0]  opcode_i,
    input  logic [2:0]  funct3_i,
    input  logic         funct7b5_i,

    output logic [3:0]  alu_op_o,
    output logic [1:0]  alu_src_a_o,   // 00=rs1  01=pc  10=zero
    output logic        alu_src_b_o,   // 0=rs2   1=imm

    output logic        reg_write_o,
    output logic        mem_read_o,
    output logic        mem_write_o,
    output logic [1:0]  mem_width_o,   // 00=byte 01=half 10=word
    output logic        mem_unsigned_o,

    output logic        branch_o,
    output logic        jump_o,
    output logic        jalr_o,
    output logic [1:0]  result_src_o,  // 00=alu  01=mem  10=pc+4

    output logic        illegal_o
);

    localparam logic [1:0] ASRC_A_RS1  = 2'b00;
    localparam logic [1:0] ASRC_A_PC   = 2'b01;
    localparam logic [1:0] ASRC_A_ZERO = 2'b10;

    localparam logic [1:0] RSRC_ALU = 2'b00;
    localparam logic [1:0] RSRC_MEM = 2'b01;
    localparam logic [1:0] RSRC_PC4 = 2'b10;

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

    localparam logic [6:0] OP_RTYPE  = 7'b0110011;
    localparam logic [6:0] OP_ITYPE  = 7'b0010011;
    localparam logic [6:0] OP_LOAD   = 7'b0000011;
    localparam logic [6:0] OP_STORE  = 7'b0100011;
    localparam logic [6:0] OP_BRANCH = 7'b1100011;
    localparam logic [6:0] OP_JAL    = 7'b1101111;
    localparam logic [6:0] OP_JALR   = 7'b1100111;
    localparam logic [6:0] OP_LUI    = 7'b0110111;
    localparam logic [6:0] OP_AUIPC  = 7'b0010111;

    wire is_alu_rtype = (opcode_i == OP_RTYPE);
    wire [1:0] branch_cmp_grp = funct3_i[2:1];

    // ALU op select — funct3 picks the base op; funct7b5_i disambiguates
    // ADD/SUB and SRL/SRA, meaningful only when funct3 is 000 or 101, and
    // only for R-type (I-type ADDI has no SUBI; I-type SRLI/SRAI reuse
    // instr[30] the same way R-type does, by RV32I spec construction).
    always_comb begin
        unique case (funct3_i)
            3'b000:  alu_op_o = (is_alu_rtype && funct7b5_i) ? ALU_SUB : ALU_ADD;
            3'b001:  alu_op_o = ALU_SLL;
            3'b010:  alu_op_o = ALU_SLT;
            3'b011:  alu_op_o = ALU_SLTU;
            3'b100:  alu_op_o = ALU_XOR;
            3'b101:  alu_op_o = funct7b5_i ? ALU_SRA : ALU_SRL;
            3'b110:  alu_op_o = ALU_OR;
            3'b111:  alu_op_o = ALU_AND;
            default: alu_op_o = ALU_ADD;
        endcase
        // Non-R/I-type ALU users override to a fixed op regardless of
        // funct3 (which encodes something else entirely for them, e.g.
        // branch condition or load/store width).
        unique case (opcode_i)
            OP_LOAD, OP_STORE, OP_JALR, OP_JAL:
                alu_op_o = ALU_ADD;            // address = base + offset
            OP_LUI, OP_AUIPC:
                alu_op_o = ALU_ADD;            // result = src_a + imm
            OP_BRANCH: begin
                // Icarus rejects a part-select used directly as a case
                // expression ("constant selects in always_* processes are
                // not currently supported (all bits will be included)") --
                // an explicit intermediate signal avoids it.
                unique case (branch_cmp_grp)   // ignore funct3[0] (polarity)
                    2'b00:   alu_op_o = ALU_SUB;   // BEQ/BNE -> zero_o
                    2'b10:   alu_op_o = ALU_SLT;   // BLT/BGE
                    2'b11:   alu_op_o = ALU_SLTU;  // BLTU/BGEU
                    default: alu_op_o = ALU_SUB;
                endcase
            end
            default: ;  // R-type/I-type-ALU: keep the funct3-derived alu_op_o above
        endcase
    end

    assign alu_src_a_o = (opcode_i == OP_AUIPC) ? ASRC_A_PC :
                          (opcode_i == OP_LUI)  ? ASRC_A_ZERO :
                                                   ASRC_A_RS1;

    assign alu_src_b_o = !(opcode_i == OP_RTYPE || opcode_i == OP_BRANCH);

    assign mem_width_o    = funct3_i[1:0];
    assign mem_unsigned_o = funct3_i[2];

    always_comb begin
        reg_write_o  = 1'b0;
        mem_read_o   = 1'b0;
        mem_write_o  = 1'b0;
        branch_o     = 1'b0;
        jump_o       = 1'b0;
        jalr_o       = 1'b0;
        result_src_o = RSRC_ALU;
        illegal_o    = 1'b0;
        unique case (opcode_i)
            OP_RTYPE:  reg_write_o = 1'b1;
            OP_ITYPE:  reg_write_o = 1'b1;
            OP_LOAD:   begin reg_write_o = 1'b1; mem_read_o  = 1'b1; result_src_o = RSRC_MEM; end
            OP_STORE:  mem_write_o = 1'b1;
            OP_BRANCH: branch_o = 1'b1;
            OP_JAL:    begin reg_write_o = 1'b1; jump_o = 1'b1; result_src_o = RSRC_PC4; end
            OP_JALR:   begin reg_write_o = 1'b1; jump_o = 1'b1; jalr_o = 1'b1; result_src_o = RSRC_PC4; end
            OP_LUI:    reg_write_o = 1'b1;
            OP_AUIPC:  reg_write_o = 1'b1;
            default:   illegal_o = 1'b1;
        endcase
    end

    // -----------------------------------------------------------------
    // Formal verification. This module was previously the one place in
    // the core relying on an UNSTATED invariant: rv32i_core.sv's pipeline
    // registers assume a single id_ex-stage instruction can never be
    // BOTH a load (mem_read_o) and a branch/jump (branch_o/jump_o) --
    // if it could, a load-use bubble and a control-hazard flush could
    // fire on the same instruction the same cycle, and the IF/ID
    // register's flush-checked-before-stall priority would silently
    // drop the branch/jump redirect (flush wins, but flush only clears
    // if_id_instr_q, not pc_q -- see rv32i_core.sv's header). A
    // multi-agent adversarial review of the composition RTL confirmed
    // this exact mechanism is real IF the precondition is reachable, but
    // unanimously refuted it as a live bug because the case statement
    // above structurally can't produce it: every case arm sets at most
    // one of {mem_read_o} or {branch_o, jump_o}, never both, and the
    // block's own zero-initialization covers every unmapped/illegal
    // opcode. That argument lived only in review notes, not in the RTL
    // -- asserted directly here so a future edit that breaks it (a merge
    // conflict duplicating a case item, a new opcode folded in
    // carelessly) is caught immediately, at the one place that actually
    // enforces it, rather than relying on a downstream property that
    // can never fire today and so can never fail today either.
`ifdef FORMAL
    always_comb begin
        assert(!(mem_read_o && (branch_o || jump_o)));
    end
`endif

endmodule
