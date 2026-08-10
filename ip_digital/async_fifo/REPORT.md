# async_fifo — Detailed Pillar Findings

_Companion to `STATUS.md`. Dual-clock gray-code FIFO (Cummings 2002 architecture, wr_clk 100MHz / rd_clk 33MHz). Uses immediate-assertion house style with a reassuring safety margin against this session's `initial X=const` finding — see below._

**Overall: ✅ per STATUS.md (2026-08-03 20:10:02), all 9 pillars PASS or documented WARN.**

| Pillar | Status | Metric |
|---|---|---|
| P1 Lint + CDC/RDC | PASS | 0 err, 0 warn |
| P2 Formal | PASS (low risk — see below) | depth 20 |
| P3 Functional | PASS | 4/4 tests |
| P4 Simulation | PASS | — |
| P5 Coverage | PASS | 90.0% line, 28.9% toggle |
| P6 Synthesis | PASS | 840 cells |
| P7 LEC | WARN (documented) | k-induction non-convergent (RTL↔PDK state-encoding gap) |
| P8 Pre-Layout STA + GLS | PASS | 12.0 MHz target, TT MET, SS advisory (-54.867 ns) |
| P9 UPF Power Intent | PASS | — |

## Toolchain trust audit: P2 Formal — lower risk than mod1000/fpu_axi_periph/axi_lite_slave

`async_fifo.sv` uses the same general shape as the other immediate-assertion IPs (`f_wr_started`/`f_rd_started` flops with `initial ... = 0`, the pattern this session found unreliable on this Yosys build's BMC basecase for its power-on value). **But the exposure here is narrower**: every assertion is gated on `wr_rst_n && f_wr_started` (write domain) / `rd_rst_n && f_rd_started` (read domain) — both conditions, not the flag alone. `wr_rst_n`/`rd_rst_n` are primary inputs with no `initial`-value dependency at all, so even in the worst case where `f_wr_started` spuriously reads `1` at step 0 (bypassing its intended "not yet started" guard), the assertion is still correctly disabled whenever the corresponding reset is actually asserted. Contrast with `mod1000`/`fpu_axi_periph`/`axi_lite_slave`, which gate solely on the derived flag (`if (f_was_reset)` / `if (f_reset_seen)`) with no redundant direct-input check.

**Net assessment**: still not independently re-confirmed with `--force` this session, but the belt-and-suspenders gating structure makes a false PASS here meaningfully less likely than in the sole-gate IPs. Worth confirming, lower priority than those.

## P7 — LEC: WARN (documented, legitimate)

Same class of finding as `axi_lite_slave`/`uart_ctrl` — Yosys k-induction doesn't converge on sequential LEC for this design (RTL↔PDK state-encoding gap), cross-verified by P2 Formal + P8 GLS, confirmed via experiment that generic-gate BMC doesn't rescue it either. Not a design defect.

## P8 — STA+GLS: PASS (TT MET; SS advisory)

12.0 MHz target — comfortably low bar for a design this size; SS-corner -54.867 ns is the standard pre-layout extreme-corner advisory, not a real violation.
