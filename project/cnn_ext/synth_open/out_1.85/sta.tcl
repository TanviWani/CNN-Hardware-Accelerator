read_liberty synth_open/NangateOpenCellLibrary_typical.lib
read_liberty synth_open/sram_macros_assumed.lib
read_verilog synth_open/out_1.85/dut_netlist.v
link_design dut_cnn
create_clock -name clk -period 1.85 [get_ports clk]
set_clock_uncertainty -setup 0.10 [get_clocks clk]
set_clock_uncertainty -hold  0.05 [get_clocks clk]
set_input_delay  [expr 1.85*0.3] -clock clk [get_ports {reset_n start dout[*]}]
set_output_delay [expr 1.85*0.3] -clock clk [get_ports {ready CMD[*] addr[*] din[*] oe}]
set_load 0.01 [all_outputs]
puts "=== SETUP (max) worst paths ==="
report_checks -path_delay max -group_path_count 1 -format full_clock_expanded -digits 3
puts "=== HOLD (min) worst paths ==="
report_checks -path_delay min -group_path_count 1 -digits 3
puts "=== SUMMARY ==="
report_worst_slack -max -digits 3
report_worst_slack -min -digits 3
report_tns -digits 3
report_wns -digits 3
report_clock_min_period
report_check_types -max_delay -min_delay -violators
