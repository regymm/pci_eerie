# SPDX-License-Identifier: CERN-OHL-P
# for LC YPCB Kintex 480T, xc7k480tffg1156-2 (pins as in pcie_7x/pcie_7x_ypcb_k480t.xdc)
# 100 MHz PCIe ref clk, via IBUFDS
set_property PACKAGE_PIN J8 [get_ports sys_clk_p]
set_property PACKAGE_PIN J7 [get_ports sys_clk_n]

# GT Lanes
set_property PACKAGE_PIN H6 [get_ports pci_exp_rxp]
set_property PACKAGE_PIN H5 [get_ports pci_exp_rxn]
set_property PACKAGE_PIN F2 [get_ports pci_exp_txp]
set_property PACKAGE_PIN F1 [get_ports pci_exp_txn]

# Reset
set_property PACKAGE_PIN Y26 [get_ports sys_rst_n]
set_property PULLUP true [get_ports sys_rst_n]
set_property IOSTANDARD LVCMOS33 [get_ports sys_rst_n]

# Single end 50 MHz clk
set_property PACKAGE_PIN AA28 [get_ports clk_50]
set_property IOSTANDARD LVCMOS33 [get_ports clk_50]

# Debug LEDs: yellow, green, red
set_property PACKAGE_PIN N30 [get_ports {led[0]}]
set_property IOSTANDARD LVCMOS33 [get_ports {led[0]}]
set_property PACKAGE_PIN M30 [get_ports {led[1]}]
set_property IOSTANDARD LVCMOS33 [get_ports {led[1]}]
set_property PACKAGE_PIN P30 [get_ports {led[2]}]
set_property IOSTANDARD LVCMOS33 [get_ports {led[2]}]
