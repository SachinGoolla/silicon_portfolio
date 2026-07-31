# CLAUDE.md — async_fifo IP Context

## Purpose
Dual-clock gray-code asynchronous FIFO for crossing between wr_clk (100 MHz) and
rd_clk (33 MHz, 3:1 ratio). DATA_W=32, DEPTH=8, SYNC_STAGES=2.
Architecture: Clifford Cummings 2002 (SNUG San Jose 2002, Rev 1.1).

## File locations
- RTL:          rtl/async_fifo.sv
- Formal:       verification/async_fifo.sby
- SDC:          verification/async_fifo.sdc
- UPF:          verification/async_fifo.upf
- cocotb/pyUVM: verification/test_async_fifo.py
- Verilator TB: verification/tb_async_fifo.sv
- Docs:         docs/Microarchitecture.txt, docs/designchoices.md, docs/buildchoices.md

## Run all 9 pillars
```
cd /home/dada/silicon_portfolio
pillar --top async_fifo --ip-path ip_digital/async_fifo
```

## Non-obvious details
- PTR_W = ADDR_W + 1 — extra bit disambiguates full vs empty; DEPTH must be >= 4 (PTR_W-3 slice)
- full condition: top 2 bits of wr_gray inverted vs rg2wr (Cummings Fig 6)
- empty condition: rd_gray == wg2rd[SYNC_STAGES-1] (simple gray equality)
- rd_data is REGISTERED — valid one rd_clk cycle after rd_en && !empty
- Yosys b2g/g2b functions need assignment-to-function-name (no 'return'); confirmed working
- OpenCDC: use 'prep' not 'synth' to generate JSON — synth maps to $_DFF_PP_ which OpenCDC misses
- Expected OpenCDC crossings: 8 (4 wr→rd, 4 rd→wr) — these are the synchroniser first stages
- (* keep *) on wg2rd/rg2wr prevents Yosys from merging synchroniser stages
- Two-clock formal: assertions use @(posedge wr_clk) / @(posedge rd_clk) explicitly
- p7_lec.py fix: uses substring match ('clk' in name) + ALL resets — needed for wr_clk/rd_clk/wr_rst_n/rd_rst_n
- SDC uses set_clock_groups -asynchronous + set_false_path -hold for cross-domain paths
- Verilator MULTIDRIVEN advisory on mem[] — expected, safe, documented in designchoices.md
- pyUVM monitor fix: WrMonitor and RdMonitor must capture wr_en/full and rd_en/empty at RisingEdge BEFORE ReadOnly() — not at ReadOnly(). At ReadOnly, wr_gray/rd_gray have been updated (post-NBA) so 'full'/'empty' reflects the JUST-WRITTEN state, not the state when the write condition was evaluated. Pre-NBA capture matches the RTL's `if (wr_en && !full)` / `if (rd_en && !empty)` condition exactly. The symptom was all UVM tests capping at DEPTH=8 scoreboard checks.
- GLS TB: async_fifo_synth.v has no parameters — use `\`ifdef GLS async_fifo dut(.*)` else parametrized instantiation
- Verilator TB: avoid `automatic` local variables inside `begin` blocks for GLS (Icarus restriction) — declare at module level instead
