# uart_ctrl — Detailed Pillar Findings

_Companion to `STATUS.md`. **`STATUS.md`'s "P2 Formal ✅ PASS" is not trustworthy — read below before treating this IP as signed off.**_

**Overall: ⚠️ Formal signoff status unknown — the recorded "PASS" almost certainly never actually ran on this toolchain.**

---

## Critical finding: same broken SVA pattern as rr_arbiter/apb_uart_master (not yet fixed)

`uart_ctrl.sv`'s formal block uses SVA (`property ... endproperty` + `assert property (...)`) — confirmed by direct grep (10 SVA-syntax occurrences, zero immediate-assertion `assert(...)` occurrences). This is the exact pattern that, this session, was confirmed to hard-error on `sby -f *.sby` on this repo's open-source Yosys build (no Verific) — both the distro `apt` yosys and the full oss-cad-suite install reject `assert property`/`property...endproperty` regardless of `-sv`/`-formal` flags.

`STATUS.md` shows `P2 Formal ✅ PASS, depth 15, 2026-08-03 19:46:42` — this is almost certainly checkpoint carryover from before the toolchain issue was ever discovered, not a genuine proof, for exactly the same reason `rr_arbiter`'s and `apb_uart_master`'s identical-looking PASS entries turned out to be fake this session.

**This has not been fixed yet** — `uart_ctrl.sv`'s formal block still needs the same rewrite already applied to `rr_arbiter.sv` and `apb_uart_master.sv` (immediate assertions, `initial assume(!rst_n)`, no `$past`/`|->`/`|=>`/`inside`). This is a pending todo item, not yet started.

## P1, P3, P4, P5, P6, P8, P9 — as last recorded (not re-verified this session)

| Pillar | Status | Metric | When |
|---|---|---|---|
| P1 Lint + CDC/RDC | PASS | 0 err, 0 warn | 2026-08-03 19:46:42 |
| P3 Functional | PASS | 4/4 tests | 2026-08-03 19:46:42 |
| P4 Simulation | PASS | — | 2026-08-03 19:46:42 |
| P5 Coverage | PASS | 83.0% line, 64.8% toggle | 2026-08-03 19:46:42 |
| P6 Synthesis | PASS | 326 cells | 2026-08-03 19:46:42 |
| P8 Pre-Layout STA + GLS | PASS | 500.0 MHz target, TT MET, SS advisory (-15.775 ns) | 2026-08-03 19:46:42 |
| P9 UPF Power Intent | PASS | — | 2026-08-03 19:46:42 |

None of these pillars are affected by SVA parsing (they don't invoke `sby`), so there's no reason to doubt them specifically the way P2 is doubted — but they also haven't been re-confirmed with `--force` this session, and the RTL will need to change again once the formal block is rewritten, which will invalidate their checkpoints anyway.

## P7 — LEC: WARN (documented, legitimate)

Sequential LEC — Yosys k-induction doesn't converge on this design (RTL↔PDK state-encoding gap). This is the same, independently-confirmed limitation seen on `async_fifo` and `axi_lite_slave` (not a design defect) — cross-verified by P2 Formal + P8 GLS *in principle*, though P2's own trustworthiness is currently in question per above.

## Next step

Fix `uart_ctrl.sv`'s formal block using the same pattern already proven on `rr_arbiter`/`apb_uart_master`, then verify with `--force` (pending — see project todo list). Given `uart_ctrl` is comparatively small (326 cells, similar order to `rr_arbiter`'s 54), the resource-ceiling risk that blocked `apb_uart_master` is less likely here, but should still be confirmed rather than assumed.
