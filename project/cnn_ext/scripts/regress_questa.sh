#!/bin/bash
# Questa regression of the full CNN core (dut_cnn).  Run from anywhere AFTER:
#   cd project && source setup.sh && mkdir -p build && cd build && cmake .. --preset cnn
# Each case regenerates the vectors (python3) and runs `make vsim-cnn-c`; prints PASS/FAIL + cycles per image.
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"; B="$ROOT/build"
[ -f "$B/CMakeCache.txt" ] || { echo "configure first: cd $ROOT/build && cmake .. --preset cnn"; exit 1; }
CASES=("mixed 1 10" "mixed 2 10" "mixed 3 10" "rand 4 10" "accmax 1 10" "ties 1 10" "zeros 1 10"
       "mixed 5 1" "mixed 6 3" "mixed 7 7" "ties 2 7" "mixed 8 16" "accmax 2 16" "ties 3 16")
pass=0; fail=0
for cs in "${CASES[@]}"; do
  set -- $cs; mode=$1; seed=$2; nc=$3
  (cd "$B" && cmake . -DCNN_NC=$nc -DCNN_MODE=$mode -DCNN_SEED=$seed >/dev/null && make -s cnn-vectors >/dev/null) || { echo "setup failed"; exit 1; }
  out=$(cd "$B" && make -s vsim-cnn-c 2>&1)
  cyc=$(echo "$out" | grep -m1 "timeline" | sed 's/.*ready \([0-9]*\).*/\1/')
  if echo "$out" | grep -q "RESULT: PASS"; then r=PASS; pass=$((pass+1)); else r=FAIL; fail=$((fail+1)); echo "$out" | grep -E "MISMATCH|FAIL|rror" | head -5; fi
  printf "%-6s mode=%-7s seed=%-2s NC=%-2s cycles/image=%s\n" "[$r]" $mode $seed $nc "$cyc"
done
echo "regression: $pass passed, $fail failed"; [ $fail -eq 0 ]
