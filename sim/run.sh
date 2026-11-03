#!/bin/bash
# SPDX-License-Identifier: CERN-OHL-P
# pci_eerie xsim runner.
# usage: sim/run.sh <config> [test] [extra xsim plusargs...]
#   config: baseline  - pcie_7x with PCIE_2_1 hard block (reference)
#           eerie     - pcie_7x with pci_eerie soft core
set -e
CFG=${1:-eerie}; TEST=${2:-pio_writeReadBack_test0}; shift 2 || true
HERE=$(cd "$(dirname "$0")" && pwd)
EERIE=$(cd "$HERE/.." && pwd)
# PCIE_7X: pcie_7x checkout (default: the ext/pcie_7x submodule, else ../pcie_7x next to this repo)
# PCIE_EX: imports/ of the Vivado PCIe example design adapted to pcie_7x (root port model and
#          usrapp tasks; Xilinx files, not part of this repository)
if [ -z "$PCIE_7X" ]; then
  if [ -e "$EERIE/ext/pcie_7x/src/pcie_7x.v" ]; then PCIE_7X=$EERIE/ext/pcie_7x; else PCIE_7X=$EERIE/../pcie_7x; fi
fi
PCIE_EX=${PCIE_EX:-$EERIE/../pcie_7x_0_ex/imports}
export PCIE_7X=$(cd "$PCIE_7X" 2>/dev/null && pwd) PCIE_EX=$(cd "$PCIE_EX" 2>/dev/null && pwd)
[ -e "$PCIE_7X/src/pcie_7x.v" ] || { echo "pcie_7x not found: git submodule update --init, or set PCIE_7X" >&2; exit 1; }
[ -e "$PCIE_EX/pcie_2_1_rport_7x.v" ] || { echo "root port example imports not found: set PCIE_EX" >&2; exit 1; }
VIVADO=${VIVADO:-/opt/Xilinx/Vivado/2023.2}
source $VIVADO/settings64.sh >/dev/null
# GEN2=1: both sides capable of 5.0 GT/s (EP ENABLE_GEN2, RP LINK_CAP_MAX_LINK_SPEED=2)
DEFS=""; SUFFIX=""
if [ "${GEN2:-0}" = 1 ]; then DEFS="-d EP_GEN2=1 -d RP_GEN2"; SUFFIX="_gen2"; fi
# APP=1: endpoint with the testbench memory application (tb/eerie_tb_ep.v) instead of pcie_7x_top_aximm
if [ "${APP:-0}" = 1 ]; then DEFS="$DEFS -d EERIE_APP"; SUFFIX="${SUFFIX}_app"; fi
[ "$CFG" = eerie ] && DEFS="$DEFS -d EERIE_DLL_MON"
SUFFIX="$SUFFIX${BUILD_TAG:+_$BUILD_TAG}"
B=$HERE/build_$CFG$SUFFIX; mkdir -p $B; cd $B
{
  echo "verilog xil_defaultlib --include \"$EERIE/tb\" --include \"$PCIE_EX\" --include \"$EERIE/rtl\" \\"
  for f in $(eval echo $(cat $HERE/files_common.f)); do echo "\"$f\" \\"; done
  if [ "$CFG" = baseline ]; then
    echo "\"$PCIE_7X/src/pcie_block.v\" \\"
  else
    echo "\"$EERIE/integration/pcie_block.v\" \\"
    for f in $(cat $EERIE/rtl/files.f); do echo "\"$EERIE/rtl/$f\" \\"; done
  fi
  echo "\"$EERIE/tb/pci_exp_usrapp_tx.v\" \\"
  echo "\"$EERIE/tb/eerie_tb_ep.v\" \\"
  echo "\"$EERIE/tb/rp_mon.v\" \\"
  echo "\"$EERIE/tb/board.v\" \\"
  echo "\"$EERIE/tb/pipe_mon.v\""
  echo "verilog xil_defaultlib \"$VIVADO/data/verilog/src/glbl.v\""
  echo "nosort"
} > files.prj
xvlog --incr --relax $DEFS -prj files.prj > xvlog.log 2>&1 || { grep -E "ERROR|WARNING: \[VRFC 10-(3091|2938)" xvlog.log | head -40; exit 1; }
xelab --incr --debug typical --relax --mt 8 -L xil_defaultlib -L unisims_ver -L unimacro_ver -L secureip -L xpm \
  --snapshot board_$CFG$SUFFIX xil_defaultlib.board xil_defaultlib.pipe_mon xil_defaultlib.rp_mon xil_defaultlib.dll_mon xil_defaultlib.glbl -log xelab.log > /dev/null 2>&1 \
  || { grep -E "ERROR" xelab.log | head -40; exit 1; }
cat > run.tcl <<TCL
run ${SIMTIME:-2000000ns}
quit
TCL
xsim board_$CFG$SUFFIX -tclbatch run.tcl -testplusarg TESTNAME=$TEST "$@" -log sim.log > /dev/null 2>&1 || true
grep -E "Test (PASSED|FAILED|Completed)|TEST (PASSED|FAILED)|ERROR|Error|Fatal|timeout|TIMEOUT|\\\$finish" sim.log | head -40
