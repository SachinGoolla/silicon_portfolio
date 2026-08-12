// rv32i_imm_gen.sv — RV32I immediate generation. Pure combinational.
// Split out of rv32i_decoder.sv (see that file's header) because the
// combined decoder (immediate mux + ALU-op decode + control-signal
// decode, three separate `unique case` blocks in one module) hung z3 in
// the presat check even after every wide-equality-in-assert pathology
// this same debugging pass found was fixed — the case-statement
// complexity itself, not any specific property, was still too much for
// this toolchain to handle in one shot (same lesson as rv32i_alu.sv).
// Isolating just the immediate generator — the highest-value, most
// bug-prone part per the RV32I bit-scrambling risk — keeps this proof
// small and fast on its own.
`timescale 1ns/1ps

module rv32i_imm_gen (
    input  logic [31:0] instr_i,
    output logic [31:0] imm_o
);

    localparam logic [6:0] OP_ITYPE  = 7'b0010011;
    localparam logic [6:0] OP_LOAD   = 7'b0000011;
    localparam logic [6:0] OP_STORE  = 7'b0100011;
    localparam logic [6:0] OP_BRANCH = 7'b1100011;
    localparam logic [6:0] OP_JAL    = 7'b1101111;
    localparam logic [6:0] OP_JALR   = 7'b1100111;
    localparam logic [6:0] OP_LUI    = 7'b0110111;
    localparam logic [6:0] OP_AUIPC  = 7'b0010111;

    wire [6:0] opcode = instr_i[6:0];

    wire [31:0] imm_i = {{20{instr_i[31]}}, instr_i[31:20]};
    wire [31:0] imm_s = {{20{instr_i[31]}}, instr_i[31:25], instr_i[11:7]};
    wire [31:0] imm_b = {{19{instr_i[31]}}, instr_i[31], instr_i[7],
                          instr_i[30:25], instr_i[11:8], 1'b0};
    wire [31:0] imm_u = {instr_i[31:12], 12'd0};
    wire [31:0] imm_j = {{11{instr_i[31]}}, instr_i[31], instr_i[19:12],
                          instr_i[20], instr_i[30:21], 1'b0};

    always_comb begin
        unique case (opcode)
            OP_ITYPE, OP_LOAD, OP_JALR: imm_o = imm_i;
            OP_STORE:                   imm_o = imm_s;
            OP_BRANCH:                  imm_o = imm_b;
            OP_LUI, OP_AUIPC:           imm_o = imm_u;
            OP_JAL:                     imm_o = imm_j;
            default:                    imm_o = 32'd0;
        endcase
    end

    // -----------------------------------------------------------------
    // Formal verification. Structural properties (cheap, high value —
    // catch a scrambled-bit typo directly) plus a handful of
    // representative known-encoding oracle checks, mirroring the
    // hand-encoded-oracle philosophy scripts/rv32i_asm.py will use for
    // the same reason.
    // -----------------------------------------------------------------
`ifdef FORMAL
    // Confirmed via a minimal repro: comparing a wide vector directly
    // against a same-width constant AS THE TOP-LEVEL PROPOSITION INSIDE
    // assert() is pathological for this z3/yosys-smtbmc combination —
    // hung the presat check indefinitely on a 10-cell circuit whose only
    // property was `imm_o[11:0] == 12'd0`, a literal tautology by RTL
    // construction. The logically identical XOR-then-OR-reduce-to-a-
    // single-bit form converges instantly. Used as a macro (not a
    // function — SystemVerilog functions need a fixed argument width;
    // this needs to work at 1/5/7/32 bits alike) for every wide equality
    // below, guard conditions included.
    `define WEQ(a, b) ((|((a) ^ (b))) == 1'b0)

    always_comb begin
        // B-type and J-type immediates are never encoded with bit 0 set.
        if (`WEQ(opcode, OP_BRANCH)) assert(imm_o[0] == 1'b0);
        if (`WEQ(opcode, OP_JAL))    assert(imm_o[0] == 1'b0);

        // U-type immediates never touch the low 12 bits.
        if (`WEQ(opcode, OP_LUI) || `WEQ(opcode, OP_AUIPC)) assert(|imm_o[11:0] == 1'b0);

        // Oracle: ADDI x1, x0, -1  =  0xFFF00093
        if (`WEQ(instr_i, 32'hFFF00093)) assert(`WEQ(imm_o, 32'hFFFFFFFF));

        // Oracle: SW x2, -4(x3)  =  0xFE21AE23 (computed via a small
        // Python cross-check, not hand-derived — an earlier hand-
        // -derivation attempt at this exact encoding got rs1 wrong,
        // precisely the bit-scrambling risk this oracle exists to catch,
        // this time caught in myself rather than the decoder).
        if (`WEQ(instr_i, 32'hFE21AE23)) assert(`WEQ(imm_o, 32'hFFFFFFFC));

        // Oracle: BEQ x1, x2, -8  =  0xFE208CE3
        if (`WEQ(instr_i, 32'hFE208CE3)) assert(`WEQ(imm_o, 32'hFFFFFFF8));

        // Oracle: JAL x1, -4  =  0xFFDFF0EF
        if (`WEQ(instr_i, 32'hFFDFF0EF)) assert(`WEQ(imm_o, 32'hFFFFFFFC));
    end

    `undef WEQ
`endif

endmodule
