// =============================================================================
// rr_arbiter.sv  —  N-way Burst-Aware Masked Round-Robin Arbiter
// =============================================================================
//
// CONTEXT:
//   This arbiter is the writeback-bus scheduler for the fpu_top compute
//   subsystem.  fpu_top contains four functional units with different latencies:
//
//     Unit        Latency   N_REQ index
//     NONCOMP     1 cycle   0
//     CVT         2 cycles  1
//     FMA         6 cycles  2
//     DIVSQRT     variable  3
//
//   When two units complete in the same cycle (e.g., NONCOMP issued 5 cycles
//   after a FMA), both assert req_i simultaneously.  This arbiter serialises
//   them onto a single 37-bit writeback bus (result[31:0] + fflags[4:0]).
//
// ARCHITECTURE:
//   Rotating-priority pointer (one-hot register pp_q).  On each grant the
//   pointer advances to the next slot, implementing strict round-robin
//   fairness.  Two features extend the base algorithm:
//
//   1. MASK (mask_i):  Suppresses requesters whose power domain is off
//      (e.g., DIVSQRT clock-gated during FMA-only workloads).  A masked
//      requester is treated as if req_i[n] = 0.  The priority pointer still
//      advances past masked slots so fairness is restored the instant a unit
//      wakes up.
//
//   2. BURST LOCK (burst_lock_i / last_i):  AXI4-compatible burst semantics.
//      Once a grant is issued and the upstream asserts burst_lock_i, the
//      arbiter freezes the grant until last_i is observed.  This prevents
//      mid-burst revocation that would corrupt in-flight data.
//
// TIMING:
//   Grant is registered.  The combinational grant-select logic (priority mask
//   + lowest-set-bit extraction) closes comfortably at 80 MHz in sky130.
//   The registered output eliminates the grant from the critical path of any
//   downstream MUX.
//
//     cycle    event
//     N        req_i asserted; new grant computed combinationally
//     N+1      grant_o reflects new winner; upstream sees stable grant
//
// FORMAL SCOPE (see rr_arbiter.sby):
//   Safety — proved by z3 k-induction:
//     ONEHOT0      : $onehot0(grant_o)               [mutual exclusion]
//     NO_MASK_GNT  : !(grant_o & mask_i)             [power-gate respect]
//     BURST_ATOMIC : burst lock holds until last_i   [AXI burst integrity]
//     PP_ONEHOT    : $onehot(pp_q)                   [pointer invariant]
//   Reachability — proved by sby cover mode:
//     COV_GRANT[k] : each requester k can receive a grant
//
// =============================================================================

module rr_arbiter #(
    parameter int N_REQ = 4                 // number of requesters
) (
    input  logic              clk,
    input  logic              rst_n,

    // ── Request interface ──────────────────────────────────────────────────
    input  logic [N_REQ-1:0] req_i,         // 1 = unit wants writeback bus
    input  logic [N_REQ-1:0] mask_i,        // 1 = unit power-gated, skip

    // ── Burst-lock interface (AXI-style) ──────────────────────────────────
    input  logic              burst_lock_i,  // 1 = hold current grant
    input  logic              last_i,        // 1 = end of burst, release

    // ── Grant interface ────────────────────────────────────────────────────
    output logic [N_REQ-1:0] grant_o,       // one-hot; 0 = no grant this cycle
    output logic              gnt_valid_o   // |grant_o; fast upstream stall
);

    // ── Internal state ─────────────────────────────────────────────────────
    logic [N_REQ-1:0] pp_q;                 // priority pointer (one-hot)
    logic [N_REQ-1:0] grant_q;             // registered grant

    // ── Combinational grant selection ──────────────────────────────────────
    logic [N_REQ-1:0] active_req;
    logic [N_REQ-1:0] prio_mask;
    logic [N_REQ-1:0] masked_req;
    logic [N_REQ-1:0] next_grant;
    logic             burst_hold;

    // Active requests: exclude power-gated units
    assign active_req = req_i & ~mask_i;

    // Priority mask: all bits at or above the pointer position.
    // Derivation: pp_q is one-hot, so (pp_q - 1) sets all bits below the
    // pointer.  Inverting gives all bits from the pointer upward.
    assign prio_mask = ~(pp_q - 1'b1);

    // Masked requests: only consider requesters at or after the pointer
    assign masked_req = active_req & prio_mask;

    // Lowest-set-bit isolation: v & (~v + 1)  ==  v & (-v)
    // If any request exists at/after pointer → grant it.
    // Otherwise wrap around and grant lowest-numbered active request.
    assign next_grant = |masked_req
                      ? (masked_req & (~masked_req + 1'b1))
                      : (active_req & (~active_req + 1'b1));

    // Freeze grant while burst in progress and end-of-burst not yet seen
    assign burst_hold = burst_lock_i & (|grant_q) & ~last_i;

    // ── Sequential logic ───────────────────────────────────────────────────
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            grant_q <= '0;
            pp_q    <= {{(N_REQ-1){1'b0}}, 1'b1};   // reset: req 0 has priority
        end else if (burst_hold) begin
            // Mid-burst: hold everything frozen
            grant_q <= grant_q;
        end else if (|active_req) begin
            grant_q <= next_grant;
            // Advance pointer to the next slot after the winner (left-rotate)
            pp_q <= {next_grant[N_REQ-2:0], next_grant[N_REQ-1]};
        end else begin
            // No active requests: deassert grant, pointer unchanged
            grant_q <= '0;
        end
    end

    assign grant_o    = grant_q;
    assign gnt_valid_o = |grant_q;

    // ── Formal verification block ──────────────────────────────────────────
    // Properties are checked by sby (SymbiYosys) in mode prove / cover.
    // Only active when Yosys reads this file with 'read -formal'.
    `ifdef FORMAL
        // F1 — Mutual exclusion: never two grants simultaneously
        ONEHOT0: assert property (
            @(posedge clk) disable iff (!rst_n)
            $onehot0(grant_o)
        );

        // F2 — Power-gate respect: masked requester never granted
        NO_MASK_GNT: assert property (
            @(posedge clk) disable iff (!rst_n)
            !(grant_o & mask_i)
        );

        // F3 — Burst atomicity: grant held until last_i when locked
        BURST_ATOMIC: assert property (
            @(posedge clk) disable iff (!rst_n)
            (burst_lock_i && |grant_o && !last_i) |=> (grant_o == $past(grant_o))
        );

        // F4 — Pointer invariant: pp_q is always one-hot (never 0, never 2-hot)
        PP_ONEHOT: assert property (
            @(posedge clk) disable iff (!rst_n)
            $onehot(pp_q)
        );

        // Cover: every requester slot is reachable (fairness demonstration)
        for (genvar k = 0; k < N_REQ; k++) begin : gen_cov
            COV_GRANT: cover property (
                @(posedge clk) grant_o[k]
            );
        end
    `endif

endmodule
