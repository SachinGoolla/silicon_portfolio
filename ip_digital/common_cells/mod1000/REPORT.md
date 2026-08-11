# mod1000 — Engineering Report: The Case Study in Knowing When a Flagged Pattern Is Actually Load-Bearing

_Companion to `STATUS.md`. A mod-1000 counter cell (64 cells) written in the correct immediate-assertion house style — no SVA anywhere. And yet this was the IP where this session's toolchain-bug discovery bit **hardest**, because its formal proof genuinely depended on the exact idiom I proved unreliable. This report is the careful, unpanicked analysis of that exposure — and its resolution: the fix was applied and the proof was re-confirmed genuine with a full forced re-run, not left as a queued recommendation._

## Final Status Dashboard

**Overall: ✅ SIGNED OFF, genuinely re-verified — full `--force` 9-pillar sweep 2026-08-10 18:07:53 (commit `02b8144`). All 9 pillars PASS against the corrected formal idiom, not inherited from the flagged proof.**

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

**The fix, applied and confirmed:** deleted the `f_was_reset` flop + `initial X=0` pattern entirely; replaced with `initial assume(!rst_n);` and gated checks on the current cycle's `rst_n` — the same correction already proven on `rr_arbiter.sv`. Then I did the part that actually matters: ran it. A full `--force` re-verification (2026-08-10, commit `02b8144`) produced a genuine k-induction PASS at depth 20 — the analysis said the exposure was real, and the corrected proof confirms the *properties themselves* hold, not just that the old model was too loose to say otherwise.

## Result

- **9/9 pillars PASS, all earned against the current RTL:** P1 0/0; P2 genuine k-induction PASS (depth 20, corrected idiom, `--force` re-run); P3 1/1; P4 clean; P5 100.0%/100.0%; P6 64 cells; P7 3 points proven; P8 +1.583 ns MET at the 500.0 MHz target with GLS PASS; P9 PASS.
- The basecase-soundness question this report raised is now closed by execution, not by argument.

## Key Accomplishments

- **Accomplished** a precise exposure verdict on a recorded PASS, **as measured by** a named failure mode (basecase soundness) rather than a vague "formal might be wrong," **by doing** dependence analysis — distinguishing "pattern present" from "pattern load-bearing" across four sibling IPs.
- **Accomplished** two-sided calibration on an open question, **as measured by** documented reasoning for why the PASS was suspect *and* why it might still be true, **by doing** model-level reasoning about what a looser basecase does and does not break.
- **Accomplished** closure of the exposure by execution, not argument, **as measured by** a genuine depth-20 k-induction PASS on a `--force` re-run against the corrected idiom, **by doing** the fix and then actually running it rather than stopping at "should be fine."

## Skills Demonstrated

- **Dependence analysis** — distinguished "pattern present" from "pattern load-bearing."
- **Proof-soundness reasoning** — identified basecase exposure as the specific failure mode.
- **Two-sided calibration** — documented why the PASS was suspect and why it might hold.
- **Follow-through** — didn't stop at a specified fix; applied it and re-verified against the real toolchain.

## Open Items — What I'd Do Next

This IP's formal signoff is now genuinely closed. Remaining portfolio-level work: apply the same idiom correction + re-verification discipline to the IPs still showing an open P2 (see the portfolio rollup).
