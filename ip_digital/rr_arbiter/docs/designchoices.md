# rr_arbiter Design Choices

## Key numbers (post-synthesis — fill from P6/P8 reports)

| Metric | Value | Notes |
|---|---|---|
| Sky130 cells (N=4) | P6 result | Run `pillar --top rr_arbiter --step synth` |
| TT WNS | P8 result | Same 80 MHz domain as fpu_top |
| Formal: ONEHOT0 | PROVED depth=15 | z3 k-induction |
| Formal: BURST_ATOMIC | PROVED depth=15 | temporal: one-step `\|=>` |
| Cocotb tests | 5/5 PASS | round-robin, mask, burst, wrap, single |

---

## Why registered grant (not combinational)?

A combinational grant creates a path: `req_i → priority logic → grant_o → downstream mux → FF`. For N=4 this is ~4 logic levels. With 2 ns I/O delays that's tight at 80 MHz.

Registering the grant breaks the combinational chain. The grant resolves in cycle N; downstream logic reads it in cycle N+1 with a full clock period. This costs one cycle of latency but eliminates the timing concern at all N_REQ values.

## Why one-hot priority pointer?

Binary pointer requires a decoder to generate the priority mask (`1 << ptr`), adding a decode stage before the priority tree. One-hot pointer directly drives the mask computation: `prio_mask = ~(pp_q - 1)`. Net savings: one gate level and one parameter (no need to size the binary counter vs. the one-hot register separately). The rotate update (`{pp[N-2:0], pp[N-1]}`) is a single wiring operation — no logic gates.

## Why `mask_i` not `req_i` masking?

Masking at the requester side (assert `req_i=0` when power-gated) works but puts policy knowledge inside the functional unit: each unit must know it is gated. The `mask_i` interface inverts this — the arbiter is told from the outside which slots to skip. This matches the actual hardware structure: `fpu_clk_gate_ctrl.sv` is the authority on which units are enabled and drives `mask_i` directly. No functional unit needs to know about power gating.

## Why not fixed-priority?

DIVSQRT has variable latency (2–27 cycles). Under fixed priority with DIVSQRT highest, a sequence of sqrt operations can hold the writeback bus and stall NONCOMP (which has 1-cycle latency) for up to 27 cycles. In a real processor that creates a write-back hazard visible to the ROB. Round-robin limits the worst-case stall to N=4 cycles regardless of unit latency.

## Burst lock: why `last_i` rather than a counter?

A counter requires knowing the burst length upfront and decrementing it. AXI4 burst lengths can be 1–256 beats (`ARLEN[7:0]`). Loading a counter adds a configuration register and a decrementor on the critical path. The `last_i` signal exactly mirrors AXI4's `WLAST`/`RLAST` semantics — no translation needed when this arbiter is integrated into an AXI crossbar.

## Formal: why `mode prove` (not BMC)?

Safety properties like `$onehot0(grant_o)` are inductive: they hold in reset and are preserved by every transition. BMC (bounded model checking) at depth D only verifies the property for the first D cycles — it does not prove it holds forever. `mode prove` with z3 k-induction extends the verification to all reachable states. For an arbiter that runs for billions of cycles in production silicon, this distinction matters.
