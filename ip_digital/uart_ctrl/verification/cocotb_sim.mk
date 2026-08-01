# Per-IP cocotb simulation parameter overrides for uart_ctrl.
# CLK_FREQ=1600, BAUD_RATE=100 → BRDIV_DEFAULT=0 (baud16_tick every clock cycle).
# FIFO_DEPTH=4 for fast simulation (4-slot FIFO drains in 640 cycles).
COMPILE_ARGS += -P uart_ctrl.CLK_FREQ=1600 -P uart_ctrl.BAUD_RATE=100 -P uart_ctrl.FIFO_DEPTH=4
