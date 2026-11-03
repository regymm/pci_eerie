#!/bin/bash
# SPDX-License-Identifier: CERN-OHL-P
# run several pci_eerie simulations in parallel and summarize
#   sim/regress.sh "<env> <test> [plusargs]" ...      e.g.  "GEN2=1 pio_writeReadBack_test0"
HERE=$(cd "$(dirname "$0")" && pwd)
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
  r=$(grep -c "Test Completed Successfully" "$HERE/regress_r$j.out")
  f=$(grep -ciE "FAILED|ERROR|TIMEOUT" "$HERE/regress_r$j.out")
  echo "r$j: completed=$r failure_lines=$f"
done
