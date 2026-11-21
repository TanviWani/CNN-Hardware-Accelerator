#!/bin/bash
# Mutation test of tb_cnn with Questa: each mutant replaces ONE (or two) RTL file(s) of dut_cnn.
# Prereq: cd project && source setup.sh && mkdir -p build && cd build && cmake .. --preset cnn && make vlog-sram (if SRAM_PATH set)
# Usage:  ./mutants/run_mutants_questa.sh        (writes mutants/results_questa.txt)
ROOT="$(cd "$(dirname "$0")/.." && pwd)"; P="$(dirname "$ROOT")"; B="$P/build"; cd "$ROOT"
python3 scripts/make_mutants.py >/dev/null || exit 1
INI=(); [ -f "$B/cnn/modelsim.ini" ] && INI=(-modelsimini "$B/cnn/modelsim.ini")
SRAMARGS=(); SRAMSRC=""
if [ -d "$B/sram-models/work" ]; then SRAMARGS=(-L "$B/sram-models/work"); else SRAMSRC="$ROOT/sim/sram_models.sv"; fi
W=$(mktemp -d); OUT=mutants/results_questa.txt; : > $OUT
run() {  # name mutdir mode seed nc
  python3 scripts/gen_vectors.py --mode $3 --seed $4 --nc $5 --out $W/vec >/dev/null
  rm -rf $W/work $W/rtl; mkdir $W/rtl; cp "$P/srcs/rtl/dut_cnn.sv" "$P/srcs/rtl/cnn_fc.sv" $W/rtl/; [ -n "$2" ] && cp $2/*.sv $W/rtl/
  vlib $W/work >/dev/null && vlog -64 -sv -work $W/work "${SRAMARGS[@]}" sim/dram_model.sv sim/tb_cnn.sv $W/rtl/dut_cnn.sv $W/rtl/cnn_fc.sv $SRAMSRC >$W/vlog.log 2>&1 || { echo "COMPILE ERROR"; return; }
  vsim -c -64 "${INI[@]}" "${SRAMARGS[@]}" -GNC=$5 $W/work.tb_cnn +VEC=$W/vec -do "run -all; quit" 2>&1 | grep -E "RESULT" | sed 's/.*RESULT: //'
}
printf "%-30s %-18s %-12s %-36s %s\n" MUTANT TEST EXPECTED "TESTBENCH SAYS" VERDICT | tee -a $OUT
r=$(run golden "" mixed 1 10); printf "%-30s %-18s %-12s %-36s %s\n" "GOLDEN (no mutation)" "mixed/1/NC10" PASS "$r" "$([[ $r == PASS* ]] && echo OK || echo BAD)" | tee -a $OUT
while read id mode seed nc exp; do
  r=$(run $id mutants/$id $mode $seed $nc)
  case $exp in DETECT) ok=$([[ $r == FAIL* ]] && echo "OK (caught)" || echo "MISSED!");;
               SURVIVES) ok=$([[ $r == PASS* ]] && echo "OK (equivalent, see DESCRIPTION)" || echo "unexpected");;
               CONTROL_PASS) ok=$([[ $r == PASS* ]] && echo "OK (control passes)" || echo "BAD");; esac
  printf "%-30s %-18s %-12s %-36s %s\n" $id "$mode/$seed/NC$nc" $exp "${r:0:36}" "$ok" | tee -a $OUT
done < mutants/manifest.txt
rm -rf $W
