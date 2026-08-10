# CLAUDE.md — rr_arbiter IP Context

## Purpose
N-way burst-aware masked round-robin arbiter for the fpu_top writeback bus.
Arbitrates between N_REQ=4 functional units (NONCOMP/CVT/FMA/DIVSQRT) sharing
one 37-bit writeback bus (result[31:0] + fflags[4:0]).

## File locations
- RTL:          rtl/rr_arbiter.sv
- Formal:       verification/rr_arbiter.sby
- SDC:          verification/rr_arbiter.sdc
- UPF:          verification/rr_arbiter.upf
- Cocotb tests: verification/test_rr_arbiter.py
- Verilator TB: verification/tb_rr_arbiter.sv
- Docs:         docs/Microarchitecture.txt, docs/designchoices.md, docs/buildchoices.md

## Run all 9 pillars
```
cd /home/dada/silicon_portfolio
pillar --top rr_arbiter --ip-path ip_digital/rr_arbiter
```

## Non-obvious details
- grant_o is REGISTERED: appears in cycle N+1 after req_i asserted in cycle N
- pp_q is one-hot, maintained by reset (0001) and left-rotate on each grant
- mask_i excludes power-gated units; pointer still advances past masked slots
- burst_lock_i / last_i implement AXI4 WLAST semantics: lock on assert, release on last
- Formal properties are immediate assertions (`assert(...)`/`assume(...)`/`cover(...)`
  inside clocked always blocks), NOT SVA `assert property`/`property...endproperty` —
  this repo's open-source Yosys build (no Verific) does not parse SVA temporal
  syntax at all. This file used to be written in SVA and showed PASS on the
  dashboard, but that PASS was checkpoint carryover, not a real proof — the
  underlying .sby run always hard-errored. Fixed 2026-08-04; see rr_arbiter.sv's
  FORMAL SCOPE header for the full story and project memory feedback_formal_sby.
- `initial assume(!rst_n);` forces BMC's basecase through an actual reset before
  anything is checked — required because grant_q/pp_q have no `initial` value and
  BMC otherwise explores "rst_n=1, reset never happened" as a valid step-0 state.
  Do NOT use a mod1000-style `initial f_was_reset = 0` latched flag instead — this
  Yosys build does not reliably honor a plain register's `initial` value either
  (confirmed with a separate minimal repro); `initial assume(...)` is the one that
  actually constrains the basecase and was confirmed working.
- NO_MASK_GNT compares grant_o against `mask_at_grant_q` (mask captured at decision
  time), not the current cycle's mask_i — grant_o is registered, so a same-cycle
  comparison is a strictly stronger, undesigned claim that mask_i can violate by
  simply changing between decision and observation (BMC found this as a real
  counterexample). mask_at_grant_q mirrors grant_q's own hold/update conditions.
- Formal mode prove depth=15 (rr_arbiter.sby): ONEHOT0 + NO_MASK_GNT + BURST_ATOMIC + PP_ONEHOT
- Formal mode prove depth=8 (rr_arbiter_liveness.sby, `-DLIVENESS`): STARVATION_FREE[k] —
  a continuously-held, unmasked request is granted within N_REQ cycles, encoded as a
  per-requester "consecutive cycles waited" counter asserted `<= N_REQ`. Scope excludes
  burst_lock_i (assumed 0 — burst atomicity is separately proven by BURST_ATOMIC).
- Cover mode (auto via p2_formal.py): COV_GRANT[k] for all k — reachability proof
- PPA sweep knob: N_REQ = 4 / 8 / 16 — run synth and check history
