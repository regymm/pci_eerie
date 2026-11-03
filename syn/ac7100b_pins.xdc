# SPDX-License-Identifier: CERN-OHL-P
# for AC7100B and TimeCard, xc7a100tffg484-1
# 100 MHz PCIe ref clk, via IBUFDS
set_property PACKAGE_PIN F10 [get_ports {sys_clk_p}]
set_property PACKAGE_PIN E10 [get_ports {sys_clk_n}]

# GT Lanes
set_property PACKAGE_PIN D11 [get_ports {pci_exp_rxp}]
set_property PACKAGE_PIN C11 [get_ports {pci_exp_rxn}]
set_property PACKAGE_PIN D5 [get_ports {pci_exp_txp}]
set_property PACKAGE_PIN C5 [get_ports {pci_exp_txn}]

# Reset
set_property PACKAGE_PIN J20 [get_ports {sys_rst_n}]
set_property PULLUP true [get_ports {sys_rst_n}]
set_property IOSTANDARD LVCMOS33 [get_ports {sys_rst_n}]

# Debug LEDs
set_property PACKAGE_PIN B13 [get_ports {led[0]}]
set_property IOSTANDARD LVCMOS33 [get_ports {led[0]}]
set_property PACKAGE_PIN C13 [get_ports {led[1]}]
set_property IOSTANDARD LVCMOS33 [get_ports {led[1]}]
set_property PACKAGE_PIN D14 [get_ports {led[2]}]
set_property IOSTANDARD LVCMOS33 [get_ports {led[2]}]
set_property PACKAGE_PIN D15 [get_ports {led[3]}]
set_property IOSTANDARD LVCMOS33 [get_ports {led[3]}]

# Clocks for Vivado
