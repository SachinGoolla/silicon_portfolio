set_units -time ns
# 20 MHz (50.0 ns) — starting point, not a fresh guess: rv32i_core's own
# measured TT critical path (39.970 ns, the hazard unit's forwarding-select
# chain into the EX-stage operand mux) already sets 50.0 ns as this SoC's
# binding constraint unless the address decoder's AXI response muxing (a
# handful of 4:1 muxes on bvalid_o/rvalid_o/bresp_o/rresp_o, entirely
# outside the core's own internal datapath) turns out to add enough gate
# depth to change the critical path. Recalibrate via Pillar 8's real
# synthesis numbers if it violates, same "measure, don't guess" convention
# established in rv32i_core.sdc/uart_axi_periph.sdc.
create_clock -name clk -period 50.0 [get_ports clk]

set_input_delay  -clock clk 1.0 [all_inputs]
set_output_delay -clock clk 1.0 [all_outputs]

# Reset is asynchronous — exclude it from timing analysis.
set_false_path -from [get_ports rst_n]
