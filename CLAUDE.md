# CLAUDE.md — Silicon Portfolio Project Context

## Purpose
RTL verification portfolio using a 9-pillar automated flow. Primary script: `scripts/pillar.py`.

## Critical paths (do not re-derive)
- Entry point: `scripts/pillar.py` — class `PillarFlow`
- Per-pillar modules: `scripts/pillars/p{1-9}_*.py` — each exposes `run(flow) -> str`
- Shared infra: `scripts/pillars/common.py` — colors, dataclasses, log parsers, Dashboard
- IP modules: `ip_digital/fpu/fpu_top/` — rtl/, verification/, build/, logs/
- PDK libs: `lib/*.lib` (gitignored symlinks — sky130 3 corners + NangateOpenCellLibrary)
- GLS cell models: `lib/sky130_fd_sc_hd.v` symlink → system PDK install (enables GLS)
- Python env: `.venv/` at repo root — `cocotb==2.0.1`, `pyuvm==4.0.1`
- CI: `.github/workflows/dv.yml` — pillars 1-3 only (no PDK libs in CI)
- Onboarding: `scripts/QUICKSTART.html` (open in browser/VSCode Live Preview)

## 9-Pillar architecture
| # | Name | Tool | Gate |
|---|------|------|------|
| 1 | Lint + CDC/RDC | Verilator `--lint-only` + static scan | 0 errors; CDC advisory |
| 2 | Formal | SymbiYosys/z3 k-induction + cover mode | PASS + cover reachable |
| 3 | Functional | cocotb 2.0.1 + pyUVM 4.0.1 / Icarus | 100% tests |
| 4 | Simulation | Verilator `--binary --coverage --coverage-toggle --coverage-expr --trace-fst` | no `$error`/`$fatal` |
| 5 | Coverage | `verilator_coverage` (line + toggle + expr) | advisory (or `--coverage-threshold N`) |
| 6 | Synthesis | Yosys RTL→gate netlist (lpflow cells pre-filtered) | synth completes, cells > 0 |
| 7 | LEC | Yosys miniSAT per-module (combinational only) | PASS; seq modules cross-checked by P2+P8 |
| 8 | Pre-Layout STA + GLS | OpenSTA multi-corner + zero-delay Icarus GLS | TT slack MET; SS advisory; GLS PASS |
| 9 | UPF Power Intent | Yosys read_upf + domain check | PASS; WARN expected (Yosys UPF incomplete) |

## Non-obvious technical decisions
- **coverage.dat**: Verilator sim binary needs `+verilator+coverage+file+{path}` plusarg — not automatic on `$finish`. See `p4_sim.py`.
- **expression coverage**: P4 uses `--coverage-expr` flag; P5 parses `v_expr` entries from coverage.dat (each hit count checked > 0). Requires both flags to get Expr Coverage in dashboard.
- **PDK isolation**: `_select_lib_files()` groups libs by prefix (sky130 vs nangate), never mixes. Returns `(tt_lib, all_corners, pdk_name)`. TT corner used for synthesis (P6), all corners swept in STA (P8).
- **lpflow pre-filter**: P6 calls `_filter_liberty_lpflow()` before abc to strip 34 power-gating cells (lpflow_isobufsrc_1, lpflow_inputiso1p_1) from liberty — they add 30+ ns of SS derating. Writes `*_nolpflow.lib` copy.
- **Checkpoint carryover**: `_load_last_metrics()` on `__init__` seeds `all_metrics` from last JSON report so cached/skipped pillars don't zero out history.
- **Formal cover mode**: `p2_formal.py` regex-replaces `mode prove` → `mode cover` in a temp `.sby`, runs it, warns on FAIL (over-constrained model), never exits 1.
- **Self-checking sim**: `SimLogParser` detects `$error`, `$fatal`, `Assertion failed` → status=FAIL. Soft-fail: all pillars run regardless; exit 1 only at orchestrator end.
- **Dual RTL lang**: Always use `_find_all_rtl()` (globs `*.sv` + `*.v`). Never bare `.glob("*.sv")`.
- **LEC strategy**: P7 uses Yosys miniSAT per-module for 5 combinational modules (fpu_round, fpu_flags, fpu_result_mux, fpu_operand_iso, fpu_clk_gate_ctrl). Sequential modules are cross-verified by P2 Formal + P8 GLS. Full-design SMT miter OOMs on 767 FFs.
- **GLS**: P8 GLS requires `lib/sky130_fd_sc_hd.v` (symlink to system PDK behavioral models). If missing, GLS returns SKIP. Currently PASS for fpu_top.
- **P6→P8 dependency**: P8 STA needs the synth netlist produced by P6. If P6 was skipped or failed, P8 returns SKIP automatically.
- **CDC/RDC**: P1 static scan catches multi-clock sensitivity lists, latches, async resets. Advisory only — not a hard gate. Commercial sign-off: Meridian CDC, VC Formal CDC.
- **Regression DB**: `.pillar_history.jsonl` in build/ appended every run. `--step history` shows N entries with ▲/▼ deltas.

## Formal verification idioms

This repo's open-source Yosys build (no Verific) has real, confirmed syntax limits that don't match typical yosys-formal tutorials. Two mistakes are easy to make, both silently produce a checkpoint-carried false PASS instead of an obvious error, and both were found the hard way debugging `rr_arbiter`/`apb_uart_master`/`uart_ctrl` — see project memory `feedback_formal_sby` for the full incident history. **`scripts/pillars/p2_formal.py`'s `_scan_formal_idioms()` now catches both automatically** (hard error for #1, warning for #2) before any `sby` invocation — but know the rules anyway when writing new formal blocks:

