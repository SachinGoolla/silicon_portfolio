# mod3ud — Detailed Pillar Findings

_Companion to `STATUS.md`. Uses a formal wrapper module (`verification/mod3ud_formal.sv`), immediate-assertion style with `$past()` — different syntax shape from `mod1000`/`rr_arbiter` but confirmed parseable on this toolchain._

**Overall: ✅ per STATUS.md (2026-08-03 19:35:06), all 9 pillars PASS.**

| Pillar | Status | Metric |
|---|---|---|
| P1 Lint + CDC/RDC | PASS | 0 err, 0 warn |
| P2 Formal | PASS (see caveat below) | depth 30 |
| P3 Functional | PASS | 6/6 tests |
| P4 Simulation | PASS | — |
| P5 Coverage | PASS | 100.0% line, 100.0% toggle |
| P6 Synthesis | PASS | 32 cells |
| P7 LEC | PASS | 3 pts proven |
| P8 Pre-Layout STA + GLS | PASS | 1579.8 MHz target, +0.368 ns MET |
| P9 UPF Power Intent | PASS | — |

## Toolchain trust audit: P2 Formal

Two things worth separating here, both discovered this session while debugging `rr_arbiter`:

1. **`$past()` as a bare system function (not wrapped in `assert property`) does parse on this toolchain** — confirmed directly with a minimal repro. `mod3ud_formal.sv` uses `$past(!rst)` this way (inside a plain `always @(posedge clk) assert(...)` block, immediate-assertion style), so unlike `uart_ctrl`'s full SVA `assert property`/`property...endproperty` syntax, this file's syntax shape is plausible and not the known-broken pattern.

2. **The `initial init = 1'b0;` idiom** (same shape as `mod1000`'s `f_was_reset`, found this session to not be reliably honored by this Yosys build's BMC basecase) is present here too, but its blast radius looks narrower: `init` is set unconditionally (`always @(posedge clk) init <= 1'b1;`, no reset gating at all) on the very first clock edge, so by step 1 it's `1` regardless of whatever arbitrary value it started with at step 0. The transition-sanity assertion is additionally gated by `$past(!rst)`, so it only fires once a real prior cycle exists — reducing (though not proving zero) exposure to a spurious step-0 state the way `mod1000`'s more state-dependent counter assertions are exposed.

**Net assessment**: lower risk than `mod1000`'s case, but still not independently re-confirmed with the corrected `initial assume(!rst)` idiom this session. Worth a `--force` re-run to confirm rather than assume, same as every other IP using this pattern.

## P6/P7/P8 — no findings

32 cells, 3 LEC points proven, comfortable timing margin (+0.368 ns at 1579.8 MHz, small design).
