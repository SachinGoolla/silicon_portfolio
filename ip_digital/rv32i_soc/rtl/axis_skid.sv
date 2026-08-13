// axis_skid.sv -- 1-entry FWFT (first-word-fall-through) valid/ready skid
// buffer.
//
// Sits at the array's m_axis boundary to absorb the one result vector that
// can be "in flight, unconsumed" when a downstream consumer briefly isn't
// ready -- sufficient because at LATENCY=1 (this phase's only implemented
// configuration), pipeline_en_i freezes the entire array the instant
// backpressure is asserted, so at most one already-computed result can ever
// be pending drain. No reusable FIFO exists in this repo for this exact
// same-clock-domain, real-backpressure shape (async_fifo.sv is CDC-specific
// and non-FWFT, confirmed by survey) -- genuinely new primitive.
`timescale 1ns/1ps

module axis_skid #(
    parameter int WIDTH = 32
) (
    input  logic              clk,
    input  logic              rst_n,

    input  logic               s_valid_i,
    output logic               s_ready_o,
    input  logic [WIDTH-1:0]  s_data_i,

    output logic               m_valid_o,
    input  logic                m_ready_i,
    output logic [WIDTH-1:0]  m_data_o
);

    logic              skid_valid_q;
    logic [WIDTH-1:0] skid_data_q;

    // Can accept a new beat only when the skid slot is empty -- if it's
    // occupied, an unconsumed beat is already waiting and must not be
    // overwritten.
    assign s_ready_o = !skid_valid_q;

    // FWFT: with the skid empty, m_valid_o/m_data_o pass s_valid_i/s_data_i
    // through combinationally (no bubble cycle) -- the skid slot only
    // engages when a beat was accepted but the downstream wasn't ready to
    // take it the same cycle.
    assign m_valid_o = s_valid_i || skid_valid_q;
    assign m_data_o  = skid_valid_q ? skid_data_q : s_data_i;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            skid_valid_q <= 1'b0;
            skid_data_q  <= '0;
        end else begin
            if (!skid_valid_q && s_valid_i && !m_ready_i) begin
                // Accepted this cycle (s_ready_o was high) but downstream
                // didn't take it -- stash it so it isn't lost.
                skid_valid_q <= 1'b1;
                skid_data_q  <= s_data_i;
            end else if (skid_valid_q && m_ready_i) begin
                // Downstream just consumed the stashed beat.
                skid_valid_q <= 1'b0;
            end
        end
    end

`ifdef FORMAL
    initial assume(!rst_n);

    // FWFT contract, checked directly.
    always_comb begin
        if (rst_n) begin
            assert(m_valid_o == (s_valid_i || skid_valid_q));
            assert(m_data_o  == (skid_valid_q ? skid_data_q : s_data_i));
            assert(s_ready_o == !skid_valid_q);
        end
    end

    // VALID-sticky: once m_valid_o is asserted and m_ready_i doesn't fire,
    // m_valid_o must remain asserted AND m_data_o must hold its value next
    // cycle (AXI4-Stream's own VALID-stable-until-READY requirement) --
    // same idiom as axi_lite_slave.sv's own B/R channel VALID-sticky
    // properties.
    logic f_mvalid_d, f_mready_d;
    logic [WIDTH-1:0] f_mdata_d;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            f_mvalid_d <= 1'b0; f_mready_d <= 1'b0; f_mdata_d <= '0;
        end else begin
            f_mvalid_d <= m_valid_o;
            f_mready_d <= m_ready_i;
            f_mdata_d  <= m_data_o;
        end
    end
    always_comb begin
        if (rst_n && f_mvalid_d && !f_mready_d) begin
            assert(m_valid_o);
            assert(m_data_o == f_mdata_d);
        end
    end

    always_comb begin
        cover(rst_n && s_valid_i && s_ready_o && !m_ready_i);  // skid engages
        cover(rst_n && skid_valid_q && m_ready_i);             // skid drains
    end
`endif

endmodule
