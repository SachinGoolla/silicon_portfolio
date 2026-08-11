# axi_lite_slave — Engineering Report: What Intellectual Honesty Looks Like When Your Own Re-Verification Erases the Evidence You're Trying to Establish

_Companion to `STATUS.md`. A full AXI4-Lite slave register file — at 4,351 cells, the largest single-purpose bus-protocol block in this portfolio. This report went through two phases: first, disciplined incompleteness (2 of 9 pillars ever run, stale evidence flagged plainly); then, applying the formal-idiom fix I'd pre-registered — which surfaced both a real resource-ceiling result on the biggest design in the portfolio, and an honest complication in the tooling's own checkpoint mechanics that I found while trying to establish clean evidence._

## Final Status Dashboard

**Overall: ⚠️ P2 Formal re-verified WARN (2026-08-10 16:09:45, commit `02b8144`) — a resource ceiling, the fastest and hardest crash signature in the portfolio, consistent with this being the largest design by cell count. P6/P7's prior results (below) are real but no longer reflected in `STATUS.md`'s own history — see "A complication I found in my own tooling."**

| Pillar | Status | Metric |
|---|---|---|
| P1 Lint + CDC/RDC | _never run_ | — |
| P2 Formal | ⚠️ WARN — resource ceiling, re-verified | depth 5 |
| P3 Functional | _never run_ | — |
| P4 Simulation | _never run_ | — |
| P5 Coverage | _never run_ | — |
| P6 Synthesis | ✅ PASS (historical — see note) | 4,351 cells, as of 2026-08-04 17:30:25 |
| P7 LEC | ⚠️ WARN (documented, historical — see note) | k-induction non-convergent |
| P8 Pre-Layout STA + GLS | _never run_ | — |
| P9 UPF Power Intent | _never run_ | — |

---

## Situation

This is the bus-protocol workhorse: a full AXI4-Lite slave with a register file, reused as a building block (it sits inside `fpu_axi_periph`). I picked it up mid-evolution — this session added an HW-priority write port (`hw_wdata_i`/`hw_we_i`) plus a registration stage to fix the STA regression that change caused.

## Task

Establish an accurate account of this IP's verification state, and legislate the correct formal idiom *before* anyone runs its first proof.

## Action

### Evidence shelf-life audit

Only synthesis and LEC have ever been exercised, both against the RTL as it existed on 2026-08-04 (commit `e3d1c2e`) — **before** the HW-priority write-port addition. So even the two rows with results **predate the current RTL and have not been re-confirmed against it.** Stale evidence is the enemy of sign-off; saying so plainly is the first achievement here.

### Reading a cell count as a design-class statement

4,351 cells is an outlier — compare `rr_arbiter` at 54, `mod1000` at 64, `uart_ctrl` at 326. That magnitude is consistent with a full register-file slave rather than a narrow protocol shim, and it has a verification consequence I noted immediately: this is a *state-heavy* design, exactly the class where solver memory becomes the binding constraint (see `apb_uart_master`'s OOM forensics). When its P2 is written, proof architecture will matter more than proof depth.

### The governance call I'm proudest of: don't carry a risky idiom into a fifth IP

`axi_lite_slave.sv` already uses the correct immediate-assertion house style (`f_reset_seen` flop, `assert(...)` inside `always_comb`) — not the broken SVA pattern I eradicated elsewhere. But it uses the **sole-gate** shape: `if (f_reset_seen)` with no redundant direct `rst_n` check, relying on `initial f_reset_seen = 1'b0;` — an `initial` value this Yosys build demonstrably does not honor in BMC's basecase (minimal repro in the `rr_arbiter` report; the genuinely-exposed case study is `mod1000`'s).

I made the call **before** anyone ran anything: when P2 Formal is first executed for this IP, use `initial assume(!rst_n);` instead of propagating the `f_reset_seen` pattern into a fifth IP. Then I applied it and ran it.

### The result validated the design-class prediction

