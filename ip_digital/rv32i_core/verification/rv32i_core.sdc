set_units -time ns
# 20 MHz (50.0 ns) — measured via Pillar 8, not guessed (same convention
# as uart_axi_periph.sdc): the real TT critical path is 39.970 ns
# (u_hazard's forwarding-select chain into the EX-stage operand mux,
# _2909_ -> ... -> _2511_/X mux2 -> _3146_/D), ~19.9% margin at this
# period. An initial 20.0 ns (50 MHz) guess VIOLATED by -20.112 ns at TT
# once real synthesis numbers came in — a 5-stage pipeline's EX-stage
# forwarding muxes chained with the ALU is a materially longer
# combinational path than this portfolio's simpler peripherals were.
create_clock -name clk -period 50.0 [get_ports clk]

set_input_delay  -clock clk 1.0 [all_inputs]
set_output_delay -clock clk 1.0 [all_outputs]

# Reset is asynchronous — exclude it from timing analysis.
set_false_path -from [get_ports rst_n]
