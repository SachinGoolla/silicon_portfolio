# Per-IP cocotb simulation parameter overrides for uart_axi_periph.
# CLK_FREQ=1600, BAUD_RATE=100 -> apb_uart_master's BRDIV_VAL=0 (baud16_tick
# every clock cycle) -- same fast-sim convention as uart_ctrl's own
# cocotb_sim.mk. Without this a real UART frame costs thousands of cycles.
COMPILE_ARGS += -P uart_axi_periph.CLK_FREQ=1600 -P uart_axi_periph.BAUD_RATE=100
