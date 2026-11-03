# SPDX-License-Identifier: CERN-OHL-P
# pci_eerie timing constraints for pcie_7x_top_aximm on 7-series (GTP or GTX pipe wrapper)
create_clock -name sys_clk -period 10.000 [get_ports sys_clk_p]
create_clock -name txoutclk -period 10.000 [get_pins -hier -filter {NAME =~ *gt*e2_channel_i/TXOUTCLK}]

# PIPE clock mux (BUFGCTRL): 125 MHz (2.5 GT/s) and 250 MHz (5.0 GT/s) are exclusive
set mmcm  [get_cells -hier -filter {REF_NAME == MMCME2_ADV}]
set mux_o [get_pins -hier -filter {NAME =~ *pclk_i1_bufgctrl.pclk_i1/O}]
create_generated_clock -name clk_125mhz_mux -source [get_pins $mmcm/CLKOUT0] -divide_by 1 -add \
    -master_clock [get_clocks -of_objects [get_pins $mmcm/CLKOUT0]] $mux_o
create_generated_clock -name clk_250mhz_mux -source [get_pins $mmcm/CLKOUT1] -divide_by 1 -add \
    -master_clock [get_clocks -of_objects [get_pins $mmcm/CLKOUT1]] $mux_o
set_clock_groups -name pclk_mux -physically_exclusive -group clk_125mhz_mux -group clk_250mhz_mux

# pci_eerie crossings between the PIPE clock and the user clock use gray-coded FIFO pointers
# and 2-flop synchronizers: constrain them as datapath-only paths
set uclk [get_clocks -of_objects [get_pins $mmcm/CLKOUT2]]
set_max_delay -datapath_only -from [get_clocks {clk_125mhz_mux clk_250mhz_mux}] -to $uclk 4.000
set_max_delay -datapath_only -from $uclk -to [get_clocks {clk_125mhz_mux clk_250mhz_mux}] 4.000
# the FIFO storage is read asynchronously only after its write pointer was synchronized
set_false_path -from [get_cells -hier -filter {NAME =~ *pcie_2_1_block/*_fifo/mem_reg*}] -to [get_clocks {clk_125mhz_mux clk_250mhz_mux}]
set_false_path -from [get_cells -hier -filter {NAME =~ *pcie_2_1_block/*_fifo/mem_reg*}] -to $uclk

# pcie_7x xilinx_pcie_mmcm: the BUFGCTRL select is changed only while the GT rate change is in
# progress (as in Xilinx's own pipe_clock constraints)
set_false_path -to [get_pins -hier -filter {NAME =~ *pclk_i1_bufgctrl.pclk_i1/S*}]
