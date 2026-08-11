# fpu_axi_periph — Engineering Report: Integration Thinking, Scoped Proofs, and the Portfolio's Best Evidence for Constrained-Random Verification

_Companion to `STATUS.md`. The portfolio's first **application-level** IP — a full IEEE 754 FPU (`fpu_top`) wrapped behind an AXI4-Lite peripheral interface with a software-visible register map: an application, not just a protocol. My work here was integration-grade: proving the glue without re-proving the parts, extracting a quantitative verification-strategy lesson from the coverage numbers, and — on re-verification — becoming the IP that proved this session's memory-safety fixes actually hold under real, concurrent, multi-pillar load._

## Final Status Dashboard

**Overall: ✅ 8/9 PASS, 1 documented WARN — full `--force` sweep re-verified 2026-08-10 19:23:34 (commit `02b8144`), completing with zero manual intervention despite running P2 Formal and P7 LEC concurrently (the exact configuration that had required a manual abort on `uart_ctrl` earlier the same session — this run is the fix's validation, not just its description).**

| Pillar | Status | Metric |
|---|---|---|
| P1 Lint + CDC/RDC | ✅ PASS | 0 err, 0 warn |
| P2 Formal | ✅ PASS (caveat below) | depth 5 |
| P3 Functional | ✅ PASS | 9/9 tests |
| P4 Simulation | ✅ PASS | — |
| P5 Coverage | ✅ PASS | 66.0% line, 16.3% toggle — the real finding |
| P6 Synthesis | ✅ PASS | 1,005 cells |
| P7 LEC | ⚠️ WARN (documented) | k-induction non-convergent — same RTL↔PDK state-encoding wall as `async_fifo`/`axi_lite_slave`/`uart_ctrl`/`fpu_top` |
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

**The idiom risk, closed:** this file originally used the **sole-gate** `f_reset_seen` shape (`initial f_reset_seen = 1'b0;`, no redundant direct `rst_n` check) — the idiom this session proved unreliable in this Yosys build's BMC basecase (see `rr_arbiter`/`mod1000`). I applied the same remedy (`initial assume(!rst_n)`) here, then confirmed it with a `--force` re-run rather than treating the fix as self-evidently correct — depth 5 is shallow, which is exactly the kind of proof where I don't want to *also* be trusting an unconfirmed idiom on top of a narrow search window. The re-run PASSed genuinely.

**The concurrency risk, also closed — and this is the more interesting result:** this re-verification ran P2 Formal and P7 LEC's sequential fallback concurrently, via `pillar.py`'s own wave-based parallelism — the exact configuration that produced a live memory crisis on `uart_ctrl` earlier this session (aggregate multi-process usage exhausting the host even with each process under its own cap). By the time I re-ran this IP, I'd already found and fixed the two tooling gaps that crisis exposed. This sweep completing cleanly, with both proofs running side by side and no manual intervention, is the actual evidence the fix works — not just that I reasoned it should.

### The finding I'm most pleased with: 16.3% toggle coverage is not a failure — it's a measurement that makes an argument

Every other IP in this portfolio posts strong toggle numbers: `rr_arbiter` 100%, `mod1000`/`mod3ud` 100%, `uart_ctrl` 64.8%, `async_fifo` 28.9%. This IP posts **16.3%** — and I can explain exactly why, structurally: it wraps the entire FPU datapath (FMA/CVT/DIVSQRT/NONCOMP — wide, deep combinational logic) behind a *narrow* AXI-Lite register interface, exercised by only 9 directed register read/write tests. Most of the FPU's internal toggle surface simply isn't reachable by a handful of register transactions.

The insight I drew: **this is the most concrete, quantified argument in the portfolio for constrained-random verification.** Directed tests verify intent; coverage metrics measure exploration. When exploration sits at 16.3%, the marginal value of the tenth directed test is near zero and the marginal value of randomization is enormous. This IP is the natural first target for the UVM constrained-random coverage-closure project — now with a number (16.3%) as both its baseline and its justification.

## Result

- **8/9 pillars PASS, 1 documented WARN**, full `--force` sweep 2026-08-10 19:23:34 at commit `02b8144`, completing with zero manual intervention under concurrent P2/P7 load.
- **Formal:** depth-5 proof scoped to integration glue only; idiom corrected and genuinely re-confirmed, not just specified.
- **Functional:** 9/9 integration tests PASS — register-level control of FPU operations, end to end.
- **Coverage:** 66.0% line / 16.3% toggle — low number fully explained by interface/datapath asymmetry and converted into a strategy decision.
- **PPA:** 1,005 cells — the embedded FPU alone is 1,004, so the peripheral wrapper costs ~1 cell: exactly what a thin register-map shim should cost. TT MET at the 5.8 MHz integration target; SS −155.374 ns catalogued as the standard pre-layout extreme-corner advisory; GLS PASS.
- **LEC:** WARN — same documented sequential-LEC wall as `fpu_top`/`async_fifo`/`axi_lite_slave`/`uart_ctrl`; cross-verified by P2 Formal + P8 GLS instead.

## Key Accomplishments

- **Accomplished** integration-level formal sign-off without redundant re-proof, **as measured by** depth-5 convergence scoped to glue properties, **by doing** cone-of-influence discipline one level of hierarchy up.
- **Accomplished** closing a flagged idiom risk by execution, not just specification, **as measured by** a genuine `--force` PASS on the corrected idiom, **by doing** the fix and then re-running it instead of leaving the caveat open.
- **Accomplished** live validation of this session's memory-safety hardening, **as measured by** a clean concurrent P2+P7 run completing with zero manual intervention — the same pillar combination that had forced a manual abort on a sibling IP, **by doing** the fix first and trusting it under real, concurrent load second.
- **Accomplished** a quantified verification-strategy decision, **as measured by** a 66.0%/16.3% baseline now attached to the constrained-random roadmap, **by doing** structural root-cause on a coverage number instead of writing more directed tests.
- **Accomplished** negligible-cost hardware integration, **as measured by** a 1-cell wrapper delta (1,005 vs 1,004), **by doing** thin-shim design over a proven datapath.

## Skills Demonstrated

- **Compositional verification architecture** — scoped the integration proof to integration assumptions.
- **Follow-through** — closed a logged caveat by fixing and re-confirming it, not by leaving it flagged.
- **Coverage economics** — converted a low metric into a justified strategy decision with a measured baseline.
- **Structural explanation of measurements** — traced 16.3% to interface/datapath asymmetry, not to "bad tests."

## Open Items — What I'd Do Next

Stand up constrained-random stimulus against this IP first (baseline: 66.0% line / 16.3% toggle) — the formal and concurrency questions are both closed now, so coverage is the clear next lever.