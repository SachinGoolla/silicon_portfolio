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
// FORMAL SCOPE (see rr_arbiter.sby + rr_arbiter_liveness.sby):
//   NOTE: properties are written as immediate assertions inside clocked
//   always blocks (`assert(...)`/`assume(...)`/`cover(...)`), NOT SVA
//   `assert property (...)`/`property...endproperty`. The open-source
//   Yosys build this flow runs on (no Verific) does not parse SVA temporal
//   property syntax at all -- confirmed directly: both the distro `apt`
//   yosys 0.33 AND the full oss-cad-suite yosys 0.38 reject `property`/
//   `assert property` with a hard parser error, regardless of `-sv`/
//   `-formal` flags. This file used to be written in SVA and reported
//   PASS on the dashboard, but that PASS came from checkpoint carryover
//   (`is_checkpoint_valid()` skipping a real re-run), not an actual
//   passing proof -- the underlying .sby run has always hard-errored on
//   this toolchain. See project memory feedback_formal_sby. Every other
//   IP in this repo whose formal proof is independently confirmed real
//   (fpu_top, mod3ud, mod1000) already uses this immediate-assertion
//   house style; this file now matches it.
//   Safety — proved by z3 k-induction (rr_arbiter.sby):
//     ONEHOT0      : $onehot0(grant_o)                     [mutual exclusion]
//     NO_MASK_GNT  : !(grant_o & mask_at_grant_q)          [power-gate respect]
//                    NOT `!(grant_o & mask_i)` (current-cycle mask) — grant_o
//                    is registered, reflecting the mask_i live when the
//                    grant was DECIDED one cycle earlier. mask_i has no
//                    stability contract, so BMC finds a real counterexample
//                    against the current-cycle comparison (mask_i legally
//                    flips between decision and observation in the formal
//                    model). mask_at_grant_q tracks the mask actually used
//                    for whatever grant_o currently holds; the property is
//                    the same one the RTL was always meant to guarantee.
//     BURST_ATOMIC : burst lock holds until last_i         [AXI burst integrity]
//     PP_ONEHOT    : $onehot(pp_q)                         [pointer invariant]
//   Liveness — proved by z3 k-induction (rr_arbiter_liveness.sby, `-DLIVENESS`):
//     STARVATION_FREE[k] : a continuously-held, unmasked request from
//                          requester k is granted within N_REQ cycles.
//                          Encoded as a per-requester "consecutive cycles
//                          waited without a grant" counter, asserted never
//                          to exceed N_REQ -- the counter IS the ranking
//                          function from the hand proof below. Proof scope
//                          excludes burst_lock_i (assumed 0 — burst
//                          atomicity is separately, fully proven by
//                          BURST_ATOMIC above); see rr_arbiter_liveness.sby
//                          header for why the two are split.
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
    // Only active when Yosys reads this file with 'read -formal'. Written
    // as immediate assertions (house style — see FORMAL SCOPE header above
    // for why, not SVA `assert property`).
    `ifdef FORMAL
        // Force the model to actually pass through reset before anything
        // is checked. Without this, BMC's basecase explores the design
        // starting from ANY arbitrary step-0 state — including "rst_n=1
        // and no reset ever happened" — and grant_q/pp_q have no explicit
        // `initial` value, so that state is uninitialized garbage
        // (confirmed directly: a real captured counterexample showed
        // rst_n=1 at step 0 with grant_q=1111 and pp_q=0000, neither
        // one-hot). This is the standard, tool-recommended idiom for this
        // exact problem — NOT a mod1000-style "was ever reset" latched
        // flag: that variant relies on a plain register's `initial X = 0`
        // being honored for ITS OWN power-on value, which this Yosys
        // build's formal flow does not reliably do either (confirmed with
        // a separate minimal repro). `initial assume(...)`, by contrast,
        // is a real constraint on the basecase's starting state and does
        // work — confirmed with a minimal k-induction PASS before relying
        // on it here.
        initial assume(!rst_n);

        // Gate every check directly on the CURRENT cycle's rst_n (the
        // immediate-assertion equivalent of SVA `disable iff (!rst_n)`).
        // Sufficient because grant_q/pp_q are already valid the same
        // cycle rst_n deasserts — no extra settling cycle needed.

        // History for F3 (burst atomicity needs last cycle's hold state +
        // grant value — the immediate-assertion equivalent of $past()).
        logic              burst_hold_prev_q;
        logic [N_REQ-1:0] grant_prev_q;
        always_ff @(posedge clk or negedge rst_n) begin
            if (!rst_n) begin
                burst_hold_prev_q <= 1'b0;
                grant_prev_q      <= '0;
            end else begin
                burst_hold_prev_q <= burst_hold;
                grant_prev_q      <= grant_o;
            end
        end

        // History for F2 (power-gate respect). grant_o is REGISTERED — it
        // reflects the mask_i that was live when the grant was DECIDED
        // (`active_req = req_i & ~mask_i`, same cycle as `next_grant`),
        // not necessarily this cycle's mask_i. mask_i is a plain,
        // unsynchronized input with no stability contract, so BMC
        // legitimately finds a counterexample if F2 is checked against
        // the CURRENT cycle's mask_i: mask_i can flip between decision
        // and observation. Track the mask actually used for whatever
        // grant_o currently holds instead — mirrors grant_q's own hold/
        // update conditions exactly, so it stays correct across a
        // burst-held grant too. This proves the assertion actually meant
        // ("never grant a unit that was masked when the decision was
        // made") rather than a strictly stronger same-cycle claim the RTL
        // was never designed to guarantee.
        logic [N_REQ-1:0] mask_at_grant_q;
        always_ff @(posedge clk or negedge rst_n) begin
            if (!rst_n) begin
                mask_at_grant_q <= '0;
            end else if (|active_req && !burst_hold) begin
                mask_at_grant_q <= mask_i;
            end
            // burst_hold or no active_req: grant_q doesn't change either
            // (held or staying 0) — mask_at_grant_q holds too, by omission.
        end

        always_comb begin
            if (rst_n) begin
                // F1 — Mutual exclusion: never two grants simultaneously
                assert ($onehot0(grant_o));
                // F2 — Power-gate respect: masked requester never granted
                assert (!(grant_o & mask_at_grant_q));
                // F3 — Burst atomicity: if last cycle was burst-held, this
                // cycle's grant must be unchanged from last cycle's.
                assert (!burst_hold_prev_q || (grant_o == grant_prev_q));
                // F4 — Pointer invariant: pp_q is always one-hot
                assert ($onehot(pp_q));
            end
        end

        // Cover: every requester slot is reachable (fairness demonstration)
        for (genvar k = 0; k < N_REQ; k++) begin : gen_cov
            always_comb cover (grant_o[k]);
        end

        `ifdef LIVENESS
            // F5 — Starvation freedom (see rr_arbiter_liveness.sby header
            // for the full rationale). Scope is isolated from burst_lock_i:
            // BURST_ATOMIC above already fully proves burst atomicity with
            // no such assume; combining "starvation-free" and "correct
            // under adversarial worst-case bursting" into one proof needs
            // depth on the order of N_REQ * MAX_BURST_LEN, not tractable
            // for k-induction on this host (see project memory
            // feedback_formal_sby). With the bus never held hostage, pp_q
            // left-rotates exactly one slot per active-request cycle, so a
            // continuously-held, unmasked request is granted within N_REQ
            // cycles — hand-verified via a decreasing-distance argument
            // (each cycle requester j loses, the new pointer strictly
            // closes the circular-scan distance to j by at least 1; that
            // distance starts at most N_REQ-1, so induction over that
            // bounded chain is exactly what k-induction proves). The
            // "distance to j" argument IS this counter: wait_cnt_q[j]
            // counts consecutive cycles j has waited since its last grant
            // (or since it started requesting) — the ranking function,
            // made concrete as a synthesizable signal instead of an SVA
            // `throughout`/`##[0:N]` window (also not supported by this
            // toolchain).
            always_comb begin
                if (rst_n) assume (!burst_lock_i);
            end

            for (genvar j = 0; j < N_REQ; j++) begin : gen_live
                logic [7:0] wait_cnt_q;
                always_ff @(posedge clk or negedge rst_n) begin
                    if (!rst_n) begin
                        wait_cnt_q <= 8'd0;
                    end else if (grant_o[j]) begin
                        wait_cnt_q <= 8'd0;                    // served — reset
                    end else if (req_i[j] && !mask_i[j]) begin
                        wait_cnt_q <= wait_cnt_q + 8'd1;        // still waiting
                    end else begin
                        wait_cnt_q <= 8'd0;                    // gave up requesting
                    end
                end
                always_comb begin
                    if (rst_n) assert (wait_cnt_q <= N_REQ);
                end
            end
        `endif
    `endif

endmodule
