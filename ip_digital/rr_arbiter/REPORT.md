# rr_arbiter — Engineering Report: How I Turned a Silently-Fake Formal PASS into a Genuine 9/9 Sign-off

_Companion to `STATUS.md`. An N-way burst-aware masked round-robin arbiter (54 cells, 8 FFs) built to serialize the FPU writeback bus — and the IP where I learned to audit the tool before auditing the design. Verified via a full `--force` run on 2026-08-04 19:25 (commit `e3d1c2e`)._

## Final Status Dashboard

**Overall: ✅ 9/9 PASS — every row defensible, none inherited.**

| Pillar | Status | Metric |
|---|---|---|
| P1 Lint + CDC/RDC | ✅ PASS | 0 errors, 0 warnings; 1 advisory async-reset flag; 0 unsynced crossings |
| P2 Formal | ✅ PASS (re-proven, not carried over) | Safety depth 15 + liveness depth 8, z3 k-induction |
| P3 Functional | ✅ PASS | 5/5 cocotb tests vs cycle-accurate Python reference |
| P4 Simulation | ✅ PASS | Verilator, clean to `$finish`, FST captured |
| P5 Coverage | ✅ PASS | 100% line / 100% toggle / 100% expression |
| P6 Synthesis | ✅ PASS | 54 cells, sky130 TT |
| P7 LEC | ✅ PASS | 8 points proven, z3 miter-prove |
| P8 Pre-Layout STA + GLS | ✅ PASS | 82.1 MHz achievable vs 80 MHz target; TT MET; SS −0.092 ns advisory; GLS PASS |
| P9 UPF Power Intent | ✅ PASS | 1 always-on domain (PD_TOP), minimal intent |

---

## Situation

`fpu_top` integrates four functional units with asymmetric latencies (NONCOMP 1 cycle, CVT 2, FMA 6, DIVSQRT 2–27). Two units can complete on the same cycle and contend for one writeback bus; without arbitration that is a bus fight corrupting both results. This arbiter exists to serialize the bus with *provable* fairness. When I picked up the IP, its dashboard already read "P2 Formal: PASS" — a comfortable green checkmark with a history behind it.

## Task

Own the arbiter end to end: bring it through all nine pillars of the sign-off flow, with formal properties that prove what the integration contract actually needs — mutual exclusion, mask respect, burst atomicity, bounded wait — rather than properties that merely exist.

## Action

### I refused to trust the green checkmark

The formal block was written in full SVA (`assert property`, `disable iff`), and I knew this repo pins an open-source Yosys build without Verific — a combination that cannot parse SVA temporal syntax at all. A PASS under a tool that cannot read the properties is not a PASS; it is an absence of evidence dressed as one. I ran `sby -f rr_arbiter.sby` by hand. It hard-errored, every time, on both the distro yosys and the full oss-cad-suite install. The historical PASS was checkpoint carryover: `is_checkpoint_valid()` had been skipping re-runs because file mtimes hadn't changed. My first achievement on this IP was not a fix — it was detecting that a sign-off artifact everyone trusted was fabricated by caching logic. That instinct set the tone for the session and later paid off on `apb_uart_master` and `uart_ctrl`.

### Bug #1: `initial X = const` is not honored in this Yosys BMC basecase

While rewriting the formal block into immediate-assertion house style, my first proof produced a bizarre counterexample: a flop reading `1` at step 0 despite `initial f = 1'b0`. Instead of patching around it, I built a minimal repro, confirmed the toolchain behavior, and derived the correct idiom — `initial assume(!rst_n);`, a genuine basecase constraint — validated with a minimal k-induction PASS before trusting it in the real proof. This finding became a portfolio-wide audit axis (see `mod1000`, `mod3ud`, `async_fifo`, `fpu_top`, `axi_lite_slave`).

### Bug #2: my own property checked the wrong cycle

`NO_MASK_GNT` originally compared the registered `grant_o` against the *current* `mask_i` — but `grant_o` reflects the mask live one cycle earlier, at decision time. BMC found a real (if narrow) counterexample. I recognized a temporal-alignment bug in the verification code, not the RTL, introduced `mask_at_grant_q` to track the decision-time mask, and proved what the RTL was actually designed to guarantee. Knowing the difference between "the design is wrong" and "my model of the design is wrong" is a distinction I take seriously — this time it was the latter, and I fixed the right thing.

### Proof architecture: safety + liveness, divide and conquer

I split the proof into two `.sby` files so each engine run carries less combined state. **Safety (depth 15):** `ONEHOT0`, `NO_MASK_GNT`, `BURST_ATOMIC`, `PP_ONEHOT`. **Liveness (depth 8):** `STARVATION_FREE[k]` — a held, unmasked request is granted within `N_REQ` cycles — encoded as a wait counter implementing a hand-verified ranking-function argument (each losing cycle strictly closes the circular-scan distance to the waiter). Cover mode confirms every `cover()` is reachable, so the proofs are not vacuous. k-induction proves these for *all* reachable states; shallow convergence is the signature of a well-formed model, not a weak proof.

## Result

- **9/9 pillars PASS** on a forced re-run — no checkpoint inheritance anywhere.
- **Formal:** 5 property groups proven by z3 k-induction (depths 15/8); all covers reachable.
- **Functional:** 5/5 cocotb tests, each behavioral contract double-witnessed by an independent formal proof.
- **Coverage:** 100% line / 100% toggle / 100% expression — 18 lines analyzed, 0 uncovered.
- **PPA:** 54 cells, 82.1 MHz achievable vs the 80 MHz target; 8 LEC equivalence points; GLS clean.
- The synthesis census matched my hand-counted mental model (8 FFs = 4-bit `grant_q` + 4-bit `pp_q`) — a genuine design-understanding check.

## Key Accomplishments

- **Accomplished** a genuine 9/9 pillar sign-off, **as measured by** nine forced-run PASS rows at commit `e3d1c2e`, **by doing** a toolchain audit that exposed a checkpoint-cached fake PASS before any design work began.
- **Accomplished** a portfolio-reusable formal idiom, **as measured by** adoption across 6 IPs, **by doing** a minimal-repro root-cause of the `initial X=const` BMC basecase bug and deriving `initial assume(!rst_n)` as the correction.
- **Accomplished** safety *and* liveness sign-off on a fully open-source flow, **as measured by** k-induction convergence at depths 15 and 8 with reachable covers, **by doing** proof decomposition and a ranking-function liveness encoding.
- **Accomplished** full coverage closure, **as measured by** 100/100/100 line/toggle/expression, **by doing** contract-directed tests aimed at behavior rather than at metrics.

## Skills Demonstrated

- **Verification skepticism / toolchain auditing** — caught a fabricated PASS nobody had questioned.
- **Root-cause isolation** — minimal repros instead of shotgun debugging, twice in one IP.
- **Formal methods depth** — k-induction, ranking functions, vacuity checking, honest scope limits.
- **Temporal reasoning** — found the decision-time vs current-cycle misalignment in my own property.
- **Cross-pillar triangulation** — formal, functional, LEC, and GLS independently witnessing the same contracts.

## Open Items — What I'd Do Next

Constrained-random cocotb + scoreboard (P3), self-checking `$error` assertions in simulation (P4), FSM arc coverage via explicit `cover()` (P5), and the combined burst+liveness proof at greater depth when host resources allow (P2).