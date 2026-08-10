# apb_uart_master — Detailed Pillar Findings

_Companion to `STATUS.md`. Only P2 Formal has actually been executed against the current RTL as of this report — see "Scope" below before reading the rest as a signoff claim._

**Overall: ⚠️ INCOMPLETE — only P2 Formal has been run this session; P1/P3/P4/P5/P6/P7/P8/P9 have never been run against the current RTL.**

---

## Scope note (read this first)

This IP's formal block was rewritten this session (SVA → immediate assertions — see "Background" below). Only `--step formal` has been re-run since that edit. `STATUS.md` correctly shows every other pillar as `_never run_`. **Do not trust the "P1 Lint PASS / P5 Coverage PASS" that sometimes appears in this tool's terminal dashboard summary** for a single-step invocation (e.g. `--step formal`) — that table displays whatever is cached in `all_metrics` from the last time each pillar ran for *any* reason (including runs before this RTL change), not confirmation that pillar passed against the *current* code. `STATUS.md`'s per-pillar table is the trustworthy source — it explicitly marks pillars `_never run_` rather than echoing stale metrics. This distinction is worth fixing in the tool itself (the terminal dashboard should probably suppress or flag stale rows the same way STATUS.md does) — flagged as a flow-improvement finding, not yet fixed.

---

## Background: this IP's formal proof was never real before this session

`apb_uart_master.sv`'s formal block was originally written in SVA, including the `inside` operator — neither is parseable by this repo's open-source Yosys build. Beyond that, the `.sby` file itself had a separate, independent bug: `[script]` read `../rtl/apb_uart_master.sv`, but SBY stages copied files by flat basename in its work directory, so that path never resolved (`ERROR: Can't open input file`). **This formal proof has never actually run successfully at any point before this session** — both bugs are now fixed:
- RTL rewritten to immediate-assertion house style (matching `fpu_top`/`mod3ud`/`mod1000`/`rr_arbiter`), including hand-rolled `$past()`-equivalent shadow registers and an explicit OR-of-equalities in place of `inside {...}` (also unsupported).
- `apb_uart_master.sby`'s `[script]` fixed to `read -formal apb_uart_master.sv` (bare basename).

## P2 — Formal: WARN (real solver resource ceiling, not a design defect — but not yet resolved)

**Four attempts, same failure signature each time:**

| Attempt | Config | Result | Crash point |
|---|---|---|---|
| 1 | depth 25 (original) | WARN | basecase, ~1m58s, "Unexpected EOF response from solver" |
| 2 | depth 25, retry after memory recovered (8.2GB available) | WARN | induction, ~1m44s, same signature |
| 3 | depth 10 (reduced — no effect on signature) | WARN | induction, ~1m41s, same signature |
| 4 | depth 10 + `TX_DEPTH=2,RX_DEPTH=2` (FIFO state reduction) | WARN | basecase, ~1m06s, same signature — **and this specific attempt triggered a real kernel OOM-kill**, not just the internal `ulimit -v` soft cap: `z3` (pid 2956872, 3.9GB RSS) was killed by the Linux OOM-killer, which in the same event also killed several unrelated Brave browser processes on this shared machine. Confirmed via `dmesg`/`journalctl`, not inferred. |

**Diagnosis:** depth reduction (25→10) did not change the crash timing or engine — ruling out "just needs a shallower unrolling." Reducing FIFO depth (state reduction, the same technique that fixed `fpu_top`'s formal proof earlier this session) also did not help, and in the one attempt where memory was already tight, tipped the whole machine into a real OOM event. This design's z3 memory footprint (3.9GB RSS observed) is roughly 6-8x rr_arbiter's (~500MB) — `apb_uart_master` has meaningfully more state (two FIFOs implemented as register lists + a 7-state sequencer + a 3-state APB engine + several `$past()`-equivalent shadow registers) that the solver has to reason about jointly across 5 properties.

**Not yet tried / possible next steps:**
- Splitting the 5 properties into separate `.sby` files (like `rr_arbiter`'s safety/liveness split) so each proof carries less combined state — the technique that worked for `rr_arbiter`'s liveness property.
- Scoping each property to only the submodules in its actual fan-in (the technique that fixed `fpu_top`) — harder here since these properties inherently span the sequencer + APB engine interaction, but worth investigating per-property.
- Re-attempting once the host has confirmed headroom (this session hit a genuinely overloaded shared machine — Cline at 3.6GB RSS, a Minecraft server at 2.4GB, other concurrent Claude Code sessions — independent of this repo's tooling).

**Current classification is WARN, not FAIL** — per this flow's established policy (see `_pillar_note()` in `pillar.py`), a solver crash/non-convergence is advisory, not a disproven property, and does not hard-fail the build under the hard-gate policy. This is honest but incomplete: **the properties in this file have never been confirmed true or false by this toolchain.** Treat P2 as an open item, not a soft pass.

## P1, P3, P4, P5, P6, P7, P8, P9 — never run against current RTL

No findings to report — these have not been executed since the formal-block rewrite. The prior terminal dashboard's cached display of "P1 PASS / P5 PASS" reflects an earlier, unrelated run and should not be read as current confirmation (see Scope note above).
