# axi_lite_slave — Detailed Pillar Findings

_Companion to `STATUS.md`. **Only P6 Synthesis and P7 LEC have ever been run for this IP** — P1/P2/P3/P4/P5/P8/P9 are genuinely `_never run_`, not a reporting gap._

**Overall: ⚠️ INCOMPLETE — 2 of 9 pillars ever executed.**

| Pillar | Status | Metric |
|---|---|---|
| P1 Lint + CDC/RDC | _never run_ | — |
| P2 Formal | _never run_ | — |
| P3 Functional | _never run_ | — |
| P4 Simulation | _never run_ | — |
| P5 Coverage | _never run_ | — |
| P6 Synthesis | PASS | 4351 cells |
| P7 LEC | WARN (documented) | k-induction non-convergent |
| P8 Pre-Layout STA + GLS | _never run_ | — |
| P9 UPF Power Intent | _never run_ | — |

## What's actually known

Only synthesis and LEC have been exercised, both against the RTL as it existed on 2026-08-04 (commit `e3d1c2e`, before this session's HW-priority write-port addition — see `CLAUDE.md`'s note on the `hw_wdata_i`/`hw_we_i` register-file change and the registration stage added to fix an STA regression it caused). **P6/P7's results predate that RTL change and have not been re-confirmed against the current file.**

- 4351 cells at synthesis — notably larger than any other single-purpose bus-protocol IP in this portfolio (compare `rr_arbiter` 54, `mod1000` 64, `uart_ctrl` 326), consistent with a full AXI4-Lite slave register file rather than a narrow protocol shim.
- P7 LEC WARN is the same documented, legitimate finding as `async_fifo`/`uart_ctrl` (sequential LEC state-encoding gap, not a design defect).

## Toolchain trust audit: P2 Formal (for when it's eventually run)

`axi_lite_slave.sv` uses the correct immediate-assertion house style (`f_reset_seen` flop, `assert(...)` inside `always_comb`) — not the broken SVA pattern. However it uses the **sole-gate** shape (`if (f_reset_seen) begin assert(...); end`, no redundant direct `rst_n` check the way `async_fifo` has) — the same shape found risky on `mod1000` this session, relying on `initial f_reset_seen = 1'b0;` which this Yosys build does not reliably honor for BMC's basecase. **When P2 Formal is first run for this IP, use `initial assume(!rst_n);` instead of the `f_reset_seen` flop** — the corrected idiom already proven on `rr_arbiter.sv`, rather than carrying this pattern forward into a fifth IP.

## Recommended next steps

Run the full 9-pillar sweep with `--force` against the current RTL (including the HW-priority write-port change) before treating this IP as portfolio-ready — P6/P7's PASS predates that change, and P1/P2/P3/P4/P5/P8/P9 have literally never run.
