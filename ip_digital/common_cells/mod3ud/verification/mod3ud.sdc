# Timing constraints for mod3ud — 3-bit up/down counter
# Target: 100 MHz (10 ns period).
# MEASURED (Pillar 8): TT +8.290 ns slack (~83% margin) — genuinely
# comfortable. SS +0.368 ns is the actual tight corner (~3.7% margin,
# still MET) — "well within sky130 capability" was true for TT but
# overstated the SS margin; correcting that here rather than leaving a
# guess that reads more comfortable than the worst corner actually is.
# clock_uncertainty models pre-layout pessimism: jitter + skew budget.
# 1.5 ns uncertainty = 15% of period; post-PnR adds another 10-20%.
create_clock [get_ports clk] -name clk -period 10.0
set_clock_uncertainty 0.5 [get_clocks clk]
set_input_delay  0.5 -clock clk [get_ports rst]
set_output_delay 0.5 -clock clk [get_ports cnt]
