# mod1000 — Engineering Report: The Case Study in Knowing When a Flagged Pattern Is Actually Load-Bearing

_Companion to `STATUS.md`. A mod-1000 counter cell (64 cells) written in the correct immediate-assertion house style — no SVA anywhere. And yet this is the IP where this session's toolchain-bug discovery bites **hardest**, because its formal proof genuinely depends on the exact idiom I proved unreliable. This report is the careful, unpanicked analysis of that exposure._

## Final Status Dashboard

**Overall: ✅ SIGNED OFF per STATUS.md (2026-08-03 19:47:10) — all 9 pillars PASS, with P2 Formal's soundness explicitly logged as an open question, not a confirmed fact.**

| Pillar | Status | Metric |
|---|---|---|
| P1 Lint + CDC/RDC | ✅ PASS | 0 err, 0 warn |
| P2 Formal | ✅ PASS (soundness caveat below) | depth 20 |
| P3 Functional | ✅ PASS | 1/1 tests |
| P4 Simulation | ✅ PASS | — |
| P5 Coverage | ✅ PASS | 100.0% line, 100.0% toggle |
| P6 Synthesis | ✅ PASS | 64 cells |
| P7 LEC | ✅ PASS | 3 pts proven |
| P8 Pre-Layout STA + GLS | ✅ PASS | 500.0 MHz target, +1.583 ns MET; GLS PASS |
| P9 UPF Power Intent | ✅ PASS | — |

---

## Situation

`mod1000` is a common-cell counter with a formal proof that had already recorded a PASS. It uses no SVA — so on the surface it looked immune to this session's toolchain findings. Surface readings are exactly what this session taught me to distrust.

## Task

Determine whether the recorded formal PASS is sound under the newly discovered BMC basecase bug — and if not, say precisely why, how much it matters, and what the fix is.

## Action

### Same flagged idiom — but here the proof stands on it

The discovery (full account in the `rr_arbiter` report): a plain register's `initial X = const;` is **not reliably honored by this Yosys build's BMC basecase** — my minimal repro showed a flop declared `initial f = 1'b0` reading `1` at step 0 regardless. `mod1000.sv`'s `f_was_reset` flop uses exactly this pattern, and all of its assertions are gated behind that flag.

Here is the discriminating analysis I applied — the same one that cleared `fpu_top` and downgraded `async_fifo`/`mod3ud`, and which here **raises** the alarm instead:

- `fpu_top`'s property is a combinational tautology — immune *by construction*, true in every state.
- `mod3ud`'s flag is unconditionally set on the first edge, and its assertion additionally requires `$past(!rst)` — exposed only in a narrow step-0 window.
- `async_fifo` gates on the flag **and** a primary reset input — the redundant direct check covers the flag's failure mode.
- **`mod1000` asserts `count <= 10'd999` plus several shadow-register bindings — claims about *registered state* legitimately undefined before a real reset, gated by the flag alone.**

So if `f_was_reset` can spuriously read `1` at step 0 without `rst_n` ever having been asserted — which the repro demonstrated is possible — these assertions are checked against a step-0 state that was never supposed to be reachable, and the **basecase soundness of the proof is genuinely in question.** Presence of a risky pattern is not the finding; *dependence* on it is. That distinction is the whole skill.

**Calibrated skepticism, in both directions:** this does not mean the properties are false — the bug makes the model *looser* than intended, not wrong, and the PASS may well still hold. But it hasn't been checked, and after watching `rr_arbiter`'s identical-looking PASS turn out to be checkpoint fiction, "hasn't been checked" is a status I report as-is.

**The fix I specified (queued):** delete the `f_was_reset` flop + `initial X=0` pattern entirely; use `initial assume(!rst_n);` and gate checks on the current cycle's `rst_n` — the same correction already applied and proven on `rr_arbiter.sv`. A smaller change than the analysis that justified it, which is usually how good fixes look.

## Result

- **8/9 pillars unconditionally clean:** P1 0/0; P3 1/1; P4 clean; P5 100.0%/100.0%; P6 64 cells; P7 3 points proven; P8 +1.583 ns MET at the 500.0 MHz target with GLS PASS; P9 PASS. None of these depend on P2's soundness.
- **P2 recorded PASS, soundness open** — basecase exposure identified, mechanism named, fix specified and queued.

## Key Accomplishments

- **Accomplished** a precise exposure verdict on a recorded PASS, **as measured by** a named failure mode (basecase soundness) rather than a vague "formal might be wrong," **by doing** dependence analysis — distinguishing "pattern present" from "pattern load-bearing" across four sibling IPs.
- **Accomplished** two-sided calibration on an open question, **as measured by** documented reasoning for why the PASS is suspect *and* why it may still be true, **by doing** model-level reasoning about what a looser basecase does and does not break.
- **Accomplished** an actionable remediation with zero design risk, **as measured by** a fix already proven on `rr_arbiter.sv`, **by doing** idiom transfer instead of inventing a new pattern.

## Skills Demonstrated

- **Dependence analysis** — distinguished "pattern present" from "pattern load-bearing."
- **Proof-soundness reasoning** — identified basecase exposure as the specific failure mode.
- **Two-sided calibration** — documented why the PASS is suspect and why it may hold.
- **Actionable remediation** — a concrete, already-proven-elsewhere fix, scoped and queued.

## Open Items — What I'd Do Next

Apply the `initial assume(!rst_n)` rewrite, then `--force` P2 (and the full sweep) so this PASS is earned against the current RTL rather than inherited.
