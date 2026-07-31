# Learned Optimizations Ledger

> Auto-appended by optimize.sh on every ACCEPT. Dr.RTL-style: a growing record
> of moves that actually improved PPA on this design, usable to prime future runs.

---

## Timing Closure

### EX3 Pipeline Split (r2b register) — 2026-07-24
**Problem:** TT WNS = −0.390 ns (critical path 12.752 ns at 80 MHz / 12.5 ns period).
**Root cause:** Single high-fanout nor2_1 cell (_5392_) at EX3 stage of fpu_fma
driving the full 29-bit LZD priority-encoder tree produced a 12.75 ns path.
**Fix:** Inserted r2b pipeline register between the adder/subtractor and the LZD
encoder in EX3, splitting into two ~6 ns half-stages:
  Before: r2 → [CSA + LZD + zero-detect] → r3  (12.75 ns)
  After:  r2 → [CSA] → r2b → [LZD + zero-detect] → r3 (~6 ns each)
**Result:** TT WNS: −0.390 ns → +0.131 ns (+521 ps). FMA latency 5→6 cycles.
**Files:** `rtl/fpu_fma.sv` (r2b_* registers added in EX3a stage)

### lpflow Liberty Pre-filter — 2026-07-24
**Problem:** SS WNS appeared as −92.593 ns, masking the real bottleneck.
**Root cause:** 34 lpflow power-gating cells (lpflow_isobufsrc_1, lpflow_inputiso1p_1)
were being mapped by abc at SS corner, adding 30+ ns of derating each.
**Fix:** `_filter_liberty_lpflow()` in p6_synth.py writes a sanitized liberty
copy before abc: sky130_fd_sc_hd__tt_025C_1v80_nolpflow.lib
**Result:** SS WNS: −92.593 ns → −84.202 ns (+8.391 ns), real gap now visible.
**Files:** `scripts/pillars/p6_synth.py`

---

## RTL Quality

### i2f_shifted Width Reduction — 2026-07-24
**Problem:** `i2f_shifted` declared as `[31:0]` in fpu_cvt.sv; bits [24:31]
were structurally dead — the barrel shift always places the leading 1 at bit 23.
Verilator UNUSEDSIGNAL warnings + 92 extra toggle targets in coverage.dat.
**Fix:** Changed declaration to `[23:0]`, updated three assignment sites to use
explicit 24-bit casts: `24'h0`, `24'(p1_i2f_mag >> ...)`, `24'(p1_i2f_mag << ...)`.
**Result:** 92 dead toggle entries removed (1,169 → 1,077 uncovered signals).
**Files:** `rtl/fpu_cvt.sv`

---

## Coverage Engineering

### Expression Coverage (--coverage-expr) — 2026-07-24
**Problem:** P5 showed "Branch/Expr: N/A" — branch coverage not being collected.
**Fix:** Added `--coverage-expr` to Verilator compile flags in `p4_sim.py`. Added
v_expr entry parsing in `p5_coverage.py` to read branch hit counts from coverage.dat.
**Result:** 79.7% expression coverage now reported (322/405 branches covered).
**Files:** `scripts/pillars/p4_sim.py`, `scripts/pillars/p5_coverage.py`

### CVT Toggle Closure Vectors — 2026-07-24
**Problem:** `int_mag[2:30]` and `i2f_mag[25:31]` bits in fpu_cvt.sv not toggling.
**Root cause:** Test suite lacked FP→INT vectors with specific integer powers of 2
(for int_mag) and INT→FP vectors with large integers > 2^24 (for i2f_mag).
**Fix:** Added 40+ directed vectors to `tb_fpu_top.sv`:
  - 28 FCVT.W.S vectors (4.0, 16.0, 32.0 ... 1073741824.0 → int_mag[2:30])
  - 8 FCVT.S.W / FCVT.S.WU vectors (2^25 ... UINT_MAX → i2f_mag[25:31])
**Result:** Toggle coverage 75.5% → 76.8% (uncovered: 1,169 → 1,077).
**Files:** `verification/tb_fpu_top.sv`

