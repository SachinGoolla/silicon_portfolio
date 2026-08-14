// int8_mac_core.sv -- int8 x int8 -> int32 multiply-accumulate leaf.
//
// LATENCY=1: combinational multiply + a single enable-gated register. This
// is one of two swappable arithmetic leaves mac_pe.sv can instantiate (the
// other, fp32_mac_core, wraps fpu_fma and is deferred -- see mac_pe.sv's own
// header for why the two aren't a drop-in swap despite both being
// fixed-latency, always-accepting pipeline stages).
`timescale 1ns/1ps

module int8_mac_core #(
    parameter int ACT_W  = 8,
    parameter int PSUM_W = 32
) (
    input  logic                     clk,
    input  logic                     rst_n,
    input  logic                     pipeline_en_i,
    input  logic signed [ACT_W-1:0]  act_in_i,
    input  logic signed [PSUM_W-1:0] psum_in_i,
    input  logic signed [ACT_W-1:0]  weight_i,
    output logic signed [PSUM_W-1:0] psum_out_o
);

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            psum_out_o <= '0;
        end else if (pipeline_en_i) begin
            psum_out_o <= psum_in_i + (act_in_i * weight_i);
        end
    end

`ifdef FORMAL
    initial assume(!rst_n);

    // Bounded psum_in_i range representative of a legitimate accumulation
    // chain in a 4x4 int8 array (max single-product magnitude 128*128=16384,
    // at most 3 prior accumulations feed any one row) -- generous headroom,
    // nowhere near int32's own +-2^31 range. `assume`, never `inside{}`
    // (p2_formal.py's _scan_formal_idioms() hard-errors on inside{}).
    localparam int PSUM_BOUND = 1_000_000;
    always_comb begin
        if (rst_n) begin
            assume(psum_in_i <= PSUM_BOUND);
            assume(psum_in_i >= -PSUM_BOUND);
        end
    end

    // Exact accumulate, no truncation -- the one-cycle-later value of
    // psum_out_o must equal last cycle's psum_in_i + act_in_i*weight_i
    // whenever the pipe was enabled that cycle. Tracked via a shadow
    // register of what was actually presented, since this is a same-cycle
    // input vs. next-cycle output comparison (an explicit skew, not a bug --
    // see CLAUDE.md's "registered output vs live input" idiom note).
    logic                     f_en_d;
    logic signed [ACT_W-1:0]  f_act_d, f_weight_d;
    logic signed [PSUM_W-1:0] f_psum_in_d;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            f_en_d <= 1'b0; f_act_d <= '0; f_weight_d <= '0; f_psum_in_d <= '0;
        end else begin
            f_en_d      <= pipeline_en_i;
            f_act_d     <= act_in_i;
            f_weight_d  <= weight_i;
            f_psum_in_d <= psum_in_i;
        end
    end
    always_comb begin
        if (rst_n && f_en_d) begin
            assert(psum_out_o == f_psum_in_d + (f_act_d * f_weight_d));
        end
    end

    // Freeze correctness: psum_out_o holds its value when pipeline_en_i==0.
    logic signed [PSUM_W-1:0] f_psum_out_prev_q;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) f_psum_out_prev_q <= '0;
        else        f_psum_out_prev_q <= psum_out_o;
    end
    always_comb begin
        if (rst_n && !f_en_d) begin
            assert(psum_out_o == f_psum_out_prev_q);
        end
    end

    always_comb begin
        cover(rst_n && pipeline_en_i && (act_in_i != 0) && (weight_i != 0));
    end
`endif

endmodule
