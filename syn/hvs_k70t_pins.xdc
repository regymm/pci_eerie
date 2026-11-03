# SPDX-License-Identifier: CERN-OHL-P
# for HVS Kintex 70T, xc7k70tfbg676-1
# 100 MHz PCIe ref clk, via IBUFDS
set_property PACKAGE_PIN D6 [get_ports sys_clk_p]
set_property PACKAGE_PIN D5 [get_ports sys_clk_n]

# GT Lanes
set_property PACKAGE_PIN G3 [get_ports pci_exp_rxn]
set_property PACKAGE_PIN G4 [get_ports pci_exp_rxp]
set_property PACKAGE_PIN F1 [get_ports pci_exp_txn]
set_property PACKAGE_PIN F2 [get_ports pci_exp_txp]

# 200 MHz clk in


# Reset
#set_property PACKAGE_PIN ?? [get_ports {sys_rst_n}]
#set_property PULLUP true [get_ports {sys_rst_n}]
#set_property IOSTANDARD LVCMOS33 [get_ports {sys_rst_n}]

# Debug LEDs
set_property PACKAGE_PIN E15 [get_ports {led[0]}]
set_property IOSTANDARD LVCMOS33 [get_ports {led[0]}]
set_property PACKAGE_PIN E16 [get_ports {led[1]}]
set_property IOSTANDARD LVCMOS33 [get_ports {led[1]}]
set_property PACKAGE_PIN E17 [get_ports {led[2]}]
set_property IOSTANDARD LVCMOS33 [get_ports {led[2]}]
set_property PACKAGE_PIN E18 [get_ports {led[3]}]
set_property IOSTANDARD LVCMOS33 [get_ports {led[3]}]

# Clocks for Vivado

# BUFG drives GT
#set_property IS_ENABLED 0 [get_drc_checks {REQP-56}]
#set_property IS_ENABLED 0 [get_drc_checks {REQP-52}]

