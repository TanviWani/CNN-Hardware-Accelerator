add wave -noupdate -group tb sim:/tb/* 
add wave -noupdate -group dut_inst  sim:/tb/dut_inst/*
add wave -noupdate -group core sim:/tb/dut_inst/u_core/* 
add wave -noupdate -group sdr_mem  sim:/tb/mem/* 
run -all
