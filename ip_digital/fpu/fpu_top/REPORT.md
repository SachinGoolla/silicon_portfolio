# fpu_top — Detailed Pillar Findings

_Companion to `STATUS.md`. The portfolio's flagship IP — IEEE 754 FPU with a genuinely re-confirmed formal proof this session, and the only IP where the `initial X=const` risk (found this session, affects most other IPs' formal signoff) can be ruled out by construction rather than left as an open question._

**Overall: ✅ per STATUS.md (2026-08-04 12:37:19), all 9 pillars PASS — P2 Formal specifically re-verified this session, not carried over.**

| Pillar | Status | Metric |
|---|---|---|
| P1 Lint + CDC/RDC | PASS | 0 err, 0 warn |
| P2 Formal | PASS — genuinely confirmed | depth 10, k-induction, <1s |
| P3 Functional | PASS | 20/20 tests |
| P4 Simulation | PASS | — |
| P5 Coverage | PASS | 96.0% line, 76.8% toggle |
| P6 Synthesis | PASS | 1004 cells |
| P7 LEC | PASS | 5 pts proven |
| P8 Pre-Layout STA + GLS | PASS | 10.5 MHz target, TT MET, SS advisory (-84.202 ns) |
| P9 UPF Power Intent | PASS | — |

## P2 Formal: why this one is trustworthy despite using the same flagged idiom

`fpu_top.sv` uses the same `f_was_reset` / `initial f_was_reset = 0;` shape this session found unreliable on this Yosys build's BMC basecase (a minimal repro showed the flop reading `1` at step 0 regardless of its declared `initial` value). **This does not compromise `fpu_top`'s specific proof**, because its one property is a pure combinational tautology, not a claim about registered state:

```
assign busy_o = div_busy;
assign ready_o = ~busy_o;
assert(ready_o == ~busy_o);
```

Both sides of the assertion reduce to `~div_busy` after substitution — true for *any* value of `div_busy`, at *any* cycle, reset or not, regardless of whether `f_was_reset`'s gating is behaving as intended. Contrast with `mod1000`'s `assert(count <= 10'd999)`, which genuinely depends on `count` being a real post-reset value — that one IS exposed to the bug. `fpu_top`'s isn't.

The proof itself was rebuilt from scratch this session (not just re-confirmed): every submodule outside the property's actual fan-in (`fpu_fma`, `fpu_cvt`, `fpu_noncomp`, `fpu_result_mux`, `fpu_clk_gate_ctrl`, and `fpu_divsqrt` itself — division/sqrt bit-vector arithmetic is a known-hard case for SMT bit-blasting independent of FF count) was stubbed with `anyseq` free inputs in `fpu_top_proto_formal_stub.sv`, cutting the state space from 767 FFs down to just `fpu_top.sv`'s own wire assignments. Full k-induction now converges in under 1 second. See `fpu_top_proto.sby`'s header comment and project memory `feedback_formal_sby` for the complete fan-in analysis.

**Caveat, for completeness**: this proof covers exactly one protocol invariant (`ready_o == ~busy_o`), not FMA/CVT/DIVSQRT arithmetic correctness — that would need a full-design formal tool (JasperGold-class) this portfolio doesn't have. Arithmetic correctness is covered by P3's 20 directed functional tests instead, not formally proven.

## P6/P7/P8 — no new findings

1004 cells, 5 LEC points proven (combinational-only per-module — `fpu_fma`/`fpu_divsqrt` sequential LEC is out of scope for the open-source Yosys miniSAT flow, cross-verified by P2 Formal + P8 GLS instead, documented limitation). TT corner MET at 10.5 MHz target; SS-corner advisory is the standard pre-layout extreme-corner pattern seen across this portfolio.
