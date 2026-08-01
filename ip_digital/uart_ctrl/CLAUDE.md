# uart_ctrl — IP-level context

## RTL structure
- `rtl/uart_ctrl.sv`  — APB3 slave top; register file; 2-FF rx sync; loopback mux; irq
- `rtl/uart_tx.sv`    — TX FSM (IDLE/START/DATA/PARITY/STOP); baud16_tick driven
- `rtl/uart_rx.sv`    — RX FSM; 16× oversample; noise-reject mid-start check
- `rtl/uart_baud.sv`  — 16× baud tick generator (counter 0..BRDIV)
- `rtl/uart_fifo.sv`  — Sync FIFO; extra-MSB full/empty; combinatorial read

## Key constraints
- DO NOT instantiate `async_fifo` here — uart_ctrl is single-clock; sync FIFO only
- PRDATA is registered (SETUP phase) — PREADY is always combinatorial PSEL & PENABLE
- `PARITY_EN` is a synthesis parameter; runtime CTRL[3] only works when param=1
- uart_rx pad always goes through 2-FF sync in uart_ctrl.sv; rx_in is the result
- BRDIV=0 in P3/P4 simulation → baud16_tick fires every cycle → frame = 160 cycles

## Formal property locations
All SVA properties are in `rtl/uart_ctrl.sv` under `` `ifdef FORMAL ``.
The `.sby` file reads all 5 RTL files from `../rtl/`.

## GLS notes
- Yosys synth output has no parameters → use `` `ifdef GLS uart_ctrl dut(.*)``
- Icarus rejects `automatic` inside `begin` blocks — declare variables at module scope

## Test quick reference
```
pillar --top uart_ctrl --ip-path ip_digital/uart_ctrl
pillar --top uart_ctrl --ip-path ip_digital/uart_ctrl --step functional
pillar --top uart_ctrl --ip-path ip_digital/uart_ctrl --step formal
```
