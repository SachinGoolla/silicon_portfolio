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
- Formal mode prove depth=15: ONEHOT0 + NO_MASK_GNT + BURST_ATOMIC + PP_ONEHOT
- Cover mode (auto via p2_formal.py): COV_GRANT[k] for all k — reachability proof
- PPA sweep knob: N_REQ = 4 / 8 / 16 — run synth and check history
