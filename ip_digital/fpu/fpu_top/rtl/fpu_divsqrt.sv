// =============================================================================
// fpu_divsqrt.sv — Iterative FDIV / FSQRT
// =============================================================================
// op_i[0]: 0=FDIV (A/B),  1=FSQRT (√A)
//
// FDIV:  restoring binary division, 26 iterations (GRS bits from quotient+rem)
// FSQRT: 2-bits-per-cycle restoring algorithm, 26 iterations
//        input X ∈ [1,2) for even E, [2,4) for odd E
//
// Latency: 30 cycles (1 IDLE→INIT + 1 INIT→ITER + 26 ITER + 1 PACK + 1 DONE)
// busy_o=1 in INIT/ITER/PACK; valid_o=1 one cycle (DONE).
// =============================================================================

module fpu_divsqrt #(
    parameter int FLEN = 32
) (
    input  logic              clk,
    input  logic              rst_n,
    input  logic              valid_i,
    /* verilator lint_off UNUSEDSIGNAL */
    input  logic [3:0]        op_i,   // op_i[0]=FSQRT; op_i[3:1] unused
    /* verilator lint_on UNUSEDSIGNAL */
    input  logic [2:0]        rm_i,
    input  logic [FLEN-1:0]   src_a_i,
    input  logic [FLEN-1:0]   src_b_i,

    output logic              busy_o,
    output logic              valid_o,
    output logic [FLEN-1:0]   result_o,
    output logic [4:0]        fflags_o
);
    // =========================================================================
    // FSM
    // =========================================================================
    typedef enum logic [2:0] {
        S_IDLE = 3'd0, S_INIT = 3'd1, S_ITER = 3'd2,
        S_PACK = 3'd3, S_DONE = 3'd4
    } state_t;
    state_t state;

    localparam int N_ITER = 26;

    logic [4:0] cnt;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) state <= S_IDLE;
        else unique case (state)
            S_IDLE: if (valid_i)                  state <= S_INIT;
            S_INIT:                                state <= S_ITER;
            S_ITER: if (cnt == 5'(N_ITER - 1))    state <= S_PACK;
            S_PACK:                                state <= S_DONE;
            S_DONE:                                state <= S_IDLE;
            default:                               state <= S_IDLE;
        endcase
    end

    assign busy_o  = (state == S_INIT) | (state == S_ITER) | (state == S_PACK);
    assign valid_o = (state == S_DONE);

    // =========================================================================
    // Operand latches
    // =========================================================================
    logic        a_sign, b_sign;
    logic [7:0]  a_exp,  b_exp;
    logic [22:0] a_mant, b_mant;
    logic        a_nan, a_inf, a_zero;
    logic        b_nan, b_inf, b_zero;
    logic        is_sqrt;
    logic [2:0]  rm_r;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            a_sign<=0; b_sign<=0; a_exp<=0; b_exp<=0;
            a_mant<=0; b_mant<=0;
            a_nan<=0; a_inf<=0; a_zero<=0;
            b_nan<=0; b_inf<=0; b_zero<=0;
            is_sqrt<=0; rm_r<=0;
        end else if (state == S_IDLE && valid_i) begin
            a_sign  <= src_a_i[31];
            a_exp   <= src_a_i[30:23];
            a_mant  <= src_a_i[22:0];
            b_sign  <= src_b_i[31];
            b_exp   <= src_b_i[30:23];
            b_mant  <= src_b_i[22:0];
            a_nan   <= (src_a_i[30:23]==8'hFF) & (src_a_i[22:0]!=0);
            a_inf   <= (src_a_i[30:23]==8'hFF) & (src_a_i[22:0]==0);
            a_zero  <= (src_a_i[30:23]==8'h00) & (src_a_i[22:0]==0);
            b_nan   <= (src_b_i[30:23]==8'hFF) & (src_b_i[22:0]!=0);
            b_inf   <= (src_b_i[30:23]==8'hFF) & (src_b_i[22:0]==0);
            b_zero  <= (src_b_i[30:23]==8'h00) & (src_b_i[22:0]==0);
            is_sqrt <= op_i[0];
            rm_r    <= rm_i;
        end
    end

    // =========================================================================
    // FDIV state
    // quo[25] = first bit (hidden); quo[24:2] = fraction; quo[1] = G; quo[0] = R
    // =========================================================================
    logic [26:0] div_rem;       // partial remainder (sign in [26])
    logic [25:0] div_quo;       // quotient accumulator (left-shift, MSB first)
    logic [23:0] div_V;         // latched divisor {1, b_mant}
    logic        div_exp_adj;   // 1 if dividend was doubled for normalisation

    // FDIV combinational INIT
    logic [23:0] div_D, div_V_c;
    assign div_D   = {1'b1, a_mant};
    assign div_V_c = {1'b1, b_mant};
    logic [26:0] div_rem0_norm, div_rem0_nonadj;
    assign div_rem0_nonadj = {3'b0, div_D}     - {3'b0, div_V_c};   // D >= V
    assign div_rem0_norm   = {2'b0, div_D, 1'b0} - {3'b0, div_V_c}; // 2D, D < V

    // FDIV ITER combinational
    logic [26:0] div_rem_sh, div_rem_trial;
    assign div_rem_sh    = {div_rem[25:0], 1'b0};
    assign div_rem_trial = div_rem_sh - {3'b0, div_V};

    // =========================================================================
    // FSQRT state (2-bits-per-cycle restoring algorithm)
    // After 26 iterations: sqrt_q[25]=hidden; [24:2]=frac; [1]=G; [0]=R
    // =========================================================================
    logic [51:0] sqrt_x;   // 52-bit padded input, shifted 2 left each iter
    logic [25:0] sqrt_q;   // accumulated quotient, left-shift, starts 0
    logic [27:0] sqrt_r;   // partial remainder (28 bits for headroom)

    // FSQRT INIT: X25 = 1.mant if E even (a_exp odd), 2*1.mant if E odd (a_exp even)
    // E even (a_exp[0]=1): {0,1,mant} = 2^23 + mant  (value 1.mant)
    // E odd  (a_exp[0]=0): {1,mant,0} = 2^24 + 2*mant (value 2.mant = 2*(1.mant))
    logic [24:0] sqrt_X25;
    assign sqrt_X25 = a_exp[0] ? {2'b01, a_mant} : {1'b1, a_mant, 1'b0};

    // FSQRT ITER combinational
    logic [1:0]  sq_bits;
    logic [27:0] sq_r_new, sq_trial, sq_r_sub;
    assign sq_bits  = sqrt_x[51:50];
    assign sq_r_new = {sqrt_r[25:0], sq_bits};
    assign sq_trial = {sqrt_q, 2'b01};          // 28-bit: sqrt_q*4 + 1
    assign sq_r_sub = sq_r_new - sq_trial;

    // =========================================================================
    // Iteration register block
    // =========================================================================
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cnt<=0; div_rem<=0; div_quo<=0; div_V<=0; div_exp_adj<=0;
            sqrt_x<=0; sqrt_q<=0; sqrt_r<=0;
        end else if (state == S_INIT) begin
            cnt <= 5'd0;
            if (!is_sqrt) begin
                // FDIV init
                div_V       <= div_V_c;
                div_exp_adj <= (div_D < div_V_c) ? 1'b1 : 1'b0;
                div_rem     <= (div_D < div_V_c) ? div_rem0_norm : div_rem0_nonadj;
                div_quo     <= 26'd0;          // MSB-first accumulation; bit 25 = hidden
            end else begin
                // FSQRT init: pad X25 to 52 bits
                sqrt_x   <= {sqrt_X25, 27'b0};
                sqrt_q   <= 26'd0;
                sqrt_r   <= 28'd0;
            end
        end else if (state == S_ITER) begin
            cnt <= cnt + 5'd1;
            if (!is_sqrt) begin
                // FDIV: restoring binary division
                if (!div_rem_trial[26]) begin  // trial >= 0: accept
                    div_rem <= div_rem_trial;
                    div_quo <= {div_quo[24:0], 1'b1};
                end else begin
                    div_rem <= div_rem_sh;
                    div_quo <= {div_quo[24:0], 1'b0};
                end
            end else begin
                // FSQRT: 2-bits-per-cycle restoring
                if (!sq_r_sub[27]) begin       // trial fits: accept
                    sqrt_r <= sq_r_sub;
                    sqrt_q <= {sqrt_q[24:0], 1'b1};
                end else begin
                    sqrt_r <= sq_r_new;
                    sqrt_q <= {sqrt_q[24:0], 1'b0};
                end
                sqrt_x <= {sqrt_x[49:0], 2'b0};   // shift next 2 bits into window
            end
        end
    end

    // =========================================================================
    // PACK: combinational result assembly
    //
    // After 26 left-shift iterations from quo=0:
    //   [25] = 1st produced bit  (hidden bit, always 1 for normalised result)
    //   [24:3] = fraction[22:1]  (22 bits)
    //   [2]  = fraction[0]
    //   [1]  = guard
    //   [0]  = round
    //   sticky from residual rem/r
    //
    // Wait — 26 bits MSB-first in a 26-bit register: [25..0] where [25]=first bit,
    // [0]=last bit.  fraction = [25:3] (23 bits), G=[2], R=[1], extra=[0]→sticky.
    // =========================================================================
    logic        p_res_sign;
    logic [8:0]  p_exp_div;
    logic [7:0]  p_exp_sq;
    logic [22:0] p_frac;
    logic        p_guard, p_rnd;
    logic        p_sticky, p_nx;
    logic        p_round_up;
    logic [23:0] p_mant_sum;
    logic        p_carry;
    logic [FLEN-1:0] p_result;
    logic [4:0]      p_fflags;

    assign p_res_sign = is_sqrt ? 1'b0 : (a_sign ^ b_sign);
    assign p_exp_div  = {1'b0, a_exp} - {1'b0, b_exp} + 9'd127 - {8'b0, div_exp_adj};
    assign p_exp_sq   = 8'(({1'b0, a_exp} + 9'd127) >> 1);

    // FDIV: hidden bit implicit; div_quo[25:3]=fraction, [2]=G, [1]=R, [0]→sticky
    // FSQRT: sqrt_q[25]=hidden(always 1); [24:2]=fraction, [1]=G, [0]=R
    /* verilator lint_off UNUSEDSIGNAL */
    logic p_sq_hidden;
    assign p_sq_hidden = sqrt_q[25];   // hidden bit, not in output mantissa
    /* verilator lint_on UNUSEDSIGNAL */
    assign p_frac   = is_sqrt ? sqrt_q[24:2] : div_quo[25:3];
    assign p_guard  = is_sqrt ? sqrt_q[1]    : div_quo[2];
    assign p_rnd    = is_sqrt ? sqrt_q[0]    : div_quo[1];
    assign p_sticky = is_sqrt ? (sqrt_r != 28'h0)
                              : (div_quo[0] | (div_rem != 27'h0));
    assign p_nx       = p_guard | p_rnd | p_sticky;

    always_comb begin
        unique case (rm_r)
            3'b000: p_round_up = p_guard & (p_rnd | p_sticky | p_frac[0]);
            3'b001: p_round_up = 1'b0;
            3'b010: p_round_up = p_nx &  p_res_sign;
            3'b011: p_round_up = p_nx & ~p_res_sign;
            default: p_round_up = p_guard;
        endcase
    end

    assign p_mant_sum = {1'b0, p_frac} + 24'(p_round_up);
    assign p_carry    = p_mant_sum[23];

    always_comb begin
        p_result = 32'h7FC0_0000;  // default: qNaN
        p_fflags = 5'b0;

        if (!is_sqrt) begin
            // ── FDIV special cases ────────────────────────────────────────────
            if (a_nan || b_nan || (a_inf && b_inf) || (a_zero && b_zero)) begin
                p_result = 32'h7FC0_0000; p_fflags = 5'b1_0000;  // NV
            end else if (a_inf || b_zero) begin
                p_result = {p_res_sign, 8'hFF, 23'h0};           // ±Inf
                p_fflags = b_zero ? 5'b0_1000 : 5'b0;
            end else if (a_zero || b_inf) begin
                p_result = {p_res_sign, 31'h0};                   // ±0
            end else if (p_exp_div[8] || (p_exp_div >= 9'd255)) begin
                p_result = {p_res_sign, 8'hFF, 23'h0}; p_fflags = 5'b0_0101; // OF+NX
            end else if (p_exp_div == 9'd0) begin
                p_result = {p_res_sign, 31'h0};        p_fflags = 5'b0_0011; // UF+NX
            end else begin
                p_result = {p_res_sign,
                            p_carry ? p_exp_div[7:0] + 8'd1 : p_exp_div[7:0],
                            p_carry ? 23'h0 : p_mant_sum[22:0]};
                p_fflags = {4'b0, p_nx};
            end
        end else begin
            // ── FSQRT special cases ───────────────────────────────────────────
            if (a_nan || (a_sign && !a_zero)) begin
                p_result = 32'h7FC0_0000; p_fflags = 5'b1_0000;  // NaN / √(neg)
            end else if (a_inf) begin
                p_result = 32'h7F80_0000;                          // +Inf
            end else if (a_zero) begin
                p_result = {a_sign, 31'h0};                        // ±0
            end else begin
                p_result = {1'b0,
                            p_carry ? p_exp_sq + 8'd1 : p_exp_sq,
                            p_carry ? 23'h0 : p_mant_sum[22:0]};
                p_fflags = {4'b0, p_nx};
            end
        end
    end

    // =========================================================================
    // Latch PACK result into DONE registers
    // =========================================================================
    logic [FLEN-1:0] r_result;
    logic [4:0]      r_fflags;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            r_result <= '0;
            r_fflags <= 5'b0;
        end else if (state == S_PACK) begin
            r_result <= p_result;
            r_fflags <= p_fflags;
        end
    end

    assign result_o = r_result;
    assign fflags_o = r_fflags;

endmodule
