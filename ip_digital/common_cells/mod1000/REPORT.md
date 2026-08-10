# mod1000 — Detailed Pillar Findings

_Companion to `STATUS.md`. This IP uses the correct immediate-assertion house style (not the broken SVA pattern found in `rr_arbiter`/`apb_uart_master`/`uart_ctrl`), but its formal proof has an unconfirmed dependency on an idiom this session found to be unreliable — read "Toolchain trust audit" below._

**Overall: ✅ per STATUS.md (2026-08-03 19:47:10), all 9 pillars PASS — but P2 Formal's trustworthiness is an open question, not confirmed.**

| Pillar | Status | Metric |
|---|---|---|
| P1 Lint + CDC/RDC | PASS | 0 err, 0 warn |
| P2 Formal | PASS (see caveat below) | depth 20 |
| P3 Functional | PASS | 1/1 tests |
| P4 Simulation | PASS | — |
| P5 Coverage | PASS | 100.0% line, 100.0% toggle |
| P6 Synthesis | PASS | 64 cells |
| P7 LEC | PASS | 3 pts proven |
| P8 Pre-Layout STA + GLS | PASS | 500.0 MHz target, +1.583 ns MET |
| P9 UPF Power Intent | PASS | — |

## Toolchain trust audit: P2 Formal

`mod1000.sv` correctly uses immediate assertions (`assert(...)` inside `always_comb`, gated by a `f_was_reset` flag), matching this repo's actual working house style — **not** the broken SVA pattern. However, this session discovered (while debugging `rr_arbiter`) that a plain register's `initial X = const;` is **not reliably honored by this Yosys build's BMC basecase** — a minimal repro showed a flop declared `initial f = 1'b0` reading `1` at BMC step 0 regardless. `mod1000.sv`'s `f_was_reset` flop uses exactly this pattern (`initial f_was_reset = 0;`).

Critically, **`mod1000`'s properties genuinely depend on this gating being correct** — unlike `fpu_top`'s single property (a pure combinational tautology, immune to this issue by construction — see `fpu_top`'s report), `mod1000` asserts `count <= 10'd999` and several shadow-register bindings, all of which reference *registered* state that is legitimately undefined before a real reset. If `f_was_reset` can spuriously read `1` at step 0 without `rst_n` ever having been asserted (as the minimal repro demonstrated is possible on this toolchain), these assertions are being checked against a step-0 state that was never supposed to be reachable, and the proof's basecase soundness is genuinely in question.

**This has not been re-verified with the corrected `initial assume(!rst_n);` idiom.** The current PASS should be treated with the same skepticism `rr_arbiter`'s identical-looking PASS deserved before it was independently re-confirmed this session — it may well still hold (the bug doesn't guarantee a counterexample exists, only that the model is looser than intended), but it hasn't been checked.

**Recommended fix** (not yet applied): replace the `f_was_reset` flop + `initial X=0` pattern with `initial assume(!rst_n);` directly, gating checks on the current cycle's `rst_n` instead of a derived "was ever reset" flag — the same fix already applied and confirmed working on `rr_arbiter.sv`.

## P6/P7/P8 — independent of the formal concern

Synthesis, LEC, and STA+GLS don't depend on P2's soundness and have no similar red flags — 64 cells, 3 LEC points proven, timing comfortably met (+1.583 ns at 500 MHz). No findings.
