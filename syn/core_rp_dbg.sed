# SPDX-License-Identifier: CERN-OHL-P
# sed -E script applied to the generated root port core (pcie_2_1_rport_7x with pci_eerie) by
# syn/vivado_impl.tcl and syn/Makefile.openxc7: hardware bring-up status out of the core top
# (top module only, i.e. up to the first endmodule) through its unused pipe_tx_N_sigs outputs:
#   pipe_tx_0/1_sigs  pci_eerie DBGVECA[49:0] (PIPE receive / receiver detection, see pci_eerie.v)
#   pipe_tx_2_sigs    {pipe_rate_idle, txphinitdone[3:0], rxpmaresetdone[3:0], cpll_lock[3:0],
#                      rst_fsm[4:0], pipe_rst_idle, phy_rdy_n}   (GT wrapper reset state)
#   pipe_tx_3_sigs    lane 0 {rate_fsm[4:0], sync_fsm_tx[5:0], drp_fsm[6:0]}
1,/^endmodule/ {
  s/^  rp_pcie_top # \(/  wire [63:0] dbg_vec_a_w;\
  wire [4:0] dbg_rst_fsm;\
  wire [LINK_CAP_MAX_LINK_WIDTH*5-1:0] dbg_rate_fsm;\
  wire [LINK_CAP_MAX_LINK_WIDTH*6-1:0] dbg_sync_tx;\
  wire [LINK_CAP_MAX_LINK_WIDTH*7-1:0] dbg_drp_fsm;\
  wire [LINK_CAP_MAX_LINK_WIDTH-1:0] dbg_cpll, dbg_pmarst, dbg_txph;\
  rp_pcie_top # (/
  s/^(\s*)\.dbg_vec_a(\s*)\( \),/\1.dbg_vec_a\2( dbg_vec_a_w ),/
  s/^(\s*)\.PIPE_RST_FSM(\s*)\( \),/\1.PIPE_RST_FSM\2( dbg_rst_fsm ),/
  s/^(\s*)\.PIPE_RATE_FSM(\s*)\( \),/\1.PIPE_RATE_FSM\2( dbg_rate_fsm ),/
  s/^(\s*)\.PIPE_SYNC_FSM_TX(\s*)\( \),/\1.PIPE_SYNC_FSM_TX\2( dbg_sync_tx ),/
  s/^(\s*)\.PIPE_DRP_FSM(\s*)\( \),/\1.PIPE_DRP_FSM\2( dbg_drp_fsm ),/
  s/^(\s*)\.PIPE_CPLL_LOCK(\s*)\( \),/\1.PIPE_CPLL_LOCK\2( dbg_cpll ),/
  s/^(\s*)\.PIPE_RXPMARESETDONE(\s*)\( \),/\1.PIPE_RXPMARESETDONE\2( dbg_pmarst ),/
  s/^(\s*)\.PIPE_TXPHINITDONE(\s*)\( \),/\1.PIPE_TXPHINITDONE\2( dbg_txph ),/
  s/^(\s*)assign  pipe_tx_0_sigs      = 25'b0;/\1assign  pipe_tx_0_sigs      = dbg_vec_a_w[24:0];/
  s/^(\s*)assign  pipe_tx_1_sigs      = 25'b0;/\1assign  pipe_tx_1_sigs      = dbg_vec_a_w[49:25];/
  s/^(\s*)assign  pipe_tx_2_sigs      = 25'b0;/\1assign  pipe_tx_2_sigs      = {5'd0, pipe_rate_idle, dbg_txph[3:0], dbg_pmarst[3:0], dbg_cpll[3:0], dbg_rst_fsm, pipe_rst_idle, phy_rdy_n};/
  s/^(\s*)assign  pipe_tx_3_sigs      = 25'b0;/\1assign  pipe_tx_3_sigs      = {7'd0, dbg_rate_fsm[4:0], dbg_sync_tx[5:0], dbg_drp_fsm[6:0]};/
}
