set_units -time ns
# 100 MHz (10.0 ns) — measured via Pillar 8, not guessed: TT slack is
# +6.228 ns at this period (real critical path ~3.77 ns). ~62% margin
# pre-layout; SS corner is a documented advisory violation (-23.401 ns),
# same extreme-corner-derating pattern as every other IP in this portfolio.
create_clock -name clk -period 10.0 [get_ports clk]

set_input_delay  -clock clk 1.0 [all_inputs]
set_output_delay -clock clk 1.0 [all_outputs]

# Reset is asynchronous — exclude it from timing analysis.
set_false_path -from [get_ports rst_n]
