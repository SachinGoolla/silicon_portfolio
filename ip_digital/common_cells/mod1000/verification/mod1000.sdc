# 100 MHz target clock.
# MEASURED (Pillar 8): TT +7.608 ns slack (real critical path ~2.39 ns,
# ~76% margin), SS +1.583 ns (worst corner, still MET but only ~16% margin
# — the pipelined carry/terminal-count logic is the SS-sensitive path).
# The original "~0.7 ns / 93% margin" note here was a pre-STA guess and
# was off by ~3x on TT — measure, don't estimate, when the number is cheap
# to get (this IP is 64 cells; STA takes seconds).
create_clock -name clk -period 10.0 [get_ports clk]
set_input_delay  2.0 -clock clk [get_ports rst_n]
set_output_delay 2.0 -clock clk [get_ports count]
