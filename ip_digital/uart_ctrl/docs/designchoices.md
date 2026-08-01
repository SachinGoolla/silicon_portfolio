# uart_ctrl — Design Choices

## Single clock domain (no internal CDC)
UART is often shown with a separate UART clock, but the industry-standard
approach is a baud-rate divider inside the peripheral on the system clock.
This avoids CDC inside the IP, is more synthesizable, and keeps the
integration simpler (one clock, one reset). The only crossing is the external
`uart_rx` pad, which is guarded by a 2-FF synchroniser inside `uart_ctrl`.

## 16× oversampling on RX
The RX FSM counts baud16_tick pulses rather than full baud-rate ticks.
At 16× rate: detect start-bit falling edge, wait 8 ticks (mid-start-bit),
then sample each bit at its midpoint (every 16 ticks). This gives ±7-tick
jitter tolerance — more than enough for crystal-sourced UARTs; marginal for
RC oscillators, which would need majority voting (not implemented).

## Self-contained sync FIFO (`uart_fifo.sv`)
Deliberately not using `async_fifo` from the sibling IP. The UART is
single-clock domain; an async FIFO would require a second clock that doesn't
exist. The sync FIFO is ~50 lines, formally verifiable by pointer-bound
assertions, and avoids cross-IP hierarchical instantiation issues in Yosys/P7.

## PRDATA registered in SETUP phase
APB PRDATA is registered one cycle before ACCESS. The timing path is:
`PADDR mux-select → FF D-input` rather than `mux-output → pad`.
This eliminates the wide-mux critical path at 80 MHz. Cost: 0 additional
wait states (PREADY is combinatorial `PSEL & PENABLE`).

## Parity as a synthesis parameter, not purely runtime
`PARITY_EN` is a module parameter so the parity state machines are
optimised away (not just clock-gated) when parity is unused. Most embedded
UART use cases are 8N1. The runtime `CTRL[3]` bit works when
`PARITY_EN=1` at synthesis and controls even/odd selection via `CTRL[4]`.

## Error flags are sticky (RW1C), interrupt is level-sensitive
Sticky flags prevent silent error loss if software is slow to respond.
RW1C (write-1-to-clear) is the ARM PrimeCell / AMBA convention and avoids
accidental double-clear bugs from read-modify-write.
Level-sensitive IRQ deasserts automatically when source is cleared — no
explicit software EOI register needed.

## CTRL default: TX_EN + RX_EN set, EN=0
Both sub-enables pre-assert so the first write to CTRL just sets EN=1 to
start operation, reducing configuration overhead in simple use cases.

## Loopback wired before pad (not at pad)
rx_in = loopback ? uart_tx_int : rx_sync[1].
The tx pad is still driven so an external analyser can capture the
loopback bytes. This matches the ST STM32 USART loopback behaviour.
