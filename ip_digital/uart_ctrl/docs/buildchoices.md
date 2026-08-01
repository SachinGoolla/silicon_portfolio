# uart_ctrl — Build Choices (pillar results updated after each run)

## P1 Lint + CDC
- Verilator `--lint-only`: 0 errors expected (no multi-driven wires, no latches)
- OpenCDC: 0 crossings expected (single clock domain; uart_rx pad is
  synchronised inside the design, not a raw CDC crossing)

## P2 Formal (SymbiYosys / Z3)
- Depth: 15 (inductive properties close at depth 5; cover needs ~150 steps
  for a full TX frame with BRDIV=0 but sby cover mode uses a different solver)
- Properties: F1–F7 (APB handshake, FSM encoding, TX idle, loopback, FIFO no-overflow)
- Cover: complete TX frame reachable from reset

## P3 Functional (cocotb + pyUVM / Icarus)
- Simulation parameters: CLK_FREQ=1600, BAUD_RATE=100 → BRDIV=0
  (baud16_tick every cycle → full frame = 160 clock cycles)
- test_loopback: pyUVM scoreboard — 4 TDR writes matched to uart_tx serial output
- test_frame_error: inject bad stop bit via uart_rx direct drive; verify SR[4]
- test_tx_watermark: fill TX FIFO, verify TX_FULL; drain, verify TX_EMPTY
- test_irq: TX_EMPTY_IE fires irq_o; clears when IER=0

## P4 Simulation (Verilator)
- Coverage flags: `--coverage --coverage-toggle --coverage-expr`
- TB: tb_uart_ctrl.sv — T1 register read-back, T2 loopback, T3 watermark, T4 IRQ

## P5 Coverage
- Target: line ≥85%, toggle ≥70%, expr ≥75%
- Parity path not exercised with default PARITY_EN=0 (by design)

## P6 Synthesis (Yosys → sky130)
- Target: TT timing closure at 80 MHz, cell count < 500
- lpflow pre-filter applied (same as fpu_top)
- Estimated: ~380 cells

## P7 LEC (Yosys miniSAT)
- 5 combinatorial sub-modules: uart_fifo, uart_baud,
  (uart_tx and uart_rx are sequential → verified by P2 + P8)

## P8 STA + GLS (OpenSTA + Icarus)
- SDC: 80 MHz PCLK; uart_tx/uart_rx set as false paths for STA
- GLS: synth netlist has no parameters; `ifdef GLS` instantiation in TB
- TT WNS target: ≥ 0 ns

## P9 UPF
- Single power domain PD_TOP; always-on
