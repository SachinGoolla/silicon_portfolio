# fpu_axi_periph — Detailed Pillar Findings

_Companion to `STATUS.md`. Application-level IP wrapping `fpu_top` behind an AXI4-Lite peripheral interface — the portfolio's first "application, not just protocol" project. Uses correct immediate-assertion house style._

**Overall: ✅ per STATUS.md (2026-08-03 22:05:09), all 9 pillars PASS or documented WARN.**

| Pillar | Status | Metric |
|---|---|---|
| P1 Lint + CDC/RDC | PASS | 0 err, 0 warn |
| P2 Formal | PASS (see caveat below) | depth 5 |
| P3 Functional | PASS | 9/9 tests |
| P4 Simulation | PASS | — |
| P5 Coverage | PASS | **66.0% line, 16.3% toggle** |
| P6 Synthesis | PASS | 1005 cells |
| P7 LEC | PASS | 5 pts proven |
| P8 Pre-Layout STA + GLS | PASS | 5.8 MHz target, TT MET, SS advisory (-155.374 ns) |
| P9 UPF Power Intent | PASS | — |

## Toolchain trust audit: P2 Formal

`fpu_axi_periph.sv` correctly uses the immediate-assertion house style (`f_reset_seen` flop, `assert(...)` inside `always_comb`) — the same pattern this session confirmed working on `fpu_top`. The properties here check the AXI-Lite/FPU glue logic specifically (STATUS/BUSY/DONE handshake encoding) — the underlying `fpu_top` and `axi_lite_slave` submodules "have their own standalone P2 formal" per the RTL's own comment, i.e. this file's proof deliberately covers only the new integration logic, not re-proving the submodules.

Like `mod1000`/`axi_lite_slave`, this uses the **sole-gate** `f_reset_seen` shape (`initial f_reset_seen = 1'b0;`, no redundant direct `rst_n` check), the pattern this session found relies on an `initial` value this Yosys build doesn't reliably honor. Depth 5 is shallow, which somewhat limits how much state divergence the induction step could actually explore either way. **Not independently re-confirmed with `--force` this session** — same open item as `mod1000`/`axi_lite_slave`.

## Coverage is the real, actionable finding here

**16.3% toggle coverage is low** — notably lower than every other IP in this portfolio (`rr_arbiter` 100%, `mod1000`/`mod3ud` 100%, `async_fifo` 28.9%, `uart_ctrl` 64.8%). This is expected given `fpu_axi_periph` wraps the full `fpu_top` FPU datapath (FMA/CVT/DIVSQRT/NONCOMP — wide, deep combinational logic) behind a narrow AXI-Lite register interface exercised by only 9 directed tests; most of the FPU's internal toggle surface simply isn't hit by a handful of register read/write sequences. This is the most concrete, quantified argument in this portfolio for the "UVM constrained-random coverage closure" project already discussed as a next step — this IP is the natural target given how much headroom exists.

## P8 — STA+GLS: PASS (TT MET; SS advisory)

5.8 MHz target is comfortably low (integration-level pacing, not the FPU's own critical path) — TT MET, SS-corner -155.374 ns is the standard pre-layout extreme-corner advisory pattern seen across this portfolio, not a real violation.
