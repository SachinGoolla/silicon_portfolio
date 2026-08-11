# mod3ud — Engineering Report: The Smallest IP in the Portfolio, Audited with the Same Rigor as the Flagship

_Companion to `STATUS.md`. A mod-3 up/down counter cell — 32 cells synthesized — verified through a dedicated formal wrapper (`verification/mod3ud_formal.sv`). Small designs are where sloppy verification hides, because "it's obviously right" is not a proof. I gave this cell the same toolchain trust audit I gave the flagship FPU._

## Final Status Dashboard

**Overall: ✅ SIGNED OFF, genuinely re-verified — full `--force` 9-pillar sweep 2026-08-10 19:11:23 (commit `02b8144`).**

| Pillar | Status | Metric |
|---|---|---|
| P1 Lint + CDC/RDC | ✅ PASS | 0 err, 0 warn |
| P2 Formal | ✅ PASS (caveat below) | depth 30 |
| P3 Functional | ✅ PASS | 6/6 tests |
| P4 Simulation | ✅ PASS | — |
| P5 Coverage | ✅ PASS | 100.0% line, 100.0% toggle |
| P6 Synthesis | ✅ PASS | 32 cells |
| P7 LEC | ✅ PASS | 3 pts proven |
| P8 Pre-Layout STA + GLS | ✅ PASS | 1579.8 MHz target, +0.368 ns MET; GLS PASS |
| P9 UPF Power Intent | ✅ PASS | — |

---

## Situation

`mod3ud` is a reusable common cell: a mod-3 up/down counter with a dedicated formal wrapper. It is the smallest design in the portfolio — and precisely because of that, the easiest place for "obviously correct" to substitute for evidence.

## Task

Carry the cell through all nine pillars at the same evidentiary bar as the flagship, and audit its formal wrapper against the two toolchain trust issues I uncovered this session.

## Action

### Two syntax-shape questions, resolved by experiment rather than assumption

While debugging `rr_arbiter` I learned that this Yosys build rejects SVA temporal syntax outright — so I audited every IP's formal code by shape. `mod3ud_formal.sv` raised two questions, and I answered both with minimal repros.

**1. Is bare `$past()` the broken pattern? No.** `$past()` used as a plain system function inside an immediate `always @(posedge clk) assert(...)` block parses fine on this toolchain — confirmed directly. This file uses `$past(!rst)` exactly that way. A useful discrimination exercise: `uart_ctrl`'s full `assert property`/`property...endproperty` SVA is the known-broken shape; this file merely *rhymes* with it. Pattern recognition includes knowing when two similar-looking things are different.

**2. Does the `initial init = 1'b0;` idiom endanger this proof? Less than `mod1000`'s — but I was wrong about why it was safe, and re-verification caught it.** The same session, I found declared `initial` values aren't reliably honored in BMC's basecase. That idiom is present here — my static analysis traced the exposure to a single step-0 window (`init` is set unconditionally on the first clock edge; the transition-sanity assertion is additionally gated by `$past(!rst)`) and rated it lower-risk than `mod1000`'s genuinely state-dependent exposure.

**Then I applied the `initial assume(!rst)` fix and ran it — and got a real basecase counterexample anyway.** Not the risk I'd analyzed: `mod3ud`'s reset (`always @(posedge clk or posedge rst) if (rst) cnt<=0;`) is **active-high**, the opposite polarity from every other IP's `rst_n` in this portfolio. My first fix wrote `initial assume(!rst);`, pattern-matching the `!rst_n` convention I'd just proven everywhere else, without checking this design's actual polarity. Basecase failed immediately — `cnt_prev`, unconstrained at step 0, never got a real reset-derived value before the transition check fired. Corrected to `initial assume(rst);` and re-ran: genuine k-induction PASS, depth 30, cover mode PASS.

**Why this matters more than the fix itself:** my static risk analysis was internally sound but blind to a fact only the RTL's reset sensitivity list carried — `posedge rst`, not `negedge rst_n`. No amount of reasoning about the `initial`-value bug would have caught a polarity mismatch, because that's a different bug in a different place. The lesson I'm keeping: static analysis narrows *where* to look; only running the tool tells you whether you were right. "Confirm, don't assume" isn't a slogan here — it's the exact reason this proof is genuine instead of subtly wrong in a new way.

## Result

- **9/9 pillars PASS, genuinely re-verified** — full `--force` sweep 2026-08-10 19:11:23 (commit `02b8144`) — the only portfolio cell with full marks on every row, earned twice: once by design, once by catching my own fix's polarity error.
- **Functional:** 6/6 directed tests PASS.
- **Coverage:** 100.0% line / 100.0% toggle — full closure, the right bar for a reusable common cell.
- **PPA:** 32 cells — the smallest mapped design in the portfolio; 3 LEC points proven; **1579.8 MHz** achievable with +0.368 ns slack MET; GLS clean.

## Key Accomplishments

- **Accomplished** total coverage closure on a reusable cell, **as measured by** 100% line + 100% toggle, **by doing** directed tests plus a dedicated formal wrapper instead of trusting the design's smallness.
- **Accomplished** detection of my own fix's polarity error before it shipped silently, **as measured by** a real BMC basecase counterexample on the first re-verification attempt, **by doing** the re-run instead of trusting the static analysis that said "lower risk."
- **Accomplished** the portfolio's fastest timing closure, **as measured by** 1579.8 MHz with +0.368 ns MET, **by doing** lean combinational design and verifying the expectation rather than assuming it.

## Skills Demonstrated

- **Precision discrimination** — separated resemblance from identity via minimal repro on the `$past()` question.
- **Intellectual honesty about my own mistakes** — reported the polarity error and how it was caught, not just the eventual clean result.
- **Execution over analysis** — treated "low risk by reasoning" as a hypothesis to test, not a conclusion to ship.
- **Uniform standards** — a 32-cell common cell received the same audit discipline as a 1,004-cell FPU.

## Open Items — What I'd Do Next

None for this IP — signoff is genuine and re-verified. Worth carrying forward: check reset polarity explicitly on every IP before applying a formal-idiom fix by pattern-matching, rather than assuming the portfolio-wide `rst_n` convention holds everywhere.
