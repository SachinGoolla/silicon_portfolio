// =============================================================================
// fpu_cvt.sv — FCVT / FMV Conversion Unit  (2-stage pipeline)
// =============================================================================
// op_i[3:0] sub-opcodes (op_i[5:4] == 2'b10):
//   4'h0  FCVT.W.S    FP32 → signed int32     → int_result_o
//   4'h1  FCVT.WU.S   FP32 → unsigned int32   → int_result_o
//   4'h2  FCVT.S.W    signed int32 → FP32     → result_o
//   4'h3  FCVT.S.WU   unsigned int32 → FP32   → result_o
//   4'h4  FMV.X.W     FP32 bits → int (copy)  → int_result_o
//   4'h5  FMV.W.X     int bits → FP32 (copy)  → result_o
// Latency: 2 registered cycles.
// Pipeline: stage 1 captures inputs + tree-LZC; stage 2 computes result.
// FP→int rounding: truncation (RTZ).  int→FP32 rounding: honours rm_i.
// =============================================================================

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

    // =========================================================================
    // STAGE-1 COMBINATIONAL: sign/magnitude and tree-LZC for int→FP path
    // =========================================================================
    logic        s1_i2f_sign;
    logic [31:0] s1_i2f_mag;

    always_comb begin
        if (op_i == 4'h2) begin
            s1_i2f_sign = int_src_i[31];
            s1_i2f_mag  = int_src_i[31] ? (~int_src_i + 32'd1) : int_src_i;
        end else begin
            s1_i2f_sign = 1'b0;
            s1_i2f_mag  = int_src_i;
        end
    end

    // =========================================================================
    // Balanced binary tree LZC (4 levels, synthesises to ~4 gate levels)
    // =========================================================================
    logic       g7_any, g6_any, g5_any, g4_any, g3_any, g2_any, g1_any;
    logic [1:0] g7_lzc, g6_lzc, g5_lzc, g4_lzc, g3_lzc, g2_lzc, g1_lzc, g0_lzc;
    logic       p3_any, p2_any, p1_any;
    logic [2:0] p3_lzc, p2_lzc, p1_lzc, p0_lzc;
    logic       q1_any;
    logic [3:0] q1_lzc, q0_lzc;
    logic [4:0] s1_i2f_lzc;

    always_comb begin
        // Level 1 — four bits each
        g7_any = |s1_i2f_mag[31:28];
        g7_lzc = s1_i2f_mag[31] ? 2'd0 : s1_i2f_mag[30] ? 2'd1 : s1_i2f_mag[29] ? 2'd2 : 2'd3;
        g6_any = |s1_i2f_mag[27:24];
        g6_lzc = s1_i2f_mag[27] ? 2'd0 : s1_i2f_mag[26] ? 2'd1 : s1_i2f_mag[25] ? 2'd2 : 2'd3;
        g5_any = |s1_i2f_mag[23:20];
        g5_lzc = s1_i2f_mag[23] ? 2'd0 : s1_i2f_mag[22] ? 2'd1 : s1_i2f_mag[21] ? 2'd2 : 2'd3;
        g4_any = |s1_i2f_mag[19:16];
        g4_lzc = s1_i2f_mag[19] ? 2'd0 : s1_i2f_mag[18] ? 2'd1 : s1_i2f_mag[17] ? 2'd2 : 2'd3;
        g3_any = |s1_i2f_mag[15:12];
        g3_lzc = s1_i2f_mag[15] ? 2'd0 : s1_i2f_mag[14] ? 2'd1 : s1_i2f_mag[13] ? 2'd2 : 2'd3;
        g2_any = |s1_i2f_mag[11:8];
        g2_lzc = s1_i2f_mag[11] ? 2'd0 : s1_i2f_mag[10] ? 2'd1 : s1_i2f_mag[9]  ? 2'd2 : 2'd3;
        g1_any = |s1_i2f_mag[7:4];
        g1_lzc = s1_i2f_mag[7]  ? 2'd0 : s1_i2f_mag[6]  ? 2'd1 : s1_i2f_mag[5]  ? 2'd2 : 2'd3;
        g0_lzc = s1_i2f_mag[3]  ? 2'd0 : s1_i2f_mag[2]  ? 2'd1 : s1_i2f_mag[1]  ? 2'd2 : 2'd3;

        // Level 2 — combine pairs of 4-bit groups
        p3_any = g7_any | g6_any;  p3_lzc = g7_any ? {1'b0, g7_lzc} : {1'b1, g6_lzc};
        p2_any = g5_any | g4_any;  p2_lzc = g5_any ? {1'b0, g5_lzc} : {1'b1, g4_lzc};
        p1_any = g3_any | g2_any;  p1_lzc = g3_any ? {1'b0, g3_lzc} : {1'b1, g2_lzc};
                                    p0_lzc = g1_any ? {1'b0, g1_lzc} : {1'b1, g0_lzc};

        // Level 3 — combine into 16-bit halves
        q1_any = p3_any | p2_any;  q1_lzc = p3_any ? {1'b0, p3_lzc} : {1'b1, p2_lzc};
                                    q0_lzc = p1_any ? {1'b0, p1_lzc} : {1'b1, p0_lzc};

        // Level 4 — 32-bit result
        s1_i2f_lzc = q1_any ? {1'b0, q1_lzc} : {1'b1, q0_lzc};
    end

    // =========================================================================
    // STAGE-1 PIPELINE REGISTER
    // =========================================================================
    logic        p1_valid;
    logic [3:0]  p1_op;
    logic [2:0]  p1_rm;
    logic [31:0] p1_src_a;      // for FP→int and FMV.X.W
    logic [31:0] p1_int_src;    // raw integer bits for FMV.W.X
    logic        p1_i2f_sign;
    logic [31:0] p1_i2f_mag;
    logic [4:0]  p1_i2f_msb;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            p1_valid    <= 1'b0;
            p1_op       <= 4'h0;
            p1_rm       <= 3'h0;
            p1_src_a    <= '0;
            p1_int_src  <= '0;
            p1_i2f_sign <= 1'b0;
            p1_i2f_mag  <= '0;

            p1_i2f_msb  <= 5'h0;
        end else begin
            p1_valid    <= valid_i;
            p1_op       <= op_i;
            p1_rm       <= rm_i;
            p1_src_a    <= src_a_i;
            p1_int_src  <= int_src_i;
            p1_i2f_sign <= s1_i2f_sign;
            p1_i2f_mag  <= s1_i2f_mag;
            p1_i2f_msb  <= 5'd31 - s1_i2f_lzc;
        end
    end

    // =========================================================================
    // STAGE-2 COMBINATIONAL: FP32 field extraction from registered p1_src_a
    // =========================================================================
    logic        p1_fp_sign;
    logic [7:0]  p1_fp_exp;
    logic [22:0] p1_fp_mant;
    assign p1_fp_sign = p1_src_a[31];
    assign p1_fp_exp  = p1_src_a[30:23];
    assign p1_fp_mant = p1_src_a[22:0];

    logic p1_fp_is_nan, p1_fp_is_inf, p1_fp_is_zero;
    assign p1_fp_is_nan  = (p1_fp_exp == 8'hFF) & (p1_fp_mant != 23'h0);
    assign p1_fp_is_inf  = (p1_fp_exp == 8'hFF) & (p1_fp_mant == 23'h0);
    assign p1_fp_is_zero = (p1_fp_exp == 8'h00) & (p1_fp_mant == 23'h0);

    // =========================================================================
    // FP32 → integer magnitude (truncate toward zero), stage 2
    // =========================================================================
    logic [23:0] p1_fp24;
    assign p1_fp24 = {1'b1, p1_fp_mant};

    logic [31:0] int_mag;
    logic        int_mag_nx;
    logic [7:0]  fp_rsh;
    assign fp_rsh = 8'd150 - p1_fp_exp;

    always_comb begin
        int_mag    = 32'h0;
        int_mag_nx = 1'b0;
        if (p1_fp_exp >= 8'd150) begin
            int_mag = 32'(p1_fp24) << (p1_fp_exp - 8'd150);
        end else if (p1_fp_exp >= 8'd127) begin
            int_mag    = 32'(p1_fp24) >> fp_rsh;
            int_mag_nx = |(p1_fp24 & ((24'h1 << fp_rsh) - 24'h1));
        end else if (!p1_fp_is_zero) begin
            int_mag_nx = 1'b1;
        end
    end

    // =========================================================================
    // integer → FP32 (FCVT.S.W / FCVT.S.WU), stage 2
    // Uses p1_i2f_mag and p1_i2f_msb already registered in stage 1.
    // Only the barrel-shift + round path remains here — no LZC on critical path.
    // =========================================================================
    /* verilator lint_off UNUSEDSIGNAL */
    logic [23:0] i2f_shifted;   // bit[23]=leading 1 (structurally always 1 post-shift); frac=[22:0]
    /* verilator lint_on UNUSEDSIGNAL */
    logic [7:0]  i2f_exp;
    logic [22:0] i2f_frac;
    logic [4:0]  i2f_gpos;
    logic        i2f_guard, i2f_round, i2f_sticky, i2f_round_up, i2f_nx;
    logic [23:0] i2f_mant_sum;
    logic [31:0] i2f_result;

    always_comb begin
        i2f_gpos     = 5'd0;
        i2f_shifted  = 24'h0;
        i2f_exp      = 8'h0;
        i2f_frac     = 23'h0;
        i2f_guard    = 1'b0;
        i2f_round    = 1'b0;
        i2f_sticky   = 1'b0;
        i2f_round_up = 1'b0;
        i2f_mant_sum = 24'h0;
        i2f_result   = 32'h0;
        i2f_nx       = 1'b0;

        if (p1_i2f_mag != 32'h0) begin
            i2f_exp = 8'(p1_i2f_msb) + 8'd127;

            if (p1_i2f_msb >= 5'd23) begin
                i2f_shifted = 24'(p1_i2f_mag >> (p1_i2f_msb - 5'd23));
                i2f_frac    = i2f_shifted[22:0];
                if (p1_i2f_msb >= 5'd24) begin
                    i2f_gpos   = p1_i2f_msb - 5'd24;
                    i2f_guard  = p1_i2f_mag[i2f_gpos];
                    i2f_round  = (i2f_gpos > 5'd0) ? p1_i2f_mag[i2f_gpos - 5'd1] : 1'b0;
                    i2f_sticky = (i2f_gpos > 5'd0) ?
                                 |(p1_i2f_mag & ((32'h1 << (i2f_gpos - 5'd1)) - 32'h1)) : 1'b0;
                end
            end else begin
                i2f_shifted = 24'(p1_i2f_mag << (5'd23 - p1_i2f_msb));
                i2f_frac    = i2f_shifted[22:0];
            end

            i2f_nx = i2f_guard | i2f_round | i2f_sticky;

            unique case (p1_rm)
                3'b000: i2f_round_up = i2f_guard & (i2f_round | i2f_sticky | i2f_frac[0]);
                3'b001: i2f_round_up = 1'b0;
                3'b010: i2f_round_up = i2f_nx &  p1_i2f_sign;
                3'b011: i2f_round_up = i2f_nx & ~p1_i2f_sign;
                default: i2f_round_up = i2f_guard;
            endcase

            i2f_mant_sum = {1'b0, i2f_frac} + 24'(i2f_round_up);
            i2f_result   = i2f_mant_sum[23]
                           ? {p1_i2f_sign, i2f_exp + 8'd1, 23'h0}
                           : {p1_i2f_sign, i2f_exp,         i2f_mant_sum[22:0]};
        end
    end

    // =========================================================================
    // Stage-2 output mux (operates on p1_* registered values)
    // =========================================================================
    logic [FLEN-1:0]  c_result;
    logic [XLEN-1:0]  c_int_result;
    logic [4:0]       c_fflags;

    always_comb begin
        c_result     = '0;
        c_int_result = '0;
        c_fflags     = 5'b0;

        unique case (p1_op)
            4'h0: begin  // FCVT.W.S — FP32 → signed int32
                if (p1_fp_is_nan || (!p1_fp_sign && p1_fp_exp >= 8'd158)) begin
                    c_int_result = 32'h7FFF_FFFF; c_fflags = 5'b1_0000;
                end else if (p1_fp_is_inf) begin
                    c_int_result = p1_fp_sign ? 32'h8000_0000 : 32'h7FFF_FFFF;
                    c_fflags = 5'b1_0000;
                end else if (p1_fp_sign && p1_fp_exp == 8'd158 && p1_fp_mant == 23'h0) begin
                    c_int_result = 32'h8000_0000;  // exactly −2^31, no NV
                end else if (p1_fp_sign && p1_fp_exp >= 8'd158) begin
                    c_int_result = 32'h8000_0000; c_fflags = 5'b1_0000;
                end else begin
                    c_int_result = p1_fp_sign ? (~int_mag + 32'd1) : int_mag;
                    c_fflags     = {4'b0, int_mag_nx};
                end
            end
            4'h1: begin  // FCVT.WU.S — FP32 → unsigned int32
                if (p1_fp_is_nan || (!p1_fp_sign && p1_fp_exp >= 8'd159)) begin
                    c_int_result = 32'hFFFF_FFFF; c_fflags = 5'b1_0000;
                end else if (p1_fp_sign && !p1_fp_is_zero) begin
                    c_int_result = 32'h0; c_fflags = 5'b1_0000;
                end else begin
                    c_int_result = int_mag; c_fflags = {4'b0, int_mag_nx};
                end
            end
            4'h2, 4'h3: begin  // FCVT.S.W / FCVT.S.WU
                c_result = i2f_result; c_fflags = {4'b0, i2f_nx};
            end
            4'h4: begin  // FMV.X.W
                c_int_result = XLEN'(p1_src_a);
            end
            4'h5: begin  // FMV.W.X
                c_result = FLEN'(p1_int_src);
            end
            default: begin end
        endcase
    end

    // =========================================================================
    // Stage-2 output register
    // =========================================================================
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            valid_o      <= 1'b0;
            result_o     <= '0;
            int_result_o <= '0;
            fflags_o     <= 5'b0;
        end else begin
            valid_o      <= p1_valid;
            result_o     <= c_result;
            int_result_o <= c_int_result;
            fflags_o     <= c_fflags;
        end
    end

endmodule
