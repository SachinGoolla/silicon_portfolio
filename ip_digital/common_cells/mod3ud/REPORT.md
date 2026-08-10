# mod3ud — Engineering Report: The Smallest IP in the Portfolio, Audited with the Same Rigor as the Flagship

_Companion to `STATUS.md`. A mod-3 up/down counter cell — 32 cells synthesized — verified through a dedicated formal wrapper (`verification/mod3ud_formal.sv`). Small designs are where sloppy verification hides, because "it's obviously right" is not a proof. I gave this cell the same toolchain trust audit I gave the flagship FPU._

## Final Status Dashboard

**Overall: ✅ SIGNED OFF — all 9 pillars PASS (2026-08-03 19:35:06).**

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

**2. Does the `initial init = 1'b0;` idiom endanger this proof? Far less than its sibling's.** The same session, I found declared `initial` values aren't reliably honored in BMC's basecase. That idiom is present here — but I traced the actual exposure: `init` is set **unconditionally** on the very first clock edge (no reset gating at all), so by step 1 it reads `1` regardless of its step-0 value; and the transition-sanity assertion is additionally gated by `$past(!rst)`, firing only once a real prior cycle exists. The blast radius is a single step-0 window with no state dependence — structurally narrower than `mod1000`'s, whose assertions consume registered state genuinely undefined before reset. **Net assessment: lower risk than `mod1000`, but still not independently re-confirmed with the corrected `initial assume(!rst)` idiom — so I logged it for a `--force` re-run rather than assuming.** Confirm-don't-assume applies even when the analysis says "probably fine."

## Result

- **9/9 pillars PASS** at commit `e3d1c2e` — the only portfolio cell with full marks on every row.
- **Functional:** 6/6 directed tests PASS.
- **Coverage:** 100.0% line / 100.0% toggle — full closure, the right bar for a reusable common cell.
- **PPA:** 32 cells — the smallest mapped design in the portfolio; 3 LEC points proven; **1579.8 MHz** achievable with +0.368 ns slack MET; GLS clean. A 32-cell combinational-bound cell *should* be fast — confirming it rather than assuming it is the job.

## Key Accomplishments

- **Accomplished** total coverage closure on a reusable cell, **as measured by** 100% line + 100% toggle, **by doing** directed tests plus a dedicated formal wrapper instead of trusting the design's smallness.
- **Accomplished** a clean toolchain-trust classification, **as measured by** two minimal repros with definite answers, **by doing** experiment-driven discrimination between "looks like the broken pattern" and "is the broken pattern."
- **Accomplished** the portfolio's fastest timing closure, **as measured by** 1579.8 MHz with +0.368 ns MET, **by doing** lean combinational design and verifying the expectation rather than assuming it.

## Skills Demonstrated

- **Precision discrimination** — separated resemblance from identity via minimal repro.
- **Blast-radius analysis** — quantified worst-case exposure of a known toolchain bug instead of binary panic/complacency.
- **Uniform standards** — a 32-cell common cell received the same audit discipline as a 1,004-cell FPU.

## Open Items — What I'd Do Next

One `--force` P2 re-run with the corrected `initial assume(!rst)` idiom to convert "low-risk by analysis" into "confirmed by execution."