1. **No SVA temporal syntax at all.** `assert property (...)`, `property...endproperty`, `assume property`, `cover property`, and the `inside {...}` operator all fail with a hard parser error (`ERROR: syntax error, unexpected '@'` or similar) — confirmed on both the distro `apt` yosys and the full oss-cad-suite install. Real SVA support needs the commercial Verific/Tabby CAD frontend, not present here.

   ❌ **Don't:**
   ```systemverilog
   ONEHOT0: assert property (
       @(posedge clk) disable iff (!rst_n)
       $onehot0(grant_o)
   );
   ```
   ✅ **Do — immediate assertions inside clocked always blocks:**
   ```systemverilog
   always_comb begin
       if (rst_n) assert ($onehot0(grant_o));
   end
   ```
   `$past()` as a bare system function (not wrapped in `assert property`) DOES parse fine inside a plain `always @(posedge clk) assert(...)` block if you need one-cycle history — but a *named* `property foo; ... endproperty` block does not, even without `assert property` wrapping it. For history spanning more than `$past()` reaches, use an explicit shadow register (`sig_prev_q <= sig;` in its own `always_ff`).

2. **A plain register's `initial X = const;` is not reliably honored for BMC's basecase.** A flop declared `initial f_was_reset = 1'b0;` can still read `1` at BMC step 0 in a counterexample trace, with `rst_n` simultaneously 0 — confirmed with a minimal repro. This breaks the common "was-ever-reset latch" idiom (`mod1000`/`mod3ud`/`async_fifo`/`axi_lite_slave`/`fpu_axi_periph` all use it, with varying real exposure — see each IP's `REPORT.md`).

   ❌ **Don't** rely on a derived flag's own power-on value:
   ```systemverilog
   logic f_was_reset;
   initial f_was_reset = 1'b0;
   always_ff @(posedge clk or negedge rst_n)
       if (!rst_n) f_was_reset <= 1'b1;
   always_comb if (f_was_reset) assert(...);
   ```
   ✅ **Do** — constrain the basecase directly, an `initial` block containing an `assume` is a real constraint (confirmed with a minimal k-induction PASS) unlike a plain register's `initial` value:
   ```systemverilog
   initial assume(!rst_n);
   always_comb if (rst_n) assert(...);
   ```
   This is usually simpler too — most designs don't actually need "was reset, ever" persistence, just "not currently in reset" (`rr_arbiter`'s `grant_q`/`pp_q` are valid the same cycle `rst_n` deasserts, no settling cycle needed). Only reach for a real "was ever reset" flop if the design genuinely needs multi-cycle post-reset settling before its properties become meaningful — and even then, gate the flop's own assertions on current-cycle `rst_n` too if possible (belt-and-suspenders — this is why `async_fifo`'s exposure to bug #2 above is lower than `mod1000`'s: it double-gates on the flag AND `wr_rst_n`/`rd_rst_n` directly).

3. **A registered output compared against a live input needs the same cycle skew the hardware actually has.** If property P checks `registered_signal` against `live_input` in the same `always_comb`, and `registered_signal` reflects `live_input` from one cycle earlier (not the current cycle), BMC will find a real counterexample the moment `live_input` changes between decision and observation — this is not a tool bug, the property statement is wrong. Track a shadow register of whatever the decision actually used (`rr_arbiter.sv`'s `mask_at_grant_q` is the worked example) instead of comparing across the skew directly.

## Installed tools (server: dada-ser)
- Verilator 5.036, Yosys 0.33, SymbiYosys v0.64, OpenSTA 2.7.0, Icarus 12.0
- All on PATH via OSS CAD Suite. cocotb 2.0.1 + pyuvm 4.0.1 in `.venv/`.

## Key commands
```
pillar --top <module>                          # run all 9 pillars
pillar --top <module> --step <pillar>         # single: lint|formal|functional|sim|
                                              #         coverage|synth|lec|sta
pillar --top <module> --step history          # regression trend (all runs)
pillar --top <module> --step all --force      # force re-run (ignore cache)
pillar --top <module> --step sta --pdk sky130|nangate|auto
pillar --top <module> --coverage-threshold 90 # P5 hard gate at 90%
pillar --top <module> --ip-path ip_analog/foo # non-default IP path
```

## What NOT to do
- Don't re-read pillar.py to understand architecture — this file covers it
- Don't mix PDK lib files — `_select_lib_files()` handles this
- Don't use `sys.exit()` inside pillars — return "FAIL"/"PASS"/"SKIP"/"WARN" only
- Don't add lib/*.lib to git — they are symlinks to system PDK install
- Don't modify `.pillar_state.json` or `.pillar_report_*.json` manually
- Don't put duplicate RTL at module root — canonical locations: rtl/ and verification/

## Known gaps / future additions
1. LEC sequential modules: Cadence Conformal needed for fpu_fma/fpu_divsqrt LEC sign-off
2. CDC/RDC is static-only — no data-flow tracking, no clock-domain propagation
3. No IP auto-discovery across categories — use `--ip-path` for non-standard paths
4. Coverage threshold is per-run — no CI enforcement yet
5. SS timing (−84.202 ns): advisory pre-layout pessimism; back-annotated STA needs PnR
6. Dynamic power: vcd2saif not available; OpenSTA power uses static switching estimates
7. Formal depth: Z3 k-induction covers protocol (depth 5); full FMA arithmetic proof needs JasperGold
