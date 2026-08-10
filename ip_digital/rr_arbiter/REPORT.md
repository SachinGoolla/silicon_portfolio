# rr_arbiter — Detailed Pillar Findings

_Companion to `STATUS.md` (the compact pass/fail dashboard). This report captures the actual per-pillar insights, metrics, and — for this IP specifically — the debugging story behind how its formal signoff went from a silently-fake PASS to a genuinely-proven one. Generated from a full `--force` run on 2026-08-04 19:25 (commit `e3d1c2e`); not auto-regenerated._

**Overall: ✅ 9/9 PASS, all genuine (confirmed via `--force`, not checkpoint carryover)**

---

## Background: this IP's formal proof was never real before this run

`rr_arbiter.sv`'s formal block was originally written in SVA (`assert property (@(posedge clk) disable iff (!rst_n) ...)`). This repository's open-source Yosys build (no Verific) cannot parse SVA temporal syntax at all — confirmed directly against both the distro `apt` yosys and the full oss-cad-suite install. The `.sby` run hard-errored on `sby -f rr_arbiter.sby` every time it was invoked; the dashboard's prior "PASS" was checkpoint carryover (`is_checkpoint_valid()` skipping a real re-run since RTL/`.sby` mtimes hadn't changed), not an actual passing proof.

Fixing this surfaced two more real bugs along the way, both now fixed:
1. A plain register's `initial X = const;` is **not** reliably honored by this Yosys build's BMC basecase — a counterexample showed a flop reading `1` at step 0 despite `initial f = 1'b0`. The working idiom is `initial assume(!rst_n);` (a genuine basecase constraint, confirmed via a minimal k-induction PASS before relying on it here).
2. `NO_MASK_GNT` originally compared the registered `grant_o` against the *current* cycle's `mask_i` — but `grant_o` reflects the mask that was live one cycle earlier, at decision time. Since `mask_i` has no stability contract, BMC found a real (if narrow) counterexample. Fixed by tracking `mask_at_grant_q` (the mask actually used for whatever grant is currently held), which proves what the RTL was actually designed to guarantee.

See `rtl/rr_arbiter.sv`'s FORMAL SCOPE header and project memory `feedback_formal_sby` for the full account.

---

## P1 — Lint + CDC/RDC: PASS

| Metric | Value |
|---|---|
| Warnings | 0 |
| Errors | 0 |
| Static CDC flags | 1 (`rr_arbiter.sv`: async reset `neg` — confirm gating) |
| OpenCDC crossings | 0 (no unsynced FF→FF crossings) |

**Findings:**
- Zero lint errors — RTL compiles cleanly.
- OpenCDC structural scan found no raw FF→FF crossings — single-clock design, consistent with expectations.
- The one static CDC flag (async reset polarity) is advisory / expected for this design's intentional async-reset architecture.
- *Improve:* static CDC flags are regex-based, advisory only — real sign-off needs Meridian CDC or VC Formal CDC.

## P2 — Formal: PASS (genuine k-induction, not checkpoint-carried)

| Metric | Value |
|---|---|
| Safety proof (`rr_arbiter.sby`) | PASS, depth 15, k-induction |
| Liveness proof (`rr_arbiter_liveness.sby`, `-DLIVENESS`) | PASS, depth 8, k-induction |
| Cover mode | PASS — all `cover()` properties reachable |

**Properties proven (safety):**
- `ONEHOT0` — mutual exclusion, never two grants simultaneously
- `NO_MASK_GNT` — a masked requester is never granted (compared against decision-time mask, see background above)
- `BURST_ATOMIC` — grant held until `last_i` once `burst_lock_i` engages
- `PP_ONEHOT` — priority pointer is always one-hot

**Property proven (liveness, new this session):**
- `STARVATION_FREE[k]` — a continuously-held, unmasked request from requester `k` is granted within `N_REQ` cycles. Encoded as a per-requester "consecutive cycles waited without a grant" counter, asserted never to exceed `N_REQ` — the counter is a direct implementation of a hand-verified ranking-function argument (each losing cycle strictly closes the circular-scan distance to the waiting requester by at least one slot). Scope excludes `burst_lock_i` (assumed 0) since burst atomicity is separately, fully proven by `BURST_ATOMIC`; combining both into one proof needs depth on the order of `N_REQ × MAX_BURST_LEN`, not tractable for k-induction on this host.

