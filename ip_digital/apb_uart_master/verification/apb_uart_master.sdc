set_units -time ns
create_clock -name clk -period 10.0 [get_ports clk]   ;# 100 MHz target
set_input_delay  -clock clk 1.0 [all_inputs]
set_output_delay -clock clk 1.0 [all_outputs]
