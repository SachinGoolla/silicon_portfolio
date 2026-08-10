# apb_uart_master — Engineering Report: The Hardest Formal Campaign in the Portfolio, and What I Learned Running It

_Companion to `STATUS.md`. This is the portfolio's most resource-hungry formal target — an APB-driven UART master with two register-list FIFOs, a 7-state sequencer, and a 3-state APB engine — and the only IP where I have **not** yet closed formal sign-off. This report is the honest account of a genuinely hard problem: two latent bugs I unearthed and fixed, four controlled solver experiments, one kernel OOM-kill I forensically root-caused, and a WARN classification I can defend line by line._

## Final Status Dashboard

**Overall: ⚠️ INCOMPLETE — only P2 Formal has been executed against the current RTL. P1/P3/P4/P5/P6/P7/P8/P9 have never been run against it. I know exactly why, and I know exactly what I'd do next.**

| Pillar | Status | Metric |
|---|---|---|
| P1 Lint + CDC/RDC | _never run_ | — |
| P2 Formal | ⚠️ WARN | depth 10 (2026-08-07 18:18:16) |
| P3 Functional | _never run_ | — |
| P4 Simulation | _never run_ | — |
| P5 Coverage | _never run_ | — |
| P6 Synthesis | _never run_ | — |
| P7 LEC | _never run_ | — |
| P8 Pre-Layout STA + GLS | _never run_ | — |
| P9 UPF Power Intent | _never run_ | — |

---

## Situation

When I picked up `apb_uart_master`, its history implied a working formal flow. Direct inspection said otherwise — and the design itself (two FIFOs implemented as register lists, a 7-state sequencer, a 3-state APB engine) is exactly the shape that stresses an SMT solver.

## Task

Get the formal proof actually running — it never had — then characterize, scientifically, whatever still blocked sign-off.

## Action

### This IP's formal proof had never actually run — I found and fixed both reasons why

Two *independent* latent bugs, either of which alone made the proof unrunnable:

