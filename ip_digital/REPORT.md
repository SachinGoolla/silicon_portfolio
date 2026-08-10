# ip_digital — Final Stat Report: What Was Achieved, in Numbers

_Portfolio-level closeout for the 9 digital IPs in this folder, structured as Situation → Task → Action → Result with quantified achievement headlines ("Accomplished X, as measured by Y, by doing Z"). Every number below is traceable to the per-IP `REPORT.md` / `STATUS.md` files; nothing here is estimated._

**Scope:** 9 IPs — `rr_arbiter`, `fpu_top`, `fpu_axi_periph`, `async_fifo`, `uart_ctrl`, `axi_lite_slave`, `apb_uart_master`, `mod1000`, `mod3ud` — each put through the 9-pillar verification flow (P1 Lint+CDC · P2 Formal · P3 Functional · P4 Simulation · P5 Coverage · P6 Synthesis · P7 LEC · P8 STA+GLS · P9 UPF).

---

## Situation

Nine digital IPs — from a 32-cell common counter to a 767-flip-flop IEEE 754 FPU — each carrying a recorded verification status, some of it inherited from before the toolchain was fully understood.

## Task

Bring every IP through the automated 9-pillar sign-off flow with results that are earned, not cached — and state precisely, in numbers, what is proven, what is tested, and what remains open.

## Action

Audited the toolchain before the designs (exposing a checkpoint-cached fake-PASS class); root-caused two Yosys BMC/SVA issues with minimal repros; re-architected the flagship's formal proof around cone-of-influence stubbing; ran controlled one-variable-at-a-time experiments where the solver crashed; classified every WARN by mechanism; and rewrote each per-IP report as a situation-task-action-result account with a numbers-first dashboard.

## Result

7 of 9 IPs fully signed off; 66 of 81 pillar checks executed with 61 PASS results surviving audit; 0 design defects found by the flow; 4 latent bugs found and fixed; 3 toolchain/flow bugs root-caused; 3 fake formal PASSes detected. Full breakdown below; per-IP narrative in each `REPORT.md`.

---

## Headline numbers

| Stat | Value |
|---|---|
| IPs in portfolio | 9 |
| IPs fully signed off (9/9 pillars PASS or documented WARN) | **7 of 9** |
| Pillar checks executed | **66 of 81** (81%) |
| Pillar results: PASS surviving audit | **61** |
| Pillar results: recorded-but-discredited PASS | 1 (`uart_ctrl` P2 — caught and flagged) |
| Pillar results: documented WARN (tool limits, not design defects) | 4 (3× sequential-LEC convergence wall, 1× solver resource ceiling) |
| Design defects found by the entire flow | **0** |
| Functional tests passing | **49/49** across 7 IPs |
| LEC equivalence points proven (z3 miter-prove) | **24** |
| Cells synthesized (sky130) | **7,676** across 8 synthesized IPs (range 32 → 4,351) |
| Coverage | 3 IPs at **100% line + 100% toggle**; flagship FPU at 96.0% line |
| Fastest timing closure | **1579.8 MHz**, +0.368 ns MET (`mod3ud`) |
| Fake formal PASSes detected and corrected/flagged | **3** |
| Latent bugs found & fixed | **4** (2 un-runnable SVA formal blocks, 1 `.sby` staging-path bug, 1 temporal property bug) |
| Toolchain/flow bugs root-caused | **3** (Yosys `initial X=const` BMC basecase; SVA non-parse; stale dashboard metrics) |
| Formal proofs achieved | k-induction, depth 8–30, safety **and** liveness |

## Key accomplishments (X, as measured by Y, by doing Z)

- **Accomplished** a genuine 9/9 pillar sign-off on `rr_arbiter`, **as measured by** k-induction proofs at depth 15 (safety) + depth 8 (liveness), 100% line/toggle/expression coverage, 8 LEC points and 82.1 MHz vs an 80 MHz target, **by** detecting that the recorded PASS was checkpoint fiction, rewriting SVA into immediate assertions, and re-proving everything with `--force`.
- **Accomplished** a sub-one-second formal proof on the 767-flip-flop flagship FPU, **as measured by** depth-10 k-induction converging in < 1 s, **by** analyzing the property's cone of influence and stubbing all out-of-fan-in submodules with `anyseq` (767 FFs → ~0 state).
- **Accomplished** a portfolio-wide formal-risk audit across 6 IPs, **as measured by** a 3-tier exposure taxonomy (immune-by-construction / redundant-gate / sole-gate) with one corrected idiom (`initial assume(!rst_n)`) adopted as the house standard, **by** root-causing a Yosys BMC basecase bug with a minimal repro instead of trusting tool output.
- **Accomplished** forensic classification of `apb_uart_master`'s solver crashes as a resource ceiling rather than a design defect, **as measured by** 4 controlled experiments and a kernel-confirmed OOM-kill (z3 at 3.9 GB RSS, 6–8× baseline), **by** one-variable-at-a-time debugging plus `dmesg`/`journalctl` confirmation.
- **Accomplished** detection of a third fake PASS on `uart_ctrl` with zero tool runs, **as measured by** 10 SVA vs 0 immediate-assertion grep hits, **by** transferring a failure signature learned on two prior IPs — pattern recognition as a verification method.
- **Accomplished** a data-backed verification-strategy decision, **as measured by** a 16.3% toggle-coverage baseline on `fpu_axi_periph`, **by** tracing the gap to interface/datapath asymmetry and making the quantified case for constrained-random (UVM) closure.
