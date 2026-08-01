# CLAUDE.md — apb_uart_master IP context

## Purpose
APB3 master controller that drives a `uart_ctrl` slave.  Exposes a byte-stream
(AXI4-S valid/ready) to system logic and handles all APB bus mechanics + uart_ctrl
register initialisation autonomously.

## File locations
- RTL:          rtl/apb_uart_master.sv
- Formal:       verification/apb_uart_master.sby
- SDC:          verification/apb_uart_master.sdc
- UPF:          verification/apb_uart_master.upf
- Verilator TB: verification/tb_apb_uart_master.sv

## Run all pillars
```
cd /home/dada/silicon_portfolio
pillar --top apb_uart_master --ip-path ip_digital/apb_uart_master
```

## Non-obvious microarchitecture details

### Zero-bubble back-to-back
`cmd_valid/addr/wdata` are driven from **`seq_next`** (combinational), not `seq_q`
(registered).  At the cycle PREADY fires in ACCESS (`apb_done=1`), `seq_next`
already reflects the upcoming state; the APB engine latches the new command and
jumps to SETUP — no IDLE cycle between init writes (BRDIV→IER→CTRL) or between
SR_RD and the dispatched TX/RX operation.

### IRQ edge detection
`uart_ctrl` holds `irq_o` high while TX_EMPTY stays asserted.  Without edge
detection, the sequencer would busy-loop on `SR_RD → IDLE → SR_RD` when the
TX FIFO is empty.  `irq_rise = irq_i && !irq_prev_q` detects the rising edge
only.  First TX byte uses the `!txf_empty` fallback trigger in SEQ_IDLE.

### uart_ctrl register init order
BRDIV is written **before** CTRL (EN=1).  Writing BRDIV after EN could produce
a glitch-rate baud tick while the counter is mid-count.

### CTRL_WORD parameter
Default `32'h07` (TX_EN|RX_EN|EN, no loopback).  Set to `32'h27` for hardware
loopback (uart_ctrl CTRL[5]=1).  The TB uses TB-level wire loopback instead
(uart_tx → uart_rx) to keep CTRL clean.

### RX FIFO overflow
If rxf_full when a RDR read completes, the byte is silently dropped.
This is mitigated by RX_DEPTH being at least as large as uart_ctrl FIFO_DEPTH.
The formal property TX_WR_VALID catches a related upstream invariant.

### uart_ctrl BRDIV dependence
`BRDIV_VAL = CLK_FREQ / (BAUD_RATE × 16) − 1`.  For CLK_FREQ=1600, BAUD_RATE=100
this gives 0 — baud16_tick every cycle — so simulation runs fast.

## Interfaces
- **TX**: `tx_data_i[7:0]`, `tx_valid_i`, `tx_ready_o` — AXI4-S subset
- **RX**: `rx_data_o[7:0]`, `rx_valid_o`, `rx_ready_i`
- **APB master**: PSEL, PENABLE, PWRITE, PADDR[4:0], PWDATA[31:0], PRDATA[31:0], PREADY, PSLVERR
- **IRQ**: `irq_i` from uart_ctrl
- **Status**: `init_done_o` (sticky post-init), `err_o` (sticky PSLVERR)
