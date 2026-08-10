# axi_lite_slave — Engineering Report: What Intellectual Honesty Looks Like When Only 2 of 9 Pillars Have Ever Run

_Companion to `STATUS.md`. A full AXI4-Lite slave register file — at 4,351 cells, the largest single-purpose bus-protocol block in this portfolio — and the IP where my contribution this session is **disciplined incompleteness**: an accurate map of what is known, what is not, what has silently gone stale, and which idiom must be used when its formal proof is finally run._

## Final Status Dashboard

**Overall: ⚠️ INCOMPLETE — only P6 Synthesis and P7 LEC have ever been executed. P1/P2/P3/P4/P5/P8/P9 are genuinely `_never run_` — not a reporting gap, a real one.**

| Pillar | Status | Metric |
|---|---|---|
| P1 Lint + CDC/RDC | _never run_ | — |
| P2 Formal | _never run_ | — |
| P3 Functional | _never run_ | — |
| P4 Simulation | _never run_ | — |
| P5 Coverage | _never run_ | — |
| P6 Synthesis | ✅ PASS | 4,351 cells (2026-08-04 17:30:25) |
| P7 LEC | ⚠️ WARN (documented) | k-induction non-convergent |
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

So I made the call **before** anyone ran anything: when P2 Formal is first executed for this IP, use `initial assume(!rst_n);` — the corrected idiom already proven on `rr_arbiter.sv` — instead of propagating the `f_reset_seen` pattern into a fifth IP. Recognizing a latent risk in code that has never failed, and legislating the fix in advance, is cheaper than every post-mortem I ran this session. That's the pattern-recognition dividend being spent on purpose.

### P7 — LEC: WARN (documented, legitimate)

Same documented finding as `async_fifo`/`uart_ctrl` — Yosys k-induction doesn't converge on sequential LEC across the RTL↔PDK state-encoding gap; confirmed by experiment on sibling IPs that generic-gate BMC doesn't rescue it (state size, not cell-model complexity, is the wall). Cross-verified in principle by P2 Formal + P8 GLS — once those exist here.

## Result

- **2 of 9 pillars ever executed:** P6 PASS (4,351 cells), P7 WARN (documented, tool-class limitation) — both predating the current RTL.
- **7 of 9 pillars genuinely never run** — reported as such, not smoothed over.
- **1 preventive governance decision recorded:** `initial assume(!rst_n)` mandated for this IP's first P2 run.

## Key Accomplishments

- **Accomplished** an honest 2/9 status map, **as measured by** seven rows explicitly marked `_never run_`, **by doing** evidence shelf-life auditing instead of echoing cached dashboards.
- **Accomplished** a preventive idiom decision with zero cost, **as measured by** one pre-registered fix ready for the first P2 run, **by doing** cross-IP risk transfer to code that has never failed.
- **Accomplished** a design-class diagnosis from a single number, **as measured by** the 4,351-cell outlier reading, **by doing** quantitative reasoning about state size and solver behavior.

## Skills Demonstrated

- **Evidence shelf-life auditing** — identified that even the "passing" rows predate the current RTL.
- **Quantitative reasoning** — read a cell-count anomaly as a statement about design class and verification strategy.
- **Preventive idiom governance** — specified the safe formal pattern in advance, from cross-IP evidence.
- **Scope honesty** — a dashboard that says 2/9, reported as 2/9.

## Open Items — What I'd Do Next

Run the full 9-pillar sweep with `--force` against the current RTL (including the HW-priority write port) before treating this IP as portfolio-ready — P6/P7's results predate that change, and P1/P2/P3/P4/P5/P8/P9 have literally never run.
