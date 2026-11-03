#!/bin/bash
# SPDX-License-Identifier: CERN-OHL-P
# run several pci_eerie simulations in parallel and summarize
#   sim/regress.sh "<env> <test> [plusargs]" ...      e.g.  "GEN2=1 pio_writeReadBack_test0"
#   sim/regress.sh                                     the full regression (9 runs, about 10-30 min
#                                                      each, all in parallel; needs ~9 cores, ~5 GB)
HERE=$(cd "$(dirname "$0")" && pwd)
if [ $# -eq 0 ]; then
  set -- "pio_writeReadBack_test0" \
         "GEN2=1 pio_writeReadBack_test0" \
         "APP=1 eerie_mem_test" \
         "APP=1 GEN2=1 eerie_mem_test" \
         "APP=1 SIMTIME=500000ns eerie_int_test" \
         "APP=1 SIMTIME=600000ns eerie_ur_test" \
         "SIMTIME=900000ns eerie_cfg_dump" \
         "SIMTIME=800000ns eerie_stress_test -testplusarg inject_rx_tlp=12 -testplusarg inject_tx_tlp=9" \
         "GEN2=1 SIMTIME=800000ns eerie_stress_test -testplusarg inject_rx_tlp=20 -testplusarg inject_tx_tlp=15"
fi
i=0
for spec in "$@"; do
  envs=""; args=()
  for w in $spec; do
    if [[ $w =~ ^[A-Z_][A-Z0-9_]*= ]]; then envs="$envs $w"; else args+=("$w"); fi
  done
  tag=r$i
  ( env $envs BUILD_TAG=${BUILD_TAG_PREFIX:-}$tag "$HERE/run.sh" eerie "${args[@]}" > "$HERE/regress_$tag.out" 2>&1 ) &
  echo "$tag: $spec"
  i=$((i+1))
done
wait
for ((j=0; j<i; j++)); do
  # the stock system check prints two "FAILED" lines in every run (it expects the example
  # design's device ID); a passing run has completed=1 and failure_lines=2
  r=$(grep -c "Test Completed Successfully" "$HERE/regress_r$j.out")
  f=$(grep -ciE "FAILED|ERROR|TIMEOUT" "$HERE/regress_r$j.out")
  echo "r$j: completed=$r failure_lines=$f"
done
