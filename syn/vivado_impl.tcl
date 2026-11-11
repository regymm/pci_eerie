# SPDX-License-Identifier: CERN-OHL-P
# pci_eerie: implement a pcie_7x board top with pci_eerie in place of PCIE_2_1
# usage: vivado -mode batch -source vivado_impl.tcl -tclargs <board> [part]
#   pcie_7x sources: $PCIE_7X if set, else the ext/pcie_7x submodule, else ../pcie_7x next to this repo
#   board: ac7100b      Alinx AC7100B (xc7a100t, GTP), Gen1   pcie_7x_top_aximm (writes top.bit)
#          ac7100b_msi  same board, Gen1, pcie_7x's MSI demo  pcie_7x_top_aximm_msi (writes top.bit)
#          ac7100b_gen2 same top with ENABLE_GEN2=1
#          ac7100b_x4   same board, x4 Gen1: Vivado 7-series core with pci_eerie (syn/top_ac7100b_x4.v;
#                       needs the root port example imports, PCIE_EX as sim/run.sh)
#          ypcb_k480t_rp YPCB K480T root port x4 Gen2 (syn/top_ypcb_k480t_rp.v, JTAG host bridge;
#                       tools/eerie_host.tcl), same PCIE_EX requirement; ypcb_k480t_rp_gen1: x4 Gen1;
#                       ypcb_k480t_rp_pzssd[_gen1]: lanes reversed for the PUZHI PZ-SSD M.2 adapter
#          hvs_k70t     HVS K70T (xc7k70t, GTX), Gen2         pcie_7x_top_aximm_hvs_70t
#          ypcb_k480t   YPCB K480T (xc7k480t, GTX), Gen2      pcie_7x_top_aximm_ypcb_480t (writes top.bit)
#          ypcb_k480t_gen1  same board, Gen1                  syn/top_ypcb_k480t.v (as the openXC7 build)
set here [file dirname [file normalize [info script]]]
set repo [file normalize $here/..]
if {[info exists env(PCIE_7X)]} { set pcie_7x [file normalize $env(PCIE_7X)]
} elseif {[file exists $repo/ext/pcie_7x/src/pcie_7x.v]} { set pcie_7x $repo/ext/pcie_7x
} else { set pcie_7x [file normalize $repo/../pcie_7x] }
if {![file exists $pcie_7x/src/pcie_7x.v]} { error "pcie_7x not found: git submodule update --init, or set PCIE_7X" }
# Vivado 7-series core of the root port example (PCIE_EX imports, as sim/run.sh) with pci_eerie in
# place of PCIE_2_1: "rp" as is (pcie_2_1_rport_7x), "ep" renamed rp_* -> ep_* (pcie_2_1_ep_7x)
proc vivado_core {kind} {
  global env repo here
  if {[info exists env(PCIE_EX)]} { set ex [file normalize $env(PCIE_EX)] } else { set ex [file normalize $repo/../pcie_7x_0_ex/imports] }
  if {![file exists $ex/pcie_2_1_rport_7x.v]} { error "root port example imports not found: set PCIE_EX" }
  file mkdir $here/build_core_gen
  set e {s/^(\s*)PCIE_2_1 #\(  \/\/ Verilog-2001/\1pci_eerie #(/}
  if {$kind eq "ep"} { set e "s/\\brp_(\[A-Za-z0-9_\]+)\\b/ep_\\1/g; s/\\bpcie_2_1_rport_7x\\b/pcie_2_1_ep_7x/g; $e"; set o pcie_2_1_ep_7x_eerie.v
  } else { set o pcie_2_1_rport_7x_eerie.v }
  exec sed -E $e $ex/pcie_2_1_rport_7x.v > $here/build_core_gen/$o
  if {$kind eq "rp"} {
    # bring-up status out of the core top (syn/core_rp_dbg.sed)
    exec sed -E -i -f $here/core_rp_dbg.sed $here/build_core_gen/$o
    if {[exec grep -c {dbg_vec_a_w\|dbg_rst_fsm} $here/build_core_gen/$o] < 8} { error "core_rp_dbg.sed did not apply" }
  }
  if {[exec grep -c {^\s*pci_eerie #(} $here/build_core_gen/$o] != 1} { error "PCIE_2_1 instance not found in $o" }
  return [list $here/build_core_gen/$o]
}
set board [lindex $argv 0]
set src $pcie_7x/src
set files [list $src/xilinx_pcie_mmcm.v $src/axil_to_al.v $src/axis_pcie_to_al_us.v $src/pcie_7x.v \
  $src/pcie_axi_rx.v $src/pcie_axi_tx.v $src/pcie_brams.v $src/pcie_tx_thrtl_ctl.v \
  $src/aximm-minimal/pcie_7x_top_aximm.v $src/aximm-minimal/axil_minimum.v $repo/integration/pcie_block.v]
set generics {}
set bitstream 0
set timing $here/pci_eerie_timing.xdc
switch $board {
  ac7100b      { set part xc7a100tfgg484-1; set top pcie_7x_top_aximm; lappend files $src/pipe_wrapper.v
                 set pins $here/ac7100b_pins.xdc; set bitstream 1 }
  ac7100b_msi  { set part xc7a100tfgg484-1; set top pcie_7x_top_aximm_msi; lappend files $src/pipe_wrapper.v
                 lappend files $src/aximm-minimal/pcie_7x_top_aximm_msi.v $src/aximm-minimal/axil_minimum_msi.v
                 set pins $here/ac7100b_pins.xdc; set bitstream 1 }
  ac7100b_gen2 { set part xc7a100tfgg484-2; set top pcie_7x_top_aximm; lappend files $src/pipe_wrapper.v
                 set pins $here/ac7100b_pins.xdc; set generics {ENABLE_GEN2=1} }
  ac7100b_x4   { set part xc7a100tfgg484-2; set top top_ac7100b_x4
                 set files [concat [vivado_core ep] [list $repo/tb/eerie_tb_ep_ml.v $repo/tb/eerie_tb_app.v $here/eerie_host_app.v $here/top_ac7100b_x4.v]]
                 set pins $here/ac7100b_x4_pins.xdc; set timing $here/ac7100b_x4_timing.xdc; set bitstream 1 }
  ypcb_k480t_rp { set part xc7k480tffg1156-2; set top top_ypcb_k480t_rp
                 set files [concat [vivado_core rp] [list $here/eerie_host_app.v $here/eerie_host_rp.v $here/top_ypcb_k480t_rp.v]]
                 set pins $here/ypcb_k480t_rp.xdc; set timing {}; set bitstream 1 }
  ypcb_k480t_rp_pzssd - ypcb_k480t_rp_pzssd_gen1 {
                 set part xc7k480tffg1156-2; set top top_ypcb_k480t_rp
                 if {$board eq "ypcb_k480t_rp_pzssd_gen1"} { set generics {ENABLE_GEN2=0} }
                 set files [concat [vivado_core rp] [list $here/eerie_host_app.v $here/eerie_host_rp.v $here/top_ypcb_k480t_rp.v]]
                 set pins $here/ypcb_k480t_rp_pzssd.xdc; set timing {}; set bitstream 1 }
  ypcb_k480t_rp_gen1 { set part xc7k480tffg1156-2; set top top_ypcb_k480t_rp; set generics {ENABLE_GEN2=0}
                 set files [concat [vivado_core rp] [list $here/eerie_host_app.v $here/eerie_host_rp.v $here/top_ypcb_k480t_rp.v]]
                 set pins $here/ypcb_k480t_rp.xdc; set timing {}; set bitstream 1 }
  hvs_k70t     { set part xc7k70tfbg676-1; set top pcie_7x_top_aximm_hvs_70t
                 lappend files $src/pipe_wrapper_gtx.v $src/aximm-minimal/pcie_7x_top_aximm_hvs_70t.v
                 set pins $here/hvs_k70t_pins.xdc }
  ypcb_k480t   { set part xc7k480tffg1156-2; set top pcie_7x_top_aximm_ypcb_480t
                 lappend files $src/pipe_wrapper_gtx.v $src/aximm-minimal/pcie_7x_top_aximm_ypcb_480t.v
                 set pins $here/ypcb_k480t_pins.xdc; set bitstream 1 }
  ypcb_k480t_gen1 { set part xc7k480tffg1156-2; set top top_ypcb_k480t
                 lappend files $src/pipe_wrapper_gtx.v $here/top_ypcb_k480t.v
                 set pins $here/ypcb_k480t_pins.xdc; set bitstream 1 }
  default { error "unknown board $board" }
}
if {[llength $argv] > 1} { set part [lindex $argv 1] }
set bdir $here/build_${board}_$part
file mkdir $bdir
cd $bdir
create_project -in_memory -part $part
set_property target_language Verilog [current_project]
read_verilog $files
foreach f [split [string trim [read [open $repo/rtl/files.f]]] "\n"] { read_verilog $repo/rtl/$f }
read_xdc $pins
if {$timing ne {}} { read_xdc $timing }
set gen_args {}
foreach g $generics { lappend gen_args -generic $g }
synth_design -top $top -include_dirs [list $repo/rtl] {*}$gen_args
report_utilization -file util_synth.rpt
opt_design
place_design
phys_opt_design
route_design
write_checkpoint -force routed.dcp
report_utilization -file util.rpt
report_utilization -hierarchical -file util_hier.rpt
report_timing_summary -max_paths 20 -file timing.rpt
report_clock_interaction -file clock_interaction.rpt
if {$bitstream} { write_bitstream -force top.bit }
