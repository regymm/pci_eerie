// SPDX-License-Identifier: CERN-OHL-P
// pci_eerie: YPCB K480T board top with the PCIe generation selectable, for builds (openXC7)
// that cannot use pcie_7x's Gen2-only pcie_7x_top_aximm_ypcb_480t.
// NO_RESET = 1 replaces PERST# by pcie_7x's internal power-on reset counter.
`timescale 1ns / 1ps

module top_ypcb_k480t #(
  parameter ENABLE_GEN2 = 0,
  parameter NO_RESET    = 0
) (
  output      pci_exp_txp,
  output      pci_exp_txn,
  input       pci_exp_rxp,
  input       pci_exp_rxn,
  input       sys_clk_p,
  input       sys_clk_n,
  input       sys_rst_n,
  input       clk_50,
  output      [2:0] led
);
wire [3:0] led_i;
assign led = led_i[2:0];
pcie_7x_top_aximm #(
  .NO_RESET(NO_RESET),
  .ENABLE_GEN2(ENABLE_GEN2),
  .GT_DEVICE("GTX"),
  .CFG_DEV_ID(16'h0480)
) pcie_7x_top_aximm_i (
  .pci_exp_txp(pci_exp_txp),
  .pci_exp_txn(pci_exp_txn),
  .pci_exp_rxp(pci_exp_rxp),
  .pci_exp_rxn(pci_exp_rxn),
  .sys_clk_p(sys_clk_p),
  .sys_clk_n(sys_clk_n),
  .sys_rst_n(sys_rst_n),
  .led(led_i)
);
endmodule
