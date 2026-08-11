# uart_axi_periph — Engineering Report: The First-Ever Composition of Two Independently-Verified IPs, and Two Real Bugs That Only Composition Could Expose

_Companion to `STATUS.md`. A new AXI4-Lite peripheral wrapping the UART stack (`apb_uart_master` + `uart_ctrl`) behind a software-programmable register map — the first entry in a 4-phase portfolio roadmap toward a hand-designed RISC-V SoC. Structurally this is `fpu_axi_periph`'s established composition pattern (`axi_lite_slave` + compute core + glue) applied to a new pair of leaves. What made this IP worth building first, deliberately, before the much harder CPU work: `apb_uart_master` and `uart_ctrl` had never been instantiated together anywhere in this repo despite matching ports — this was genuinely new integration surface, and it found two real glue-logic bugs that neither leaf's own standalone verification could have caught, because both bugs live entirely in the interaction between them._

## Final Status Dashboard

**Overall: ✅ SIGNED OFF — full `--step all --force` sweep, single coherent run, 2026-08-11 16:12:10 (commit `ede13c9`). 8/9 PASS, 1 documented WARN.**

| Pillar | Status | Metric |
|---|---|---|
| P1 Lint + CDC/RDC | ✅ PASS | 0 err, 0 warn |
| P2 Formal | ✅ PASS | depth 5, BMC + cover mode |
| P3 Functional | ✅ PASS | 5/5 cocotb tests |
| P4 Simulation | ✅ PASS | Verilator, `ALL TESTS PASSED`, `$finish` at 6 us |
| P5 Coverage | ✅ PASS | 87.0% line, 21.1% toggle |
| P6 Synthesis | ✅ PASS | 1,129 cells, sky130 |
| P7 LEC | ⚠️ WARN (documented) | k-induction non-convergent — same class as `async_fifo`/`axi_lite_slave`/`uart_ctrl`/`fpu_top` |
| P8 Pre-Layout STA + GLS | ✅ PASS | 100 MHz constraint, TT +6.228 ns MET, SS advisory (−23.401 ns, 31.6 MHz max-frequency readback at that corner); GLS PASS |
| P9 UPF Power Intent | ✅ PASS | 1 domain, WARN expected (Yosys UPF incomplete) |

---

## Situation

This portfolio's next phase targets a hand-designed RISC-V SoC. Before starting the CPU — the hard, multi-session part — the plan called for one bounded-risk composition to prove the pattern: a UART peripheral memory-mapped behind AXI4-Lite, following `fpu_axi_periph`'s already-proven `axi_lite_slave` + compute-core + glue shape. Two existing, independently-verified leaves were available: `apb_uart_master` (byte-stream-to-APB3 sequencer, autonomous init) and `uart_ctrl` (the APB3 slave it drives). Their ports matched exactly — `apb_uart_master`'s own header comment says "connect directly to uart_ctrl APB slave" — but a repo-wide check found neither had ever actually been wired together. Every prior verification of each was standalone.

## Task

Build `uart_axi_periph`, sign it off across all 9 pillars, and treat the `apb_uart_master`↔`uart_ctrl` wiring as genuinely new integration surface deserving real scrutiny — not a copy-paste reskin of `fpu_axi_periph`'s register map.

## Action

### Register map design: a shadow latch, chosen the hard way

The register map (`TXDATA`/`RXDATA`/`STATUS`/`CTRL`) started from an obvious-looking design: mirror `apb_uart_master`'s live `tx_ready_o`/`rx_valid_o`/`rx_data_o` straight into `STATUS`/`RXDATA`, and let a `CTRL[0]` write pulse `rx_ready_i` directly to pop its RX FIFO. P3's cocotb back-to-back test (`test_multi_byte_loopback_order`) caught this immediately: reading `RXDATA` for the second byte returned `X` in simulation.

