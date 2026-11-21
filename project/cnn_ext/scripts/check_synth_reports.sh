#!/bin/bash
# Sanity-check Design Compiler reports after `make synth`:  cnn_ext/scripts/check_synth_reports.sh [build_dir]
# Fails if the SRAM macros were not linked (black boxes / zero area) or timing is violated.
B="${1:-$(cd "$(dirname "$0")/../.." && pwd)/build}"; R="$B/synth/reports"; rc=0
[ -d "$R" ] || { echo "no reports in $R (run: make synth)"; exit 2; }
if grep -qE "unresolved reference|Unable to resolve reference|Cannot find the design 'sram_" $R/*.rpt; then
  echo "FAIL: SRAM macros NOT linked (unresolved references) - area and SRAM-pin timing are incomplete."
  echo "      Check: echo \$SRAM_PATH ; ls \$SRAM_PATH/sram_32x32_1r1w/*SS_0p9V_100C.db ; configure output must print '-- SRAM libraries: ...';"
  echo "      then use a FRESH build dir:  rm -rf build && mkdir build && cd build && cmake .. --preset cnn && make synth"; rc=1
else echo "ok  : no unresolved references"; fi
nm=$(grep -cE "sram_[0-9]+x32_1r1?w?.* b *$|sram_.*0\.0000 +b" $R/cell_report_final.rpt)
[ "$nm" -gt 0 ] && { echo "FAIL: $nm SRAM instances are black boxes (area 0.0000) in cell_report_final.rpt"; rc=1; } || echo "ok  : SRAM instances have real area"
for f in $R/timing_max_slow*.rpt $R/timing_min_fast_holdcheck*.rpt; do
  s=$(grep -m1 "slack (" $f); echo "$(basename $f): $s"; echo "$s" | grep -q VIOLATED && rc=1
done
grep -m1 "^Total .* cells" $R/cell_report_final.rpt
exit $rc
