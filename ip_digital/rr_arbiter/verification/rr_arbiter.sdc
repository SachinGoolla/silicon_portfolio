# =============================================================================
# rr_arbiter.sdc  —  Timing Constraints for OpenSTA (Pillar 8 — STA)
# =============================================================================
#
# TARGET:  80 MHz on sky130 PDK  (12.5 ns clock period)
#          Matches fpu_top.sdc — the arbiter sits on the FPU writeback path
#          and must close timing in the same clock domain.
#
# CRITICAL PATH:
#   The combinational grant-select logic: priority-mask OR + lowest-set-bit
#   extraction.  For N_REQ=4 this is ~3 gate levels: OR(prio_mask, active_req)
#   → XOR (isolate LSB) → AND.  Sky130 sky_buf_4 is ~0.3 ns → total ~1 ns.
#
#   MEASURED (Pillar 8, TT corner): +9.544 ns slack at this period, i.e. real
#   critical path ~2.96 ns — higher than the ~1 ns hand estimate above (I/O
#   delay budget + actual cell selection account for the difference), but
#   still ~76% margin. Ample room at 12.5 ns. Scales to N_REQ=16 before
#   timing closure is at risk — re-measure, don't re-guess, if you do that.
#
# =============================================================================

create_clock -name clk -period 12.5 [get_ports clk]

set_input_delay  2.0 -clock clk [all_inputs]
set_output_delay 2.0 -clock clk [all_outputs]

# Async reset: exclude from timing analysis
set_false_path -from [get_ports rst_n]
