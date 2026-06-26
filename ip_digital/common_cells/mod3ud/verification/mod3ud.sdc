# Timing constraints for mod3ud — 3-bit up/down counter
# Target: 100 MHz (10 ns period) — well within sky130 capability.
# clock_uncertainty models pre-layout pessimism: jitter + skew budget.
# 1.5 ns uncertainty = 15% of period; post-PnR adds another 10-20%.
create_clock [get_ports clk] -name clk -period 10.0
set_clock_uncertainty 0.5 [get_clocks clk]
set_input_delay  0.5 -clock clk [get_ports rst]
set_output_delay 0.5 -clock clk [get_ports cnt]
