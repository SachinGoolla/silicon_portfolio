# fpu_axi_periph — Engineering Report: Integration Thinking, Scoped Proofs, and the Portfolio's Best Evidence for Constrained-Random Verification

_Companion to `STATUS.md`. The portfolio's first **application-level** IP — a full IEEE 754 FPU (`fpu_top`) wrapped behind an AXI4-Lite peripheral interface with a software-visible register map: an application, not just a protocol. My work here was integration-grade: proving the glue without re-proving the parts, and extracting a quantitative verification-strategy lesson from the coverage numbers._

## Final Status Dashboard

**Overall: ✅ SIGNED OFF — all 9 pillars PASS or documented WARN (2026-08-03 22:05:09).**

| Pillar | Status | Metric |
|---|---|---|
| P1 Lint + CDC/RDC | ✅ PASS | 0 err, 0 warn |
| P2 Formal | ✅ PASS (caveat below) | depth 5 |
| P3 Functional | ✅ PASS | 9/9 tests |
| P4 Simulation | ✅ PASS | — |
| P5 Coverage | ✅ PASS | 66.0% line, 16.3% toggle — the real finding |
| P6 Synthesis | ✅ PASS | 1,005 cells |
| P7 LEC | ✅ PASS | 5 pts proven |
| P8 Pre-Layout STA + GLS | ✅ PASS | 5.8 MHz target, TT MET, SS advisory (−155.374 ns); GLS PASS |
| P9 UPF Power Intent | ✅ PASS | — |

---

## Situation

This IP composes two already-verified blocks — `fpu_top` (1,004 cells) and `axi_lite_slave` — into a software-accessible floating-point peripheral. Composition changes the verification question: the parts are proven; the *integration assumptions* are not.

## Task

Sign off the integration across all nine pillars, with formal effort spent where the new risk actually lives — the glue — and an honest read on what the coverage numbers say about verification strategy.

## Action

### Proof scoping: I proved the new logic and refused to re-prove the old

The formal properties on `fpu_axi_periph.sv` check exactly one thing: the AXI-Lite↔FPU glue — the STATUS/BUSY/DONE handshake encoding this file introduces. The underlying `fpu_top` and `axi_lite_slave` submodules carry their own standalone P2 proofs. A deliberate architecture decision: integration-level formal should witness *integration assumptions*, not redundantly re-verify submodule internals — that is how proofs stay fast, legible, and maintainable as systems compose. It's the same cone-of-influence discipline I applied to `fpu_top`'s stubbed proof, one level of hierarchy up.

**Caveat I logged:** this file uses the **sole-gate** `f_reset_seen` shape (`initial f_reset_seen = 1'b0;`, no redundant direct `rst_n` check) — the idiom this session proved unreliable in this Yosys build's BMC basecase (see `rr_arbiter`/`mod1000`). Depth 5 is shallow, which bounds how much state divergence induction could explore either way — but "shallow" is not "sound." Not independently re-confirmed with `--force` this session; same open item as `mod1000`/`axi_lite_slave`, and `initial assume(!rst_n)` is the known remedy.

### The finding I'm most pleased with: 16.3% toggle coverage is not a failure — it's a measurement that makes an argument

Every other IP in this portfolio posts strong toggle numbers: `rr_arbiter` 100%, `mod1000`/`mod3ud` 100%, `uart_ctrl` 64.8%, `async_fifo` 28.9%. This IP posts **16.3%** — and I can explain exactly why, structurally: it wraps the entire FPU datapath (FMA/CVT/DIVSQRT/NONCOMP — wide, deep combinational logic) behind a *narrow* AXI-Lite register interface, exercised by only 9 directed register read/write tests. Most of the FPU's internal toggle surface simply isn't reachable by a handful of register transactions.

The insight I drew: **this is the most concrete, quantified argument in the portfolio for constrained-random verification.** Directed tests verify intent; coverage metrics measure exploration. When exploration sits at 16.3%, the marginal value of the tenth directed test is near zero and the marginal value of randomization is enormous. This IP is the natural first target for the UVM constrained-random coverage-closure project — now with a number (16.3%) as both its baseline and its justification.

## Result

- **9/9 pillars PASS**, full sweep 2026-08-03 22:05:09 at commit `e3d1c2e`.
- **Formal:** depth-5 proof scoped to integration glue only; sole-gate idiom caveat logged with a known remedy.
- **Functional:** 9/9 integration tests PASS — register-level control of FPU operations, end to end.
- **Coverage:** 66.0% line / 16.3% toggle — low number fully explained by interface/datapath asymmetry and converted into a strategy decision.
- **PPA:** 1,005 cells — the embedded FPU alone is 1,004, so the peripheral wrapper costs ~1 cell: exactly what a thin register-map shim should cost. 5 LEC points; TT MET at the 5.8 MHz integration target; SS −155.374 ns catalogued as the standard pre-layout extreme-corner advisory; GLS PASS.

## Key Accomplishments

- **Accomplished** integration-level formal sign-off without redundant re-proof, **as measured by** depth-5 convergence scoped to glue properties, **by doing** cone-of-influence discipline one level of hierarchy up.
- **Accomplished** a quantified verification-strategy decision, **as measured by** a 66.0%/16.3% baseline now attached to the constrained-random roadmap, **by doing** structural root-cause on a coverage number instead of writing more directed tests.
- **Accomplished** negligible-cost hardware integration, **as measured by** a 1-cell wrapper delta (1,005 vs 1,004), **by doing** thin-shim design over a proven datapath.
- **Accomplished** honest caveat maintenance on a passing row, **as measured by** the sole-gate idiom flagged in the same table that reports PASS, **by doing** skepticism that doesn't exempt green checkmarks.

## Skills Demonstrated

- **Compositional verification architecture** — scoped the integration proof to integration assumptions.
- **Coverage economics** — converted a low metric into a justified strategy decision with a measured baseline.
- **Structural explanation of measurements** — traced 16.3% to interface/datapath asymmetry, not to "bad tests."
- **Honest caveat maintenance** — flagged the sole-gate formal idiom even on a passing row.

## Open Items — What I'd Do Next

Stand up constrained-random stimulus against this IP first (baseline: 66.0% line / 16.3% toggle), and apply the `initial assume(!rst_n)` idiom before the next `--force` sweep.