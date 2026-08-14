// xy_route.sv -- XY (dimension-order) routing decision for a mesh router.
//
// Purely combinational, no state: given a flit's destination coordinates and
// this router's own position, computes which of the router's 5 directions
// (North/East/South/West/Local) the flit needs to go next. Route in X first
// until the X coordinate matches, then route in Y, else Local -- the
// standard dimension-order rule that makes a mesh deadlock-free by
// construction with no virtual channels needed (Phase 3 plan §1).
//
// This module only decides "which direction should a flit AT this position,
// bound for this destination, go next" -- it has no notion of which
// direction the flit arrived FROM, so it cannot itself assert no-U-turn.
// That property (a flit's computed want never equals the port it arrived
// on) is a mesh_router-level check, made there where the arrival port is
// known (Phase 3 plan §1/§3, checkpoint 3).
`timescale 1ns/1ps

module xy_route #(
    parameter int MESH_DIM = 2
) (
    input  logic [$clog2(MESH_DIM)-1:0] dest_x_i,
    input  logic [$clog2(MESH_DIM)-1:0] dest_y_i,
    input  logic [$clog2(MESH_DIM)-1:0] my_x_i,
    input  logic [$clog2(MESH_DIM)-1:0] my_y_i,
    output logic [4:0]                  wants_o  // one-hot {L,W,S,E,N}, see DIR_* below
);

    // Direction indices, shared convention across every mac_cluster module
    // that touches a {N,E,S,W,L} port vector (mesh_router.sv, mesh_2x2.sv).
    localparam int DIR_N = 0;
    localparam int DIR_E = 1;
    localparam int DIR_S = 2;
    localparam int DIR_W = 3;
    localparam int DIR_L = 4;

    always_comb begin
        wants_o = 5'b0;
        if (dest_x_i > my_x_i) begin
            wants_o[DIR_E] = 1'b1;
        end else if (dest_x_i < my_x_i) begin
            wants_o[DIR_W] = 1'b1;
        end else if (dest_y_i > my_y_i) begin
            wants_o[DIR_N] = 1'b1;
        end else if (dest_y_i < my_y_i) begin
            wants_o[DIR_S] = 1'b1;
        end else begin
            wants_o[DIR_L] = 1'b1;
        end
    end

`ifdef FORMAL
    // Purely combinational, no clk/rst_n -- no basecase to constrain, no
    // `initial assume(!rst_n)` needed (there is nothing for it to gate).
    //
    // Non-tautological, exhaustive routing-correctness check: MESH_DIM=2
    // gives a 1-bit coordinate width, so all 16 (my_x,my_y,dest_x,dest_y)
    // combinations are enumerated explicitly below, each pinned to a
    // literal one-hot constant -- an independently hand-derived truth
    // table (worked out on paper against the routing SPEC: X first, then
    // Y, else Local), not a re-statement of the RTL's own if/else-if
    // structure above. This is the anti-vacuity discipline
    // rv32i_addr_decoder.sv established: a property must be checkable
    // against the INTENDED behavior, not just internally self-consistent
    // with whatever the RTL happens to compute.
    always_comb begin
        unique case ({my_x_i, my_y_i, dest_x_i, dest_y_i})
            4'b0000: assert(wants_o == 5'b10000); // my(0,0) dest(0,0) -> L
            4'b0001: assert(wants_o == 5'b00001); // my(0,0) dest(0,1) -> N
            4'b0010: assert(wants_o == 5'b00010); // my(0,0) dest(1,0) -> E
            4'b0011: assert(wants_o == 5'b00010); // my(0,0) dest(1,1) -> E (X first)
            4'b0100: assert(wants_o == 5'b00100); // my(0,1) dest(0,0) -> S
            4'b0101: assert(wants_o == 5'b10000); // my(0,1) dest(0,1) -> L
            4'b0110: assert(wants_o == 5'b00010); // my(0,1) dest(1,0) -> E (X first)
            4'b0111: assert(wants_o == 5'b00010); // my(0,1) dest(1,1) -> E
            4'b1000: assert(wants_o == 5'b01000); // my(1,0) dest(0,0) -> W
            4'b1001: assert(wants_o == 5'b01000); // my(1,0) dest(0,1) -> W (X first)
            4'b1010: assert(wants_o == 5'b10000); // my(1,0) dest(1,0) -> L
            4'b1011: assert(wants_o == 5'b00001); // my(1,0) dest(1,1) -> N
            4'b1100: assert(wants_o == 5'b01000); // my(1,1) dest(0,0) -> W (X first)
            4'b1101: assert(wants_o == 5'b01000); // my(1,1) dest(0,1) -> W
            4'b1110: assert(wants_o == 5'b00100); // my(1,1) dest(1,0) -> S
            4'b1111: assert(wants_o == 5'b10000); // my(1,1) dest(1,1) -> L
        endcase
    end

    // Output is one-hot for every reachable input, unconditionally --
    // general property, independent of the exhaustive per-case table above.
    always_comb assert($onehot(wants_o));

    always_comb begin
        cover(wants_o[DIR_N]);
        cover(wants_o[DIR_E]);
        cover(wants_o[DIR_S]);
        cover(wants_o[DIR_W]);
        cover(wants_o[DIR_L]);
    end
`endif

endmodule
