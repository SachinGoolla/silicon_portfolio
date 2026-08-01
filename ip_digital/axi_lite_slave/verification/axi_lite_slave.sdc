# axi_lite_slave.sdc — timing constraints.
# Target 200 MHz (5 ns period): all paths are register-to-register; the
# critical path is WSTRB masking on the register write (DATA_WIDTH/8 enables).

create_clock -name clk -period 5.0 [get_ports clk]

set_input_delay  -clock clk  1.0 [all_inputs]
set_output_delay -clock clk  1.0 [all_outputs]
