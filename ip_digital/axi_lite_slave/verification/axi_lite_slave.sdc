# axi_lite_slave.sdc — timing constraints.
# 200 MHz was the original target for the plain AXI-Lite register file
# (WSTRB masking only). Adding the hw_wdata_i/hw_we_i HW-write ports (a
# NUM_REGS*DATA_WIDTH-wide input feeding the write-priority mux) pushed the
# real critical path to ~11.7 ns on sky130 TT — measured via Pillar 8, not
# guessed. 80 MHz (12.5 ns) matches fpu_axi_periph's own closure point,
# the actual downstream consumer of this HW-write path.

create_clock -name clk -period 12.5 [get_ports clk]

set_input_delay  -clock clk  1.0 [all_inputs]
set_output_delay -clock clk  1.0 [all_outputs]
