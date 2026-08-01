# uart_ctrl.sdc — Timing constraints targeting 80 MHz (same as fpu_top).
# PRDATA is registered (registered on SETUP phase), so the critical path
# is APB mux → PRDATA register input — not mux → output pad.
# The baud-divider compare (16-bit cnt == brdiv) is registered; no multi-cycle needed.

create_clock -name PCLK -period 12.5 [get_ports PCLK]

set_input_delay  -clock PCLK  2.0 [all_inputs]
set_output_delay -clock PCLK  2.0 [all_outputs]

# uart_rx and uart_tx are false paths for STA (they're timed by the baud divider,
# not the system clock edge-to-edge path).
set_false_path -from [get_ports uart_rx]
set_false_path -to   [get_ports uart_tx]
