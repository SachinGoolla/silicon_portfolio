// requant.sv -- saturating fixed-shift int32 -> int8 requantization leaf.
//
// Converts one raw psum element (int32, as produced by int8_mac_core.sv)
// into one int8 activation element, so a receiving tile's mesh-delivered
// result can be used directly as its own next s_axis_tdata_i activation
// input -- real AI accelerators requantize between layers for exactly this
// reason (Phase 3 plan §3, checkpoint 2). Purely combinational, no state.
//
// SHIFT is a fixed parameter, not software-programmable -- a programmable
// scale needs a CSR (and the register-map/mutual-exclusion machinery that
// comes with one), real scope creep for a phase about proving the NoC
// fabric, not a quantization scheme. Deferred future task, same
// "designed for, not built" shape as Phase 2's fp32_mac_core leaf.
//
// Rounding mode is truncate via arithmetic right-shift (floor toward
// negative infinity, `>>>`'s own definition) -- not round-half-up. Stated
// explicitly here so a golden model never has to guess.
`timescale 1ns/1ps

module requant #(
    parameter int IN_W  = 32,
    parameter int OUT_W = 8,
    parameter int SHIFT = 4
) (
    input  logic [IN_W-1:0]  in_i,
    output logic [OUT_W-1:0] out_o
);

    localparam int signed MAX_VAL = (1 <<< (OUT_W-1)) - 1;  //  127 for OUT_W=8
    localparam int signed MIN_VAL = -(1 <<< (OUT_W-1));     // -128 for OUT_W=8

    // Signedness trap: in_i is a flat unsigned port vector (this repo's own
    // established port-syntax convention -- no packed struct, see
    // systolic_array_4x4.sv), so each element MUST be explicitly
    // $signed()-cast before shifting. An unsigned/logical >> here would
    // produce correct-looking answers only for positive inputs -- invisible
    // unless both this leaf's own proof and the P3/P4 golden model
    // deliberately exercise negative values (Phase 3 plan §3/§4 both
    // require this explicitly for exactly this reason).
    logic signed [IN_W-1:0] shifted;
    assign shifted = $signed(in_i) >>> SHIFT;

    always_comb begin
        if (shifted > MAX_VAL) begin
            out_o = MAX_VAL[OUT_W-1:0];
        end else if (shifted < MIN_VAL) begin
            out_o = MIN_VAL[OUT_W-1:0];
        end else begin
            out_o = shifted[OUT_W-1:0];
        end
    end

`ifdef FORMAL
    // Purely combinational, no clk/rst_n -- no basecase to constrain.
    //
    // Boundary-checked against literal MAX_VAL/MIN_VAL, not by re-reading
    // out_o's own ternary structure -- each branch asserted independently
    // as an outcome (saturate-high / saturate-low / exact round-trip),
    // the same "check the INTENDED behavior at its boundaries" discipline
    // as xy_route.sv's own exhaustive table, adapted for a leaf too wide
    // (2^32 inputs) to enumerate exhaustively.
    always_comb begin
        if (shifted > MAX_VAL) begin
            assert($signed(out_o) == MAX_VAL);
        end else if (shifted < MIN_VAL) begin
            assert($signed(out_o) == MIN_VAL);
        end else begin
            // In-range: no saturation, and the round-trip through OUT_W
            // bits must recover the exact shifted value (sign-extension
            // correctness, not just "some 8 bits came out").
            assert($signed(out_o) == shifted);
        end
    end

    // Output never escapes its own representable range, regardless of
    // input -- a general safety net independent of the boundary cases above.
    always_comb begin
        assert($signed(out_o) <= MAX_VAL);
        assert($signed(out_o) >= MIN_VAL);
    end

    // Reachability, deliberately including both saturation directions and
    // the negative-in-range case -- the exact coverage the signedness trap
    // above needs to be caught by, not just positive/in-range traffic.
    always_comb begin
        cover(shifted > MAX_VAL);                       // positive saturate
        cover(shifted < MIN_VAL);                        // negative saturate
        cover(shifted >= MIN_VAL && shifted <= MAX_VAL && shifted < 0);  // negative, in-range
        cover(shifted >= MIN_VAL && shifted <= MAX_VAL && shifted > 0);  // positive, in-range
    end
`endif

endmodule
