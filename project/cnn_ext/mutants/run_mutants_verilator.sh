#!/bin/bash
# Builds the golden CNN core + each mutant (replacing only the mutated file(s)), runs tb_cnn,
# prints/saves a table.  Usage: ./mutants/run_mutants_verilator.sh   (from anywhere)
ROOT="$(cd "$(dirname "$0")/.." && pwd)"; cd "$ROOT"
python3 scripts/make_mutants.py >/dev/null || { echo "mutant generation failed"; exit 1; }
W=$(mktemp -d); OUT=mutants/results.txt; : > $OUT
run() {  # name dir mode seed nc
  python3 scripts/gen_vectors.py --mode $3 --seed $4 --nc $5 --out $W/vec >/dev/null
  rm -rf $W/rtl; mkdir $W/rtl; cp ../srcs/rtl/dut_cnn.sv ../srcs/rtl/cnn_fc.sv $W/rtl/; [ -n "$2" ] && cp $2/*.sv $W/rtl/
  verilator --binary --timing -Wno-fatal -Wno-lint -Wno-style --top-module tb_cnn -GNC=$5 -Mdir $W/obj \
     sim/tb_cnn.sv sim/dram_model.sv sim/sram_models.sv $W/rtl/dut_cnn.sv $W/rtl/cnn_fc.sv > $W/b.log 2>&1 || { echo "BUILD ERROR"; return; }
  $W/obj/Vtb_cnn +VEC=$W/vec | grep -E "RESULT" | sed 's/\[TB \] RESULT: //'
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
