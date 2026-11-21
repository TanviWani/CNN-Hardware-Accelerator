#!/bin/bash
# Usage: cnn_ext/synth_open/run_synth.sh [clock_period_ns]   (default 1.85)   -- open-source estimate, NOT Design Compiler
# Flow: Yosys (generic synth + ABC mapped to Nangate45 typical) -> OpenSTA (setup/hold, area, cells)
# Needs: yosys, OpenSTA binary (env STA=/path/to/sta).  Outputs in synth/out_<period>/
ROOT="$(cd "$(dirname "$0")/.." && pwd)"; cd "$ROOT"      # = cnn_ext/
P=${1:-1.85}; STA=${STA:-/home/claude/tools/OpenSTA-master/build/sta}
PS=$(python3 -c "print(int($P*1000))"); O=synth_open/out_${P}; mkdir -p $O
LIB=synth_open/NangateOpenCellLibrary_typical.lib; SLIB=synth_open/sram_macros_assumed.lib
cat > $O/synth.ys <<YS
read_verilog -sv synth_open/sram_blackbox.v
read_verilog -sv -DSYNTHESIS ../srcs/rtl/cnn_fc.sv ../srcs/rtl/dut_cnn.sv
hierarchy -top dut_cnn
synth -top dut_cnn -flatten
dfflegalize -cell \$_DFF_P_ 01
dfflibmap -liberty $LIB
abc -liberty $LIB -constr synth_open/abc.constr -D $PS
hilomap -hicell LOGIC1_X1 Z -locell LOGIC0_X1 Z
opt_clean -purge
tee -o $O/yosys_stat.txt stat -liberty $LIB -liberty $SLIB
write_verilog -noattr -noexpr $O/dut_netlist.v
YS
yosys -q -l $O/yosys.log $O/synth.ys > /dev/null 2>&1 || { echo "yosys failed"; tail -20 $O/yosys.log; exit 1; }
cat > $O/sta.tcl <<TCL
read_liberty $LIB
read_liberty $SLIB
read_verilog $O/dut_netlist.v
link_design dut_cnn
create_clock -name clk -period $P [get_ports clk]
set_clock_uncertainty -setup 0.10 [get_clocks clk]
set_clock_uncertainty -hold  0.05 [get_clocks clk]
set_input_delay  [expr $P*0.3] -clock clk [get_ports {reset_n start dout[*]}]
set_output_delay [expr $P*0.3] -clock clk [get_ports {ready CMD[*] addr[*] din[*] oe}]
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
TCL
$STA -no_splash -exit $O/sta.tcl > $O/sta_report.txt 2>&1
echo "done -> $O/sta_report.txt , $O/yosys_stat.txt"
