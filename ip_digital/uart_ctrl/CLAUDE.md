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
All properties are in `rtl/uart_ctrl.sv` under `` `ifdef FORMAL ``, written
as immediate assertions (`assert(...)`/`cover(...)` inside clocked always
blocks), NOT SVA `assert property`/`property...endproperty`/`inside {...}`
— this repo's open-source Yosys build can't parse any of that (see root
CLAUDE.md "Formal verification idioms"). This file used to be written in
SVA and showed a checkpoint-carried false PASS; the underlying `.sby` run
always hard-errored. Gated on `initial assume(!PRESETn);` + current-cycle
`PRESETn`, not a derived "was ever reset" latch. The `.sby` file reads all
5 RTL files from `../rtl/`.

## GLS notes
- Yosys synth output has no parameters → use `` `ifdef GLS uart_ctrl dut(.*)``
- Icarus rejects `automatic` inside `begin` blocks — declare variables at module scope

## Test quick reference
```
pillar --top uart_ctrl --ip-path ip_digital/uart_ctrl
pillar --top uart_ctrl --ip-path ip_digital/uart_ctrl --step functional
pillar --top uart_ctrl --ip-path ip_digital/uart_ctrl --step formal
```
