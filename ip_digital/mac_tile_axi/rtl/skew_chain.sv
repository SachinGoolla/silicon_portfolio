// skew_chain.sv -- parameterized N-deep, enable-gated delay line.
//
// Reused across the array's own west-edge skew network (per-row delays of
// i*LATENCY cycles), south-edge de-skew network ((N-1-j)*LATENCY cycles),
// and axi4stream_ctrl's own occupancy/TLAST tag chain (full transit-depth
// cycles) -- one proven primitive instead of N hand-written shift-register
// copies, each a fresh chance for an off-by-one.
`timescale 1ns/1ps

module skew_chain #(
    parameter int WIDTH = 8,
    parameter int DEPTH = 1  // 0 = pure combinational passthrough
) (
    /* verilator lint_off UNUSEDSIGNAL */
    // clk/rst_n/en_i are genuinely unused when DEPTH==0 (pure combinational
    // passthrough, no registers) -- a legitimate configuration (row 0's own
    // west skew / column N-1's own south de-skew in systolic_array_4x4),
    // not a mistake.
    input  logic              clk,
    input  logic              rst_n,
    input  logic               en_i,
    /* verilator lint_on UNUSEDSIGNAL */
    input  logic [WIDTH-1:0]  data_in_i,
    output logic [WIDTH-1:0]  data_out_o
);

    generate
        if (DEPTH == 0) begin : g_passthrough
            assign data_out_o = data_in_i;
        end else begin : g_delay
            logic [WIDTH-1:0] chain_q [DEPTH];
            always_ff @(posedge clk or negedge rst_n) begin
                if (!rst_n) begin
                    for (int k = 0; k < DEPTH; k++) chain_q[k] <= '0;
                end else if (en_i) begin
                    chain_q[0] <= data_in_i;
                    for (int k = 1; k < DEPTH; k++) chain_q[k] <= chain_q[k-1];
                end
            end
            assign data_out_o = chain_q[DEPTH-1];
        end
    endgenerate

`ifdef FORMAL
    initial assume(!rst_n);

    // DEPTH==0 (g_passthrough) is a bare wire assign -- nothing to get
    // wrong sequentially, and a shadow chain sized [DEPTH] would be a
    // zero-element array (f_shadow_q[DEPTH-1] = f_shadow_q[-1], an
    // elaboration-time error, not just a vacuously-true runtime condition).
    // Guard with a real generate-if, not a runtime assume() -- an assume
    // can't prevent an invalid array index from being elaborated in the
    // first place. This exact gap was caught for real: checkpoint 2's own
    // standalone proof only ever chparam'd DEPTH=3, so it never elaborated
    // the DEPTH=0 configuration; systolic_array_4x4 (checkpoint 3) does,
    // for row 0's west skew and column N-1's south de-skew, and hit this
    // directly.
    generate
        if (DEPTH > 0) begin : g_formal_delay
            // Independently re-derived shadow chain (hand-written fresh
            // here, not copied from the DUT's own generate-for loop above)
            // -- if the DUT's indexing has an off-by-one, an independently-
            // derived chain built to the same DEPTH is very unlikely to
            // share the exact same mistake. This is the "explicit shadow
            // register" idiom this repo's formal blocks use throughout
            // (e.g. rv32i_addr_decoder.sv's f_ram_bvalid_d).
            logic [WIDTH-1:0] f_shadow_q [DEPTH];
            always_ff @(posedge clk or negedge rst_n) begin
                if (!rst_n) begin
                    for (int m = 0; m < DEPTH; m = m + 1) f_shadow_q[m] <= '0;
                end else if (en_i) begin
                    for (int m = DEPTH - 1; m > 0; m = m - 1) f_shadow_q[m] <= f_shadow_q[m-1];
                    f_shadow_q[0] <= data_in_i;
                end
            end
            always_comb begin
                if (rst_n) assert(data_out_o == f_shadow_q[DEPTH-1]);
            end
        end else begin : g_formal_passthrough
            always_comb begin
                if (rst_n) assert(data_out_o == data_in_i);
            end
        end
    endgenerate

    // Freeze correctness: output holds when en_i==0. Meaningful only for
    // DEPTH>0 -- the passthrough arm has no state to freeze (data_out_o
    // tracks data_in_i combinationally regardless of en_i by construction).
    generate
        if (DEPTH > 0) begin : g_freeze_check
            logic f_en_d;
            logic [WIDTH-1:0] f_out_prev_q;
            always_ff @(posedge clk or negedge rst_n) begin
                if (!rst_n) begin
                    f_en_d <= 1'b0; f_out_prev_q <= '0;
                end else begin
                    f_en_d <= en_i;
                    f_out_prev_q <= data_out_o;
                end
            end
            always_comb begin
                if (rst_n && !f_en_d) assert(data_out_o == f_out_prev_q);
            end
        end
    endgenerate

    always_comb begin
        cover(rst_n && en_i && (data_in_i != 0));
    end
`endif

endmodule
