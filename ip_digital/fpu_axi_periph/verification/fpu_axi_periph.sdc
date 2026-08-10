# fpu_axi_periph.sdc — timing constraints for OpenSTA (Pillar 8 — STA).
#
# fpu_top alone closes 80 MHz (12.5 ns) with near-zero margin — its own SDC
# documents that as "the measured TT-corner closure frequency," not a
# target with headroom. Flattening it together with the AXI-Lite register
# file/glue FSM for this peripheral's synthesis (Pillar 6 uses `synth
# -flatten`, no module boundaries) adds integration overhead — measured
# TT critical path is ~15.1 ns, so 60 MHz (16.7 ns) is this peripheral's
# actual closure point, not the bare compute core's.

create_clock -name clk -period 16.7 [get_ports clk]

set_input_delay  2.0 -clock clk [all_inputs]
set_output_delay 2.0 -clock clk [all_outputs]

# Reset is asynchronous — exclude it from timing analysis.
set_false_path -from [get_ports rst_n]
