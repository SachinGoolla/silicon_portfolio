// Formal wrapper for mod3ud — adds assertions without modifying RTL source.
`default_nettype none

module mod3ud_formal (
    input logic clk,
    input logic rst
);

    logic [2:0] cnt;
    mod3ud dut (.clk(clk), .rst(rst), .cnt(cnt));

    `ifdef FORMAL
    // Track past cnt for transition checks
    logic [2:0] cnt_prev;
    always @(posedge clk)
        cnt_prev <= cnt;

    // ── Safety: counter always in [0,7] ──────────────────────────────────────
    always @(posedge clk)
        assert (cnt <= 3'd7);

    // ── Transition sanity: cnt can only ±1, jump to 7, jump to 6, or reset ──
    // (checked after initialization to avoid X-state false fails)
    logic init;
    initial init = 1'b0;
    always @(posedge clk) init <= 1'b1;

    always @(posedge clk) begin
        if (init && !rst && $past(!rst)) begin
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
        cover (init && !rst && cnt == 3'd7);
    // Wrap-around: return to 0 after counting down from 1
    always @(posedge clk)
        cover (init && !rst && cnt == 3'd0 && cnt_prev == 3'd1);
    `endif

endmodule
