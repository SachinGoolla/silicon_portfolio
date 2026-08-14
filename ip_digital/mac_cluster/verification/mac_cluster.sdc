# mac_cluster.sdc — timing constraints for OpenSTA (Pillar 8 — STA).
#
# Recalibrated 2026-08-14 — measured via Pillar 8, not guessed (same
# convention as rv32i_core.sdc/mac_tile_axi.sdc). First pass used a
# conservative 40.0 ns guess (mac_cluster composes 4x mac_tile_axi plus 4x
# mesh_router, a genuinely new critical-path shape -- a 134-bit 5-port
# output mux driven by a 4-input rr_arbiter -- never synthesized before
# this phase, so no assumption was safe to carry over). The measured TT
# critical path turned out to be the SAME inherited bottleneck
# mac_tile_axi.sdc already documents (g_tile[0].u_tile/u_ctrl/u_out_skid's
# ready signal fanning unbuffered into the PE array's enable chain), not a
# new mesh_router-driven path: 24.218 ns here vs. 24.918 ns for one
# standalone tile (close, not identical -- different fanout/loading
# composed into a larger netlist). None of the mesh_router/rr_arbiter
# logic showed up on the worst path in this run. 30.0 ns (33.3 MHz)
# closes TT with ~24% margin above the measured 24.218 ns requirement,
# matching mac_tile_axi.sdc's own period exactly since it's fundamentally
# the same critical path, inherited 4x, not a new one.

create_clock -name clk -period 30.0 [get_ports clk]

set_input_delay  2.0 -clock clk [all_inputs]
set_output_delay 2.0 -clock clk [all_outputs]

# Reset is asynchronous — exclude it from timing analysis.
set_false_path -from [get_ports rst_n]