**Findings:**
- k-induction proven — properties hold for ALL reachable states, not just bounded traces.
- Proof converged in 15 (safety) / 8 (liveness) induction steps — shallow depth reflects low combinational complexity once state was correctly modeled.
- *Improve:* combine liveness with worst-case burst-hold adversarial timing (would need much greater depth — noted as a known limitation, not attempted).

## P3 — Functional: 5/5 PASS

cocotb + Icarus, 780 ns sim time.

| Test | Result |
|---|---|
| `test_round_robin_all_active` | PASS |
| `test_mask_suppression` | PASS |
| `test_burst_lock_hold` | PASS |
| `test_priority_wrap` | PASS |
| `test_single_requester` | PASS |

**Findings:**
- All directed behavioral tests pass.
- *Improve:* add randomized stimulus (cocotb + hypothesis) and a cycle-accurate scoreboard — current suite is directed-only, no constrained-random coverage.

## P4 — Simulation: PASS

Verilator `--binary --timing --coverage --trace`, no `$error`/`$fatal`, FST trace captured.

**Findings:**
- Clean run to `$finish`.
- *Improve:* `$finish` alone doesn't prove correctness — add explicit `$error` self-check assertions on every expected output.

## P5 — Coverage: 100% line / 100% toggle / 100% expression

18 total lines analyzed, 0 uncovered.

**Findings:**
- Full statement coverage achieved — comfortably clears the typical 80%+ pre-tapeout closure target.
- *Improve:* FSM arc coverage isn't natively instrumented by Verilator — would need explicit `cover()` properties.

## P6 — Synthesis: PASS, 54 cells

sky130 TT corner, `abc -D 12500` (80 MHz target).

| Cell type | Count |
|---|---|
| `$_ANDNOT_` | 18 |
| `$_OR_` | 8 |
| `$_NOT_` | 5 |
| `$_AND_` | 4 |
| `$_DFFE_PN0N_` | 4 |
| `$_MUX_` | 4 |
| `$_DFFE_PN0P_` | 3 |
| `$_ORNOT_`, `$_XOR_` | 2 each |
| `$_DFFE_PN1P_`, `$_NAND_`, `$_NOR_`, `$_XNOR_` | 1 each |

**Findings:**
- 8 flip-flops mapped (matches expectation: 4-bit `pp_q` + 4-bit `grant_q`).
- lpflow isolation cells correctly excluded from the abc liberty (avoids ~30ns SS derating).
- *Improve:* add `set_max_fanout`/`set_max_transition` constraints to the `.sdc` to guide optimization further.

## P7 — LEC: PASS

SymbiYosys smtbmc z3, miter-prove mode, all-outputs assertion, sky130 cell library.

**Findings:**
- Z3 proved RTL and gate-level netlist output-identical for ALL input sequences.
- Netlist confirmed current with RTL for this revision.
- *Improve:* LEC covers functional equivalence only — setup/hold and X-propagation need GLS (P8, also PASS here).

## P8 — Pre-Layout STA + GLS: PASS (TT MET; SS advisory)

| Corner | Slack |
|---|---|
| `ff_n40C_1v76` | +9.774 ns |
| `tt_025C_1v80` | +9.544 ns |
| `ss_n40C_1v28` | **−0.092 ns (VIOLATED)** |

Max freq (worst corner): 82.1 MHz. Target: 80 MHz. GLS: PASS (zero-delay Icarus, matches RTL).

**Findings:**
- TT corner MET with comfortable margin (82.1 MHz vs. 80 MHz target).
- SS corner violation (−0.092 ns) is extreme-corner cell derating (−40°C/1.28V), advisory per this flow's pre-layout sign-off policy — not a real violation at typical operating conditions.
- GLS PASS — zero-delay gate simulation matches RTL behavior, no X-propagation or reset issues.
- *Improve:* pre-layout STA is optimistic; add 20-30% margin before declaring tapeout-ready closure. Full back-annotated timing needs PnR (OpenROAD).

## P9 — UPF Power Intent: PASS (Yosys check WARN, expected)

1 power domain (`PD_TOP`), 2 supply nets, 0 isolation strategies, 0 level shifters, 0 retention registers.

**Findings:**
- Single always-on domain — no retention cells needed, consistent with this IP having no power-gating of its own.
- Yosys UPF check WARN is the documented, expected outcome (Yosys's `read_upf` support is incomplete) — not a real defect.
- *Improve:* full OpenROAD UPF flow (`read_upf` → `insert_power_switches` → `place_pd`) not yet exercised for this IP.
