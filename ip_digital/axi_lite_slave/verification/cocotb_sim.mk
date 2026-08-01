# Per-IP cocotb parameter overrides for axi_lite_slave.
# Default parameters are fine for functional testing; no speed-up needed
# (no baud-rate or deep FIFO — register file tests run in O(1) cycles).
# Intentionally empty — pillar.py passes parameters via -P from pillar_params.
