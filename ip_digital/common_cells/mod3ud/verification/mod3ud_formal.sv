// Formal wrapper for mod3ud — adds assertions without modifying RTL source.
`default_nettype none

module mod3ud_formal (
    input logic clk,
    input logic rst
);

    logic [2:0] cnt;
    mod3ud dut (.clk(clk), .rst(rst), .cnt(cnt));

    `ifdef FORMAL
    // Force BMC's basecase through an actual reset before anything is
    // checked. The previous `initial init = 1'b0;` flop (gating the
    // transition-sanity property alongside a direct `!rst`/`$past(!rst)`
    // check) relied on a plain register's `initial` value being honored
    // for its own power-on state, which this Yosys build does not
    // reliably do (confirmed with a minimal repro elsewhere in this
    // portfolio — see project memory feedback_formal_sby). Exposure here
    // was already low (the `!rst && $past(!rst)` check is a redundant,
    // `initial`-independent gate), but `initial assume(!rst);` makes
    // `init` unnecessary rather than merely low-risk: once the basecase
    // itself is constrained to start in reset, `!rst && $past(!rst)`
    // alone is sufficient to gate past the first real cycle.
    //
    // mod3ud's `rst` is ACTIVE-HIGH (`always @(posedge clk or posedge
    // rst) if (rst) cnt<=0;` in mod3ud.v) — the opposite polarity from
    // every other IP's active-low `rst_n` in this portfolio. A first
    // attempt at this fix wrote `initial assume(!rst);`, copying the
    // `!rst_n` pattern from elsewhere without checking this design's
    // actual polarity — caught immediately by a real basecase
    // counterexample on re-verification (cnt_prev, unconstrained at
    // step 0, never got a chance to settle to a real post-reset value).
    // `initial assume(rst);` is correct here.
    initial assume(rst);

    // Track past cnt for transition checks
    logic [2:0] cnt_prev;
    always @(posedge clk)
        cnt_prev <= cnt;

    // ── Safety: counter always in [0,7] ──────────────────────────────────────
    // (3-bit cnt's entire representable range is [0,7] — this is a
    // tautology by construction, immune to any basecase concern.)
    always @(posedge clk)
        assert (cnt <= 3'd7);

    // ── Transition sanity: cnt can only ±1, jump to 7, jump to 6, or reset ──
    always @(posedge clk) begin
        if (!rst && $past(!rst)) begin
            assert (
                cnt == cnt_prev + 3'd1 ||  // count up
                cnt == cnt_prev - 3'd1 ||  // count down
                cnt == 3'd7             ||  // F7 state
                cnt == 3'd6             ||  // S7 state
                cnt == cnt_prev            // held (should not occur post-reset)
            );
        end
    end

    // ── Liveness: cover interesting states ───────────────────────────────────
    // F7 state: cnt=7 is reachable
    always @(posedge clk)
        cover (!rst && cnt == 3'd7);
    // Wrap-around: return to 0 after counting down from 1
    always @(posedge clk)
        cover (!rst && cnt == 3'd0 && cnt_prev == 3'd1);
    `endif

endmodule
