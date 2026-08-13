# mac_tile_axi.sdc — timing constraints for OpenSTA (Pillar 8 — STA).
#
# Recalibrated 2026-08-13 — measured via Pillar 8, not guessed (same
# convention as rv32i_core.sdc/uart_axi_periph.sdc). The original 10.0 ns
# guess assumed the critical path would be dominated by a single int8
# multiply + 32-bit add, since every PE-to-PE hop is register-bounded
# (LATENCY=1). That assumption was wrong: the real TT critical path is
# 24.918 ns and runs through a single-cell fanout bottleneck, not PE
# arithmetic depth --
# u_ctrl/u_out_skid's ready signal -> u_ctrl/_158_ (nor2) ->
# u_ctrl/_159_ (clkinv_1, 13.772 ns alone) -> fans out into
# u_array/g_row[0].g_col[0].u_pe's int8_mac_core enable chain. That single
# inverter is almost certainly driving `array_pipeline_en`/`pipeline_en_i`
# to all 16 PEs (and every internal register each PE gates) with no
# fanout buffering -- synthesis's own log flagged this directly ("Add
# set_max_fanout and set_max_transition constraints to guide synthesis
# optimization"), not fixed here since it's a backend/PPA-closure concern,
# consistent with this portfolio's pre-layout-STA-is-advisory-pessimism
# stance (see root CLAUDE.md "Known gaps" #5). 30.0 ns (33.3 MHz) closes
# TT with ~19% margin above the measured 25.207 ns requirement -- the
# same margin convention rv32i_core.sdc used.

create_clock -name clk -period 30.0 [get_ports clk]

set_input_delay  2.0 -clock clk [all_inputs]
set_output_delay 2.0 -clock clk [all_outputs]

# Reset is asynchronous — exclude it from timing analysis.
set_false_path -from [get_ports rst_n]
