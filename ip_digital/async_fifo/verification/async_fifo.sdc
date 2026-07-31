# async_fifo.sdc — Two-domain timing constraints
# wr_clk  10 ns  (100 MHz)
# rd_clk  30 ns  (~33 MHz, 3:1 ratio)
# Declared asynchronous — no cross-domain timing paths analysed.

create_clock -name wr_clk -period 10.0 [get_ports wr_clk]
create_clock -name rd_clk -period 30.0 [get_ports rd_clk]

# Asynchronous clocks: no phase relationship; suppress false-path warnings
# between the two domains.
set_clock_groups -asynchronous -group {wr_clk} -group {rd_clk}

# I/O delays (25 % of period)
set_input_delay  -clock wr_clk -max 2.5 [get_ports {wr_en wr_data}]
set_output_delay -clock wr_clk -max 2.5 [get_ports full]

set_input_delay  -clock rd_clk -max 7.5 [get_ports {rd_en}]
set_output_delay -clock rd_clk -max 7.5 [get_ports {rd_data empty}]

# Synchroniser first-stage FFs: relax hold (metastability-immune by design)
set_false_path -hold -from [get_clocks wr_clk] -to [get_clocks rd_clk]
set_false_path -hold -from [get_clocks rd_clk] -to [get_clocks wr_clk]
