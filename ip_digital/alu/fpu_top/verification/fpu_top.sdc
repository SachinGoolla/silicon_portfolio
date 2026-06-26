# =============================================================================
# fpu_top.sdc  —  Timing Constraints for OpenSTA (Pillar 8 — STA)
# =============================================================================
#
# TARGET:  100 MHz on sky130 PDK  (10 ns clock period)
#
# WHY 100 MHz FOR AN FPU?
#   Sky130 is a 180nm-class process (older technology).
#   A 32-bit FP adder in sky130 has ~8–12 ns of combinational delay.
#   At 100 MHz we have 10 ns total — that barely fits without pipelining.
#   In Phase 2, the FMA pipeline will break that path across 4 stages,
#   making 100 MHz comfortable and 200 MHz achievable.
#
#   For comparison: the same FPU on a 7nm process would run at 2+ GHz.
#
# NON-COMPUTE OPS (Phase 1):
#   FCLASS, FSGNJ, compare, FMIN/FMAX are purely combinational with simple
#   mux logic.  Their critical path is ~1–2 ns in sky130.
#   100 MHz gives ~800% timing margin for Phase 1 alone.
#   The constraint here is a FORWARD-LOOKING target for the full FPU.
#
# SDC SYNTAX REMINDER:
#   create_clock: defines the clock signal and its period
#   set_input_delay:  how long AFTER the clock edge the inputs arrive
#   set_output_delay: how long BEFORE the next clock edge outputs must be stable
#   These are placeholders — refined after place-and-route.
#
# =============================================================================

# Define 80 MHz clock (12.5 ns period) on the 'clk' port
# 80 MHz is the measured TT-corner closure frequency for the 4-stage FMA +
# 2-stage CVT pipeline in sky130.  100 MHz target is achievable post-PnR
# with retiming; pre-layout STA uses 80 MHz as the realistic sign-off point.
create_clock -name clk -period 12.5 [get_ports clk]

# Input setup: assume all inputs arrive 2 ns after the launching clock edge.
# This leaves 12.5 - 2 = 10.5 ns for combinational logic inside the FPU.
set_input_delay 2.0 -clock clk [all_inputs]

# Output hold: outputs must be stable 2 ns before the capturing clock edge.
set_output_delay 2.0 -clock clk [all_outputs]

# Reset is asynchronous — exclude it from timing analysis
# (The synthesis tool will treat negedge rst_n as an async clear)
set_false_path -from [get_ports rst_n]
