# Clock definitions and clock grouping for design hack_top
create_clock -name clk_cpu      -period 2.000 [get_ports clk_cpu]
create_clock -name clk_cpu_div2 -period 4.000 [get_pins  U_DIV/Q]
create_clock -name clk_bus      -period 5.000 [get_ports clk_bus]
create_clock -name clk_io       -period 8.000 [get_ports clk_io]
create_clock -name clk_dsp      -period 3.300 [get_ports clk_dsp]

# Clocks inside one -group are synchronous to each other.
set_clock_groups -asynchronous \
  -group {clk_cpu clk_cpu_div2} \
  -group {clk_bus} \
  -group {clk_io} \
  -group {clk_dsp}

set_input_delay  0.400 -clock clk_cpu [get_ports din]
set_output_delay 0.400 -clock clk_bus [get_ports dout]
