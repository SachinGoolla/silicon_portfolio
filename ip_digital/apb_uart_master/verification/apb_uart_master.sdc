set_units -time ns
# 100 MHz (10 ns) — measured via Pillar 8, not guessed: TT slack is
# +7.049 ns at this period (real critical path ~2.95 ns, APB PENABLE/PADDR
# registered-output logic). ~70% margin pre-layout; plenty of room to raise
# this if a consumer ever needs a faster APB clock.
create_clock -name clk -period 10.0 [get_ports clk]
set_input_delay  -clock clk 1.0 [all_inputs]
set_output_delay -clock clk 1.0 [all_outputs]
