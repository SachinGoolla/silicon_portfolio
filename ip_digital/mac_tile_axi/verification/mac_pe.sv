// mac_pe.sv -- systolic array processing element: a thin, LATENCY-
// parameterized shell around a swappable arithmetic leaf.
//
// Holds one stationary weight, passes its activation input east delayed
// exactly LATENCY cycles (so it arrives at the next PE synchronized with
// this PE's own psum output), and dispatches to one of two arithmetic
// leaves via the USE_FP32 generate arm:
//   USE_FP32=0 (default, only configuration built this phase): int8_mac_core,
//     LATENCY=1, combinational multiply + one enable-gated register.
//   USE_FP32=1 (deferred, NOT implemented this phase): would wrap fpu_fma
//     (ip_digital/fpu/fpu_fma/rtl/fpu_fma.sv) as a 4-stage FMA. fpu_fma has
//     NO ready_i/backpressure port at all -- valid_i in, valid_o out exactly
//     4 cycles later, unconditionally accepting, no way to pause it
//     mid-flight. That's what makes LATENCY-parameterization the right shape
//     for the swap (both leaves are fixed-latency, always-accepting pipeline
//     stages) but it's also why pipeline_en_i's MEANING differs by LATENCY:
//     at LATENCY=1 it freezes the whole arithmetic core (a plain
//     clock-enable-gated register); at LATENCY=4 it could only gate this
//     shell's own registers, never fpu_fma's internal pipeline, since that
//     pipeline has no enable of its own. A real fp32_mac_core needs a
//     resolved output-buffering contract (sized to the array's full transit
//     latency, not a 1-entry skid buffer) before it can be built -- see
//     Phase 2 plan Sec 3. Never elaborated this phase (USE_FP32 stays 0
//     everywhere); the g_fp32 arm below is a documented, inert placeholder,
//     not working RTL.
`timescale 1ns/1ps

module mac_pe #(
    parameter int LATENCY  = 1,
    parameter int ACT_W    = 8,
    parameter int PSUM_W   = 32,
    parameter bit USE_FP32 = 1'b0
) (
    input  logic                      clk,
    input  logic                      rst_n,
    input  logic                      pipeline_en_i,

    input  logic signed [ACT_W-1:0]   act_in_i,
    output logic signed [ACT_W-1:0]   act_out_o,

    input  logic signed [PSUM_W-1:0]  psum_in_i,
    output logic signed [PSUM_W-1:0]  psum_out_o,

    input  logic signed [ACT_W-1:0]   weight_i,
    input  logic                      weight_we_i
);

    // Not read internally -- exposed so systolic_array_4x4/axi4stream_ctrl
    // can select their backpressure strategy off this parameter instead of
    // silently assuming freezability (see header comment).
    /* verilator lint_off UNUSEDPARAM */
    localparam bit FREEZABLE = (LATENCY == 1);
    /* verilator lint_on UNUSEDPARAM */

    // Stationary weight register -- loaded once (gated externally on !busy,
    // see mac_tile_axi.sv), held across many streaming passes.
    logic signed [ACT_W-1:0] weight_q;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n)          weight_q <= '0;
        else if (weight_we_i) weight_q <= weight_i;
    end

    // Activation pass-through, delayed exactly LATENCY cycles, freeze-hold
    // when pipeline_en_i==0. Hand-rolled here rather than an instance of
    // skew_chain.sv (a later checkpoint reserved for the array's own
    // multi-cycle skew/de-skew networks and the control FSM's occupancy
    // chain) -- at LATENCY=1 this phase it's a single register, no reuse
    // benefit from a generic module, and building it standalone keeps this
    // checkpoint's own proof self-contained.
    logic signed [ACT_W-1:0] act_delay_q [LATENCY];
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (int k = 0; k < LATENCY; k++) act_delay_q[k] <= '0;
        end else if (pipeline_en_i) begin
            act_delay_q[0] <= act_in_i;
            for (int k = 1; k < LATENCY; k++) act_delay_q[k] <= act_delay_q[k-1];
        end
    end
    assign act_out_o = act_delay_q[LATENCY-1];

    generate
        if (!USE_FP32) begin : g_int8
            int8_mac_core #(
                .ACT_W  (ACT_W),
                .PSUM_W (PSUM_W)
            ) u_core (
                .clk           (clk),
                .rst_n         (rst_n),
                .pipeline_en_i (pipeline_en_i),
                .act_in_i      (act_in_i),
                .psum_in_i     (psum_in_i),
                .weight_i      (weight_q),
                .psum_out_o    (psum_out_o)
            );
        end else begin : g_fp32
            initial begin
                $fatal(1, "mac_pe: USE_FP32=1 selects an unimplemented fp32_mac_core leaf (deferred, see Phase 2 plan Sec 3)");
            end
            assign psum_out_o = '0;
        end
    endgenerate

`ifdef FORMAL
    initial assume(!rst_n);

    // This checkpoint only proves the LATENCY=1 (int8) configuration -- the
    // fp32 arm is inert (see header). Assume the elaboration matches.
    initial assume(LATENCY == 1 && !USE_FP32);

    // Weight holds its value except on a real weight_we_i.
    logic f_we_d;
    logic signed [ACT_W-1:0] f_weight_prev_q;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            f_we_d <= 1'b0; f_weight_prev_q <= '0;
        end else begin
            f_we_d <= weight_we_i;
            f_weight_prev_q <= weight_q;
        end
    end
    always_comb begin
        if (rst_n && !f_we_d) assert(weight_q == f_weight_prev_q);
    end

    // act_out_o freeze correctness (LATENCY=1: one register, holds when
    // pipeline_en_i==0).
    logic f_en_d;
    logic signed [ACT_W-1:0] f_act_out_prev_q;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            f_en_d <= 1'b0; f_act_out_prev_q <= '0;
        end else begin
            f_en_d <= pipeline_en_i;
            f_act_out_prev_q <= act_out_o;
        end
    end
    always_comb begin
        if (rst_n && !f_en_d) assert(act_out_o == f_act_out_prev_q);
    end

    always_comb begin
        cover(rst_n && pipeline_en_i && weight_we_i);
        cover(rst_n && pipeline_en_i && (psum_out_o != 0));
    end
`endif

endmodule
