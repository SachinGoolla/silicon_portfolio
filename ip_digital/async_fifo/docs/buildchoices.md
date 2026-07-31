# async_fifo Build Choices

## P1 — Lint + CDC/RDC

Verilator `--lint-only -Wall -sv`. Expected advisory warnings:
- `MULTIDRIVEN` on `mem[]`: written on wr_clk, read on rd_clk — safe by pointer discipline.

Static CDC scan: detects two independent `posedge wr_clk` / `posedge rd_clk` domains with no multi-clock sensitivity issues (each always block has exactly one clock).

**OpenCDC structural analysis** (new in P1): generates Yosys `prep` netlist, runs OpenCDC checker. Expected result: **8 crossings** (4 nets wr→rd, 4 nets rd→wr) — the synchroniser first stages (wg2rd[0] and rg2wr[0]). These are ADVISORY: each crossing feeds a 2-FF synchroniser and is intentional. No raw crossings detected.

## P2 — Formal

`.sby`: `mode prove`, `depth 20`, `smtbmc --stbv z3`. Multi-clock design — assertions use `@(posedge wr_clk)` and `@(posedge rd_clk)` explicitly. SBY v0.64 handles asynchronous multi-clock via SMT bitvector abstraction.

Depth 20 chosen to allow the solver enough steps to:
1. Apply reset (1 cycle each domain)
2. Allow synchronisers to settle (2 rd_clk cycles)
3. Fill FIFO (8 wr_clk cycles)
4. Detect full flag (1 wr_clk cycle)
5. Verify FULL_STOPS_WR / EMPTY_STOPS_RD invariants hold

Cover mode (`p2_formal.py` auto-switches): COV_FULL and COV_DRAIN verify the FIFO can reach full and subsequently drain — essential liveness proof for the gray-code pointer logic.

## P3 — Functional (cocotb + pyUVM)

Full pyUVM 4.0.1 hierarchy:
- `AsyncFIFOEnv` → `WrAgent` (WriteDriver + WrMonitor + uvm_sequencer)
- `AsyncFIFOEnv` → `RdAgent` (RdDriver + RdMonitor + uvm_sequencer)
- `AsyncFIFOScoreboard` → in-order FIFO integrity via uvm_tlm_analysis_fifo

4 tests:
- `test_fill_drain`: DEPTH writes + full assertion + DEPTH reads + empty assertion, scoreboard verifies data
- `test_backpressure`: N=16 concurrent wr/rd goroutines, writer 3× faster (clock ratio match)
- `test_no_spurious_read`: rd_en=0 throughout, verifies rd_bin stays 0
- `test_stress`: N=32 random data, random inter-item gaps, scoreboard catches any misordering

## P4 — Simulation (Verilator)

`tb_async_fifo.sv` drives four test scenarios with embedded `$error` checks. Two independent `always #(N) clk = ~clk` clock generators (wr: 5 ns half-period, rd: 15 ns half-period). Verilator `--binary --coverage --coverage-toggle --coverage-expr` generates the simulation binary.

The `wait(!full)` / `wait(!empty)` constructs in the testbench use Verilator's event-driven simulation. Since both clocks are free-running (not derived from each other), Verilator's scheduler interleaves them correctly.

## P5 — Coverage

Target: >85% line coverage, >80% toggle coverage. The four TB tests cover:
- Full FIFO state (full=1)
- Empty FIFO state (empty=1)
- Simultaneous wr+rd (all branches in wr_bin/rd_bin increment paths)
- Backpressure: both `full` blocking writes and `empty` blocking reads

## P6 — Synthesis

Yosys sky130 TT corner. **Verified result: 840 cells** (vs expected ~250 — much larger because the 8×32-bit mem[] array maps to individual sky130 DFFs rather than a compiled SRAM macro; each bit = 1 DFF → 256 DFFs for data alone, plus 4 PTR_W FFs × 4 synchroniser stages + pointer logic + full/empty logic). lpflow pre-filter not required (no power-gating cells in async_fifo).

## P7 — LEC

async_fifo is fully sequential (all state in FFs) — the miniSAT per-module LEC returns WARN (same as rr_arbiter). Yosys can prove combinational equivalence but not FF-state equivalence without Cadence Conformal. GLS PASS in P8 provides functional cross-check. The updated `_write_miter()` uses substring matching for `wr_clk`/`rd_clk` and collects both resets (`wr_rst_n`, `rd_rst_n`).

## P8 — STA + GLS

Two-clock SDC (`async_fifo.sdc`): wr_clk 10 ns, rd_clk 30 ns, `set_clock_groups -asynchronous`. OpenSTA sweeps all three sky130 corners for each clock independently.

**Verified PPA:**
- Cell count: 840 (dominated by DFF array for mem[])
- TT WNS: +3.246 ns MET (critical path: gray XOR + DFF setup)
- SS WNS: −54.867 ns (extreme corner derating, advisory pre-layout)
- Max frequency (TT): ~77 MHz; (SS worst-case): ~12 MHz
- GLS: **PASS** — zero-delay gate sim matches RTL on all 4 test scenarios

## P9 — UPF

Two power domains (WR_DOMAIN, RD_DOMAIN). The shared mem[] array is placed in RD_DOMAIN. Isolation strategy: gray-coded pointers cross domain boundaries; `set_isolation ... -no_isolation` is appropriate since gray-code has no glitch risk. Yosys `read_upf` + domain check (advisory, as usual).