Root cause: `axi_lite_slave`'s own HW-write path is a 2-cycle pipeline (`hw_wdata_i → hw_wdata_q → reg_q`). A poll issued right after popping byte N could still observe the *stale* `RX_VALID=1` describing byte N — not yet drained out of that pipeline — and misread it as byte N+1 having arrived, landing on `apb_uart_master`'s RX FIFO slot before byte N+1 had actually been pushed there. I fixed this with a single-entry shadow latch (`rx_have_byte_q`/`rx_byte_q`) that auto-drains `apb_uart_master`'s FIFO the instant a byte is available and the one-entry slot is free, so `RXDATA`/`STATUS.RX_VALID` describe exactly one well-defined byte with no pipelined-staleness window — the latch itself, not a delayed mirror of a live signal, is the source of truth.

That fix alone wasn't sufficient. Re-running the same test still failed — the shadow latch has the *identical* pipeline lag one level up (its own transition is *also* read back through `axi_lite_slave`'s 2-cycle path), and a poll issued immediately after the `CTRL[0]` ack write could still see the stale `RX_VALID=1` describing the byte just acked. The real fix was a software-protocol discipline, not another hardware layer: the driver must poll `RX_VALID==0` after acking, confirming the ack has actually propagated, before polling `RX_VALID==1` for the next byte. This is documented explicitly in the RTL header and implemented identically in both verification vehicles (`rx_byte()` in the cocotb suite and the SV testbench).

### The bug advisory review caught before any test ever would have

While reviewing the RX fix, I checked whether the same pipeline-lag hazard could exist on the TX side — it does, in the opposite direction. `TX_READY` mirrors `apb_uart_master.tx_ready_o` through the identical 2-cycle path; if software polled a stale `TX_READY=1` and wrote a second `TXDATA` byte while the first was still pending in the glue's own one-entry `tx_pending_q` register, the write would silently overwrite `tx_byte_q` and drop the queued byte. My own 5-test suite never sent more than 2 bytes with tight enough timing to expose this, so it would have shipped invisible. Fixed with a two-line guard (`tx_we_q && !tx_pending_q`) and a new formal property (`if (tx_we_q && tx_pending_q) assert(tx_data_valid)` — the pending byte survives a colliding write) before it ever became a test failure.

### What P2 formal did — and structurally could not — prove

Both `apb_uart_master` and `uart_ctrl` are `anyseq`-stubbed in `uart_axi_periph`'s own proof (three stub modules — `axi_lite_slave`, `apb_uart_master`, `uart_ctrl` — following `fpu_axi_periph_formal_stub.sv`'s exact pattern; a plain `blackbox` is rejected by the SMT2 backend). This is deliberate cone-of-influence scoping, the same discipline `fpu_axi_periph` and `fpu_top` already established: prove the new glue, don't re-prove submodules already signed off standalone. Pulling `uart_ctrl`'s real logic (326 cells, 5 RTL files) into this proof's state space is the exact design whose formal run triggered this session's aggregate multi-process memory abort on a different IP — must not recur here, and didn't.

**But that scoping has a real, honest cost, and it's worth stating plainly rather than leaving implicit: P2 formal PASSED twice — before and after the first RX fix — while the pipeline-staleness bug sat in the RX path both times.** The `anyseq` stub makes `rx_valid_o`/`rx_data_o` free every cycle; the proof structurally cannot observe "STATUS mirrors a value describing an already-consumed byte," because that hazard lives entirely in the relationship between the pipelined mirror and the real FIFO's push/pop sequencing — which stubbing deliberately deletes to keep the proof tractable. This is the same boundary shape as `fpu_top`'s "formal covers protocol, not arithmetic," except here there's a concrete, caught-by-P3-not-P2 bug to point at rather than an abstract caveat. The formal properties added after the fix (VALID-sticky on the TX handshake, sticky-until-acked on the RX latch, HW-ownership of `RXDATA`/`STATUS`) prove the glue's *own* state machine is internally sound — they do not, and structurally cannot, prove the glue behaves correctly against the real timing of the FIFOs it's stubbing out.

### Two Icarus syntax restrictions, found only at GLS

P4 (Verilator) and P3 (cocotb/Icarus behavioral) compiled the same testbench cleanly. P8's GLS pass — Icarus against the synthesized sky130 netlist — rejected two constructs neither of the other tools flagged: `break` inside a `for` loop (`sorry: break statements not supported`) and a bare `return` inside a task (`Cannot "return" from tasks.`). Both were in `wait_bit()`/`rx_byte()`'s polling logic; rewritten as loop-guard flags and an `if/else` restructure respectively. Filed alongside this repo's other confirmed Icarus-GLS-mode restrictions (no `automatic` variables inside `begin` blocks, no module parameters on a synthesized netlist).

