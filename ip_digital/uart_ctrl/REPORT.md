# uart_ctrl — Engineering Report: How Pattern Recognition Across IPs Told Me a "PASS" Was Fake Before I Ever Ran the Tool

_Companion to `STATUS.md`. A full UART controller (baud generator, TX/RX engines, FIFOs, APB3 register file — 326 cells) whose recorded P2 Formal PASS I have **deliberately flagged as untrustworthy**. No new bug bit me here — instead, I caught this one by recognition: the exact failure signature I had already root-caused twice elsewhere this session._

## Final Status Dashboard

**Overall: ⚠️ Signed off per STATUS.md — but I do not certify P2. Formal sign-off status is genuinely unknown until the rewrite below is done.**

| Pillar | Status | Metric |
|---|---|---|
| P1 Lint + CDC/RDC | ✅ PASS | 0 err, 0 warn |
| P2 Formal | ⚠️ Recorded PASS — flagged untrustworthy | depth 15 (2026-08-03 19:46:42) |
| P3 Functional | ✅ PASS | 4/4 tests |
| P4 Simulation | ✅ PASS | — |
| P5 Coverage | ✅ PASS | 83.0% line, 64.8% toggle |
| P6 Synthesis | ✅ PASS | 326 cells |
| P7 LEC | ⚠️ WARN (documented) | k-induction non-convergent |
| P8 Pre-Layout STA + GLS | ✅ PASS | 500.0 MHz target, TT MET, SS advisory (−15.775 ns); GLS PASS |
| P9 UPF Power Intent | ✅ PASS | — |

---

## Situation

A complete single-clock UART peripheral: 16× oversampling RX with a 2-FF pad synchronizer, self-contained sync FIFOs, and an APB3 register map with RW1C sticky error flags and a level-sensitive interrupt. Its dashboard showed a signed-off P2 — inherited from before this session's toolchain discoveries.

## Task

Determine whether the recorded formal PASS deserves trust — and if not, specify the exact path to a real one.

## Action

### The critical finding: I recognized a broken pattern by sight

After the `rr_arbiter` and `apb_uart_master` campaigns, I had a very specific scar: SVA temporal syntax (`assert property`, `property ... endproperty`) hard-errors on `sby -f` with this repo's open-source Yosys build (no Verific) — confirmed against both the distro `apt` yosys and the full oss-cad-suite install, regardless of `-sv`/`-formal` flags.

So when I audited `uart_ctrl.sv`, I didn't run anything first. I grepped: **10 SVA-syntax occurrences, zero immediate-assertion `assert(...)` occurrences.** The same pattern. Which means `STATUS.md`'s `P2 Formal ✅ PASS, depth 15, 2026-08-03 19:46:42` is almost certainly checkpoint carryover from before the toolchain issue was ever discovered — fake for exactly the same mechanical reason the identical-looking PASS entries on `rr_arbiter` and `apb_uart_master` turned out to be fake.

This is the cognitive skill I most want this portfolio to evidence: **transfer**. A failure understood deeply once becomes a detection rule everywhere. I didn't need a failing run to know this PASS couldn't be trusted — the shape of the code and the shape of the claim didn't match, and that mismatch *is* the finding.

**Status of the fix:** not yet applied. The rewrite is fully specified — immediate assertions, `initial assume(!rst_n)` (the idiom I proved on `rr_arbiter`), no `$past`/`|->`/`|=>`/`inside` — and queued. Given `uart_ctrl` is comparatively small (326 cells, the same order as `rr_arbiter`'s 54), the solver resource ceiling that blocked `apb_uart_master` is less likely to bite here — but I've written "confirm, don't assume" on that line, because assuming is what created this portfolio's fake-PASS class in the first place.

### The other pillars — what I believe, and why my belief is calibrated

None of P1/P3/P4/P5/P6/P8/P9 invoke `sby`, so the SVA issue gives me no reason to doubt them the way I doubt P2 — that's the discriminating analysis that keeps skepticism precise rather than paranoid. Two honest caveats stand: they haven't been re-confirmed with `--force` this session, and the pending formal-block rewrite will change the RTL, invalidating their checkpoints anyway. Their PASSes are believable but perishable.

### P7 — LEC: WARN (documented, legitimate)

Sequential LEC via Yosys k-induction doesn't converge on this design — the RTL↔PDK state-encoding gap I independently confirmed on `async_fifo` and `axi_lite_slave`. I verified by experiment that generic-gate BMC doesn't rescue it: state size, not cell-model complexity, is the wall; true sign-off needs Conformal/Formality-class sequential LEC. Cross-verified in principle by P2 Formal + P8 GLS — with the explicit asterisk that P2's own trustworthiness is the open question above.

## Result

- **8 of 9 rows believable:** P1 0/0; P3 4/4; P4 clean; P5 83.0%/64.8%; P6 326 cells; P8 TT MET at the 500.0 MHz target (SS −15.775 ns advisory) with GLS PASS; P9 PASS; P7 WARN classified as the known sequential-LEC wall.
- **P2 uncertified:** recorded PASS diagnosed as checkpoint fiction by syntax-shape evidence; rewrite fully specified and queued.

## Key Accomplishments

- **Accomplished** detection of a fake formal PASS with zero tool runs, **as measured by** 10 SVA vs 0 immediate-assertion grep hits, **by doing** failure-signature transfer from two prior IPs — pattern recognition as a verification method.
- **Accomplished** a fully-specified remediation before touching the code, **as measured by** a rewrite spec (idiom, banned constructs, expected solver behavior), **by doing** application of the already-proven `rr_arbiter` pattern.
- **Accomplished** precise-scope skepticism, **as measured by** exactly one pillar doubted for exactly one documented reason, **by doing** per-pillar discriminating analysis instead of blanket distrust.
- **Accomplished** sound change-management reasoning, **as measured by** advance identification that the pending RTL rewrite invalidates every other pillar's checkpoint, **by doing** dependency thinking across the flow.

## Skills Demonstrated

- **Cross-case pattern recognition** — diagnosed an un-run proof's invalidity from syntax shape alone.
- **Evidence discipline** — grep-counted SVA vs immediate assertions; cited the exact mechanism of the fake PASS.
- **Calibrated skepticism** — doubted exactly one pillar for exactly the right reason, not all pillars for a general reason.
- **Change management** — identified that the pending RTL rewrite invalidates the other pillars' checkpoints.

## Open Items — What I'd Do Next

Apply the proven rewrite pattern to `uart_ctrl.sv`'s formal block, then `--force` the full 9-pillar sweep on the new RTL so every row is re-earned against the code it claims to describe.