# rr_arbiter Build Choices

## P2 — Formal

`.sby`: `mode prove`, `depth 15`, `smtbmc --stbv z3`

Depth 15 is conservatively large for this design. The temporal property `BURST_ATOMIC` (`|=>` one-step lookahead) needs depth ≥ 2 to unfold. The remaining properties (ONEHOT0, NO_MASK_GNT, PP_ONEHOT) are single-step inductive and close at depth 1. Depth 15 matches fpu_top's formal convention and leaves headroom for future properties.

Cover mode runs automatically (p2_formal.py replaces `mode prove` → `mode cover`). The `COV_GRANT[k]` cover points verify all four grant slots are reachable from reset.

## P3 — Functional

5 cocotb tests, all `@cocotb.test()`. Each test instantiates a `RRArbiterRef` Python reference model that mirrors the RTL state machine exactly. Every cycle, the DUT output is compared against the reference — divergence fails immediately with a descriptive message.

Tests target the behavioral boundaries:
- `test_round_robin_all_active`: fairness guarantee (all seen within N×2 cycles)
- `test_mask_suppression`: power-gate boundary (masked requester = 0 grants)
- `test_burst_lock_hold`: AXI semantics (4-cycle lock, clean release on `last_i`)
- `test_priority_wrap`: pointer arithmetic (wraps from slot 3 back to slot 0)
- `test_single_requester`: degenerate case (one requester, gets all grants)

## P4 — Simulation

`tb_rr_arbiter.sv` drives the same 5 scenarios with embedded `$error` assertions. Verilator compiles with `--coverage --coverage-toggle --coverage-expr --trace-fst`. The arbiter's priority logic and FSM branches are fully exercised by the 5 test sequences → expected line coverage >95%.

## P6 — Synthesis

**Verified results (sky130 TT corner):** 54 cells, TT WNS +9.544 ns, FF WNS +9.774 ns. Equivalent gate count ≈ 20 NAND2, roughly 5% the size of fpu_top (1004 cells). This is expected — the arbiter has N=4 input requests, 8 flip-flops, and a pure combinational grant path with no arithmetic.

lpflow pre-filter not needed (arbiter has no power-gating cells in its own netlist). The PPA knob to sweep: rebuild with `chparam -set N_REQ {4,8,16}` to demonstrate area/timing trade-off. Results appear in `.pillar_history.jsonl`.

## P7 — LEC

**Verified: PASS** — SymbiYosys smtbmc z3, miter prove mode.

`rr_arbiter` is sequential (8 FFs: `grant_q[3:0]` + `pp_q[3:0]`), so the per-module combinational Yosys miniSAT path (used for fpu_top's combinational sub-modules) is bypassed. Instead, the full-design miter is fed to z3 SMT solver.

Key implementation detail: the miter's `assume()` applies the active-low reset (`rst_n == 1'b0`) for the first SMT timestep so both RTL-gold and gate instances start from a common, fully-determined reset state. After one clock, `init_seen` flips and equivalence assertions fire. Z3 proves RTL ≡ sky130 gate netlist for all reachable input sequences.

## P8 — STA

**Verified results:** TT WNS +9.544 ns MET (82.1 MHz achievable); SS WNS −0.092 ns advisory (extreme-corner pre-layout pessimism, same posture as fpu_top). GLS PASS — zero-delay Icarus gate simulation passes all 5 functional tests against the synthesized netlist.

SDC: single clock, 12.5 ns period (80 MHz). Matches fpu_top.sdc — both IPs share the same clock domain in the fpu_subsystem. Expected TT WNS: strongly positive (combinational depth ≈ 1 ns vs 10.5 ns available after I/O delays).
