#!/bin/bash
# Regression: each line = MODE SEED NC.  Builds one simulator per NC (NC is an elaboration parameter).
cd "$(dirname "$0")/.."
CASES=(
 "mixed 1 10"  "mixed 2 10"  "mixed 3 10"  "rand 4 10"
 "accmax 1 10" "ties 1 10"   "zeros 1 10"
 "mixed 5 1"   "mixed 6 3"   "mixed 7 7"   "ties 2 7"   "mixed 8 16"  "accmax 2 16"  "ties 3 16"
)
pass=0; fail=0
for cs in "${CASES[@]}"; do
  set -- $cs; mode=$1; seed=$2; nc=$3
  vec=vec/run_${mode}_${seed}_nc${nc}
  python3 scripts/gen_vectors.py --mode $mode --seed $seed --nc $nc --out $vec > /dev/null || { echo "gen failed"; exit 1; }
  [ -x obj_nc$nc/Vtb_cnn ] || make -s -f Makefile.verilator build NC=$nc > /dev/null || { echo "build failed NC=$nc"; exit 1; }
  out=$(./obj_nc$nc/Vtb_cnn +VEC=$vec)
  cyc=$(echo "$out" | grep -m1 "timeline" | sed 's/.*ready \([0-9]*\).*/\1/')
  if echo "$out" | grep -q "RESULT: PASS"; then r=PASS; pass=$((pass+1)); else r=FAIL; fail=$((fail+1)); echo "$out" | grep -E "MISMATCH|FAIL" | head -5; fi
  printf "%-6s mode=%-7s seed=%-2s NC=%-2s  cycles/image=%-6s %s\n" "[$r]" $mode $seed $nc "$cyc" "$(grep -m1 class= $vec/summary.txt)"
done
echo "regression: $pass passed, $fail failed"
[ $fail -eq 0 ]