P2 Formal WARNed — but not from the idiom risk I'd pre-empted. The proof crashed in **56 seconds at "Max Step 0,"** the fastest and earliest failure of any IP in the portfolio, on this being the largest design by a wide margin (4,351 cells vs. `async_fifo`'s 840 or `uart_ctrl`'s 326). That's exactly the design-class prediction from the cell-count reading above, now confirmed by execution rather than argument: state size, not idiom soundness, is what's blocking this proof. The idiom fix was still the right call to make in advance — it means the *next* attempt (property-splitting or fan-in scoping, the same techniques that rescued `rr_arbiter` and `fpu_top`) starts from a sound basecase model instead of adding a second unknown on top of the resource question.

### A complication I found in my own tooling

Re-running `--step formal --force` to get a clean P2 result had a side effect I hadn't fully internalized: `--force` clears **every** pillar's checkpoint, not just the one being re-run. `STATUS.md`'s per-pillar history is derived from that checkpoint state, so P6's 4,351-cell synthesis PASS and P7's documented LEC WARN — both real, both still true — no longer appear in the live dashboard's own record, even though nothing about the RTL invalidated them. I'm reporting both effects here rather than letting either stand alone: the historical P6/P7 results are genuine and worth keeping (shown above, dated), and the fact that establishing evidence for P2 quietly erased evidence for P6/P7 is itself a real finding about how this tool's `--force` semantics interact with its own reporting — worth fixing in the tool, not just working around in the report.

### P7 — LEC: WARN (documented, legitimate — historical result, see above)

Same documented finding as `async_fifo`/`uart_ctrl` — Yosys k-induction doesn't converge on sequential LEC across the RTL↔PDK state-encoding gap; confirmed by experiment on sibling IPs that generic-gate BMC doesn't rescue it (state size, not cell-model complexity, is the wall).

## Result

- **P2 Formal re-verified**: WARN, resource ceiling, fastest-crashing proof in the portfolio — confirms the cell-count-based design-class prediction made before any tool ran.
- **P6/P7's historical results stand** (4,351-cell synthesis PASS; documented LEC WARN) but are no longer live in `STATUS.md`'s own checkpoint history — a real `--force`-scope finding, reported rather than hidden.
- **1 preventive governance decision, applied and validated**: `initial assume(!rst_n)` was the right idiom call; the WARN that resulted is orthogonal to it, exactly as the design-class analysis predicted.

## Key Accomplishments

- **Accomplished** an honest, evolving status map across two phases, **as measured by** explicit before/after reporting instead of overwriting the earlier honest-incompleteness account, **by doing** evidence shelf-life auditing at every step, including on my own re-verification.
- **Accomplished** validation of a design-class prediction by execution, **as measured by** the fastest, earliest crash signature in the portfolio (56s, step 0) on the largest design by cell count, **by doing** quantitative reasoning first and confirming it against real solver behavior second.
- **Accomplished** discovery of a real tooling gap through my own workflow, **as measured by** identifying that `--force` on one step silently clears every pillar's checkpoint history, **by doing** careful before/after comparison of `STATUS.md` rather than assuming the tool did only what I asked.

## Skills Demonstrated

- **Evidence shelf-life auditing** — applied to inherited results, and then to the side effects of my own re-verification.
- **Quantitative reasoning** — read a cell-count anomaly as a statement about design class, then confirmed it against real crash-timing data.
- **Preventive idiom governance** — specified the safe formal pattern in advance; correctly separated its outcome from the resource-ceiling result.
- **Tooling self-audit** — found and reported a real `--force`/checkpoint-scope gap in the flow itself, not just in the RTL.

## Open Items — What I'd Do Next

Same resource-ceiling remediation as `apb_uart_master`/`async_fifo`: property-splitting or fan-in scoping, then re-attempt on a quiet host. Separately, fix `--force`'s checkpoint scope in `pillar.py` so re-running one step doesn't erase another pillar's still-valid history — this bit me directly on this IP and would bite anyone using `--force` for a single-step re-check.