### The GLS wall-clock ceiling, and a scoped-down GLS test as the honest fix — not a bigger budget

The first working GLS compile still failed: `apb_uart_master`/`uart_ctrl` have no parameter override on a synthesized netlist (the standard `` `ifdef GLS `` split, same as `uart_ctrl`'s own testbench), so GLS falls back to their default `CLK_FREQ=50MHz`/`BAUD_RATE=115200` → `BRDIV=26` → a real UART frame costs ~4,320 core clock cycles. Unlike `uart_ctrl`'s own standalone testbench (which *is* the direct APB master and can force `BRDIV=0` with a direct register write immediately after reset), `uart_axi_periph`'s testbench only has AXI-Lite access — `apb_uart_master` autonomously owns and programs `BRDIV`, with no path for software to override it.

My first instinct was to raise the poll budget. That was the wrong instinct: interpreted gate-level Icarus simulation evaluates all 1,129 synthesized primitives' behavioral models per clock edge, and a 200,000-poll experiment blew straight through `pillar.py`'s own 120-second GLS wall-clock ceiling without completing even one byte — more budget doesn't fix a per-cycle cost problem, it just burns more of a shared host's compute finding that out. The actual fix was scoping down what GLS re-proves: the full-baud serial round-trip (`T2`/`T3`) is already exhaustively covered by P3 cocotb and P4 Verilator, both at `BRDIV=0` fast-sim — re-running the identical protocol timing a third time, under a simulator that's orders of magnitude slower per cycle, buys zero marginal verification value for a real wall-clock cost this host can't absorb. `T2`/`T3` are skipped in GLS mode with an explicit, logged reason; a new `T2b` exercises the TX glue's FIFO-push path at gate level (`TX_READY` returns in a handful of cycles, independent of `BRDIV` — only the serial *drain* that follows is baud-rate-slow), so the TX glue is still gate-verified within budget. The RX shadow latch has no equivalent shortcut — it can only be set by a byte actually completing serial reception — so it is honestly GLS-*un*verified by construction; that gap is covered by P3/P4 at full rigor instead, not silently left uncovered.

One more thing this scoping caught before it shipped: the original testbench printed `T2 PASS`/`T3 PASS` unconditionally, even in the run where `rx_byte()` had already logged real errors — exactly the "fake PASS" class this portfolio's `uart_ctrl` report exists to warn about. Every PASS message is now gated on the test's own error-count delta, not printed unconditionally.

## Result

- **Full 9-pillar sweep, single coherent run**, 2026-08-11 16:12:10 (commit `ede13c9`) — 8/9 PASS, 1 documented WARN, `--step all --force` after each pillar had already been individually confirmed.
- **Formal:** depth-5 BMC + cover mode PASS, scoped to the new TX/RX glue only; all three real submodules `anyseq`-stubbed. Explicitly does not, and cannot, cover the pipeline-timing interaction that P3 caught — stated as a real scope boundary, not implied coverage.
- **Functional:** 5/5 cocotb tests — reset/init, single-byte loopback, back-to-back multi-byte loopback (the test that found both real bugs), SLVERR, no-op ack safety.
- **Simulation:** Verilator self-checking TB, `ALL TESTS PASSED`, clean to `$finish`.
- **Coverage:** 87.0% line / 21.1% toggle — first-pass baseline for a new IP; toggle headroom is the real next lever (same pattern as `fpu_axi_periph`'s 16.3% baseline).
- **PPA:** 1,129 cells (`uart_ctrl` 326 + `apb_uart_master` + `axi_lite_slave` + glue). TT MET at the 100 MHz constraint with +6.228 ns margin (measured, not guessed); SS −23.401 ns (31.6 MHz max-frequency readback at that corner) is the standard pre-layout extreme-corner advisory.
- **LEC:** WARN — same documented sequential-LEC wall as every other fully-sequential IP in this portfolio (no purely-combinational submodule candidates the way `fpu_top` has); cross-verified by P2 Formal + P8 GLS instead.
- **GLS:** PASS — register/init/AXI-path and TX-glue-push equivalence confirmed at gate level; full-baud serial loopback and the RX shadow latch are explicitly out of GLS's scope for wall-clock-cost reasons, covered instead by P3/P4.

## Key Accomplishments

- **Accomplished** the first-ever verified composition of `apb_uart_master` and `uart_ctrl` in this repo, **as measured by** a passing 9-pillar sweep on genuinely new integration wiring, **by doing** direct port-list comparison to confirm the connection was mechanical, then real functional-test attention rather than assuming the pairing "just works" because each half was independently signed off.
- **Accomplished** finding and fixing a real pipeline-staleness race that only composition could expose, **as measured by** a single-entry shadow latch replacing a naive live-signal mirror, verified by the exact back-to-back test that caught the original bug, **by doing** root-cause analysis into `axi_lite_slave`'s own HW-write pipeline depth rather than patching the symptom.
- **Accomplished** catching a second, opposite-direction instance of the same bug class before it ever became a test failure, **as measured by** a two-line RTL guard plus a new formal property, **by doing** proactive review of the TX path once the RX root cause was understood, instead of stopping at the one bug a test happened to catch.
- **Accomplished** an honest statement of formal's real coverage boundary, **as measured by** documenting that P2 passed twice while the RX bug was still present, and explaining structurally why the `anyseq` stub could never have caught it, **by doing** the same scope-honesty discipline `fpu_top`'s report established, applied here to a bug that's concrete rather than hypothetical.
- **Accomplished** resolving a real GLS wall-clock ceiling without burning further shared-host compute chasing a bigger budget, **as measured by** a scoped-down, explicitly-logged GLS test plan (T2b) that still exercises the TX glue at gate level, **by doing** cost-model reasoning (interpreted gate-level per-cycle cost) instead of retrying the same approach with a larger number.
- **Accomplished** eliminating a testbench class of bug — unconditional PASS messages printing over live errors — **as measured by** every PASS now gated on a per-test error-count delta, **by doing** the same fake-PASS vigilance this portfolio's `uart_ctrl` report established, applied to my own new code rather than only to inherited code.

## Skills Demonstrated

- **Composition-first integration verification** — treated a "the ports match" pairing as genuinely unproven until tested, not assumed correct by transitivity from two standalone sign-offs.
- **Root-cause pipeline analysis** — traced an `X`-valued read through two full iterations (raw-signal mirror, then shadow-latch-through-the-same-pipe) to the actual mechanism, rather than patching the first plausible cause.
- **Proactive symmetric-bug hunting** — found the TX-direction twin of the RX bug by reasoning about the pattern, before any test exposed it.
- **Formal scope honesty under a concrete counterexample** — stated plainly that a passing proof coexisted with a real bug, and explained the structural reason why, rather than letting a green P2 imply more than it covered.
- **Cost-aware verification engineering** — recognized a wall-clock ceiling as a per-cycle-cost problem, not a budget problem, and scoped the test to what's actually unverified elsewhere rather than brute-forcing a slower simulator.

## Open Items — What I'd Do Next

Push toggle coverage with randomized register-level stimulus (current 21.1% baseline, no constrained-random yet — same next-lever pattern as `fpu_axi_periph`'s 16.3%). GLS's full-baud serial path remains permanently out of scope for wall-clock reasons on this host; if a faster gate-level simulator becomes available, revisit whether `T2`/`T3` can run there instead of staying RTL-only. Separately: `apb_uart_master`'s own standalone `STATUS.md` still shows only P2 ever run (WARN) — every other pillar `_never run_`. This sweep exercises that RTL through all nine pillars as a submodule, which is real coverage the leaf itself never had, but the leaf's own dashboard doesn't reflect it; worth backfilling `apb_uart_master`'s standalone sweep before the SoC composition pulls it in again. This IP is Phase 1, Step 1 of the RISC-V SoC roadmap — next up: `rv32i_core`, standalone, before composition into the full SoC.