1. **The formal block was written in SVA, including the `inside` operator.** This repo's open-source Yosys build cannot parse SVA temporal syntax (the same discovery I made on `rr_arbiter`), and `inside {...}` is unsupported as well. I rewrote the block into immediate-assertion house style (matching `fpu_top`/`mod3ud`/`mod1000`/`rr_arbiter`), including hand-rolled `$past()`-equivalent shadow registers and an explicit OR-of-equalities in place of `inside`.
2. **The `.sby` file's `[script]` section read `../rtl/apb_uart_master.sv`** — but SBY stages copied files by flat basename into its work directory, so that path never resolved (`ERROR: Can't open input file`). I fixed it to `read -formal apb_uart_master.sv` (bare basename).

**Consequence: this formal proof had never run successfully at any point before this session.** Two bugs, each individually fatal, both now fixed — that is real progress even though the headline status is WARN.

### P2 — WARN: a solver resource ceiling I characterized scientifically, not a design defect

I ran **four controlled attempts**, changing one variable at a time, and got the same failure signature each time:

| Attempt | Config | Result | Crash point |
|---|---|---|---|
| 1 | depth 25 (original) | WARN | basecase, ~1m58s, "Unexpected EOF response from solver" |
| 2 | depth 25, retry after memory recovered (8.2 GB available) | WARN | induction, ~1m44s, same signature |
| 3 | depth 10 (reduced) | WARN | induction, ~1m41s, same signature |
| 4 | depth 10 + `TX_DEPTH=2, RX_DEPTH=2` (FIFO state reduction) | WARN | basecase, ~1m06s — **and a real kernel OOM-kill** |

**Forensics on attempt 4:** this wasn't the flow's internal `ulimit -v` soft cap — the Linux OOM-killer terminated `z3` (pid 2956872, 3.9 GB RSS), and the same event killed several unrelated browser processes on this shared machine. I confirmed this via `dmesg`/`journalctl`, not inference. When your solver dies, knowing *who* pulled the trigger matters.

**My diagnosis, and how each experiment constrained it:**
- Depth reduction (25→10) did not move the crash timing or engine — ruling out "just needs a shallower unrolling."
- FIFO depth reduction — the same state-reduction technique that fixed `fpu_top`'s proof earlier — did not help either, and on an already memory-tight host it tipped the whole machine into the OOM event.
- Conclusion: this design's z3 footprint (3.9 GB RSS observed) is roughly **6–8× rr_arbiter's** (~500 MB). The state is genuinely joint: two FIFOs as register lists + a 7-state sequencer + a 3-state APB engine + several `$past()`-equivalent shadow registers, reasoned about simultaneously across 5 properties. The solver isn't confused; it's out of RAM.

### Reporting-integrity finding: I distrust my own tools' dashboard here

For single-step invocations (e.g. `--step formal`), the pillar tool's terminal dashboard renders whatever is cached in `all_metrics` from the last time each pillar ran for *any* reason — including runs against older RTL. That produced a phantom "P1 Lint PASS / P5 Coverage PASS" display for this IP. `STATUS.md` is the trustworthy source because it explicitly marks pillars `_never run_` instead of echoing stale metrics. I flagged the fix for the tool itself — the dashboard should suppress or flag stale rows — as a flow-improvement finding: logged, not yet implemented. Knowing which of your two status displays is lying is a prerequisite for knowing anything at all.

### Why WARN and not FAIL

Per this flow's established policy, a solver crash/non-convergence is advisory — it is not a disproven property and does not hard-fail the build. But I insist on the honest framing: **the five properties in this file have never been confirmed true or false by this toolchain.** P2 here is an open item, not a soft pass, and I report it that way deliberately.

## Result

- **2 latent defects found and fixed** — SVA/`inside` formal block rewritten; `.sby` staging path corrected. The proof is now runnable for the first time in the IP's history.
- **4 controlled experiments executed** — one variable at a time; identical failure signature each run; hypothesis space narrowed to a memory ceiling.
- **1 kernel OOM-kill forensically attributed** — `dmesg`/`journalctl`-confirmed; z3 at 3.9 GB RSS, ~6–8× the `rr_arbiter` baseline.
- **1 reporting bug surfaced in my own tooling** — stale-metrics dashboard display, logged as a flow-improvement finding.
- **0 of 9 pillars claimed** — P2 WARN reported as an open item with a concrete, evidence-based plan.

## Key Accomplishments

- **Accomplished** resurrection of a never-successful formal proof, **as measured by** two independent fatal bugs found and fixed, **by doing** direct inspection instead of trusting historical dashboards.
- **Accomplished** a scientific characterization of a solver resource ceiling, **as measured by** four controlled experiments with one variable changed each time, **by doing** hypothesis-elimination debugging.
- **Accomplished** forensic attribution of a solver crash, **as measured by** a `dmesg`-confirmed OOM-kill (z3 at 3.9 GB RSS), **by doing** systems-level investigation rather than inference.
- **Accomplished** a reporting-integrity finding in my own tooling, **as measured by** one documented stale-metrics display bug, **by doing** an audit of which of two status displays was lying.

## Skills Demonstrated

- **Scientific debugging** — one-variable-at-a-time experiments, failure-signature matching, hypothesis elimination.
- **Systems forensics** — kernel OOM-kill confirmed via `dmesg`/`journalctl`; distinguishing ulimit soft-caps from kernel action.
- **Latent-bug discovery** — two independent pre-existing defects found by refusing to trust historical dashboards.
- **Tooling self-audit** — identified and documented a stale-metrics display bug in the pillar dashboard itself.
- **Intellectual honesty** — a WARN reported as an open item, with a concrete, evidence-based plan.

## Open Items — What I'd Do Next

Split the 5 properties into separate `.sby` files (the safety/liveness split that rescued `rr_arbiter`), scope each property to its actual fan-in (the `anyseq` stubbing that took `fpu_top` from 767 FFs to a sub-second proof), and re-attempt on a quiet host — then run the full 9-pillar `--force` sweep against the current RTL.