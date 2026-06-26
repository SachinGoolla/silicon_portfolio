# 100 MHz target clock — realistic for sky130 with combinational depth ~5
# Data path worst-case ~0.7 ns; 10 ns period gives ~93% margin pre-PnR
create_clock -name clk -period 10.0 [get_ports clk]
set_input_delay  2.0 -clock clk [get_ports rst_n]
set_output_delay 2.0 -clock clk [get_ports count]
