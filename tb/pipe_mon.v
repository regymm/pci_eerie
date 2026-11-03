// SPDX-License-Identifier: CERN-OHL-P
// PIPE-level symbol logger for the endpoint (works for both PCIE_2_1 and pci_eerie builds)
// +pipe_log  : per-pclk data log to pipe.log (decode with tools/pipe_decode.py)
// +pipe_ctl  : PIPE control-signal change log to pipe_ctl.log
`timescale 1ps/1ps
module pipe_mon;
  integer f, fc;
  wire        clk  = board.EP.pcie_7x_i.pcie_block_inst.pipe_clk;
  wire [15:0] txd  = board.EP.pcie_7x_i.pcie_block_inst.pipe_tx0_data_gt;
  wire [1:0]  txk  = board.EP.pcie_7x_i.pcie_block_inst.pipe_tx0_char_is_k_gt;
  wire        txei = board.EP.pcie_7x_i.pcie_block_inst.pipe_tx0_elec_idle_gt;
  wire [15:0] rxd  = board.EP.pcie_7x_i.pcie_block_inst.pipe_rx0_data_gt;
  wire [1:0]  rxk  = board.EP.pcie_7x_i.pcie_block_inst.pipe_rx0_char_is_k_gt;
  wire        rxv  = board.EP.pcie_7x_i.pcie_block_inst.pipe_rx0_valid_gt;
  wire [5:0]  ltssm = board.EP.pcie_7x_i.pcie_block_inst.pl_ltssm_state;
  wire [1:0]  pd   = board.EP.pcie_7x_i.pcie_block_inst.pipe_tx0_powerdown_gt;
  wire        det  = board.EP.pcie_7x_i.pcie_block_inst.pipe_tx_rcvr_det_gt;
  wire        rate = board.EP.pcie_7x_i.pcie_block_inst.pipe_tx_rate_gt;
  wire        pol  = board.EP.pcie_7x_i.pcie_block_inst.pipe_rx0_polarity_gt;
  wire        phys = board.EP.pcie_7x_i.pcie_block_inst.pipe_rx0_phy_status_gt;
  wire [2:0]  rxst = board.EP.pcie_7x_i.pcie_block_inst.pipe_rx0_status_gt;
  wire        rxei = board.EP.pcie_7x_i.pcie_block_inst.pipe_rx0_elec_idle_gt;
  wire        cmp  = board.EP.pcie_7x_i.pcie_block_inst.pipe_tx0_compliance_gt;
  wire        dmp  = board.EP.pcie_7x_i.pcie_block_inst.pipe_tx_deemph_gt;
  wire        rdy  = board.EP.pcie_7x_i.pcie_block_inst.phy_rdy_n;
  wire [5:0]  rp_ltssm = board.RP.pl_ltssm_state;
  initial begin
    f = 0; fc = 0;
    if ($test$plusargs("pipe_log")) f = $fopen("pipe.log", "w");
    if ($test$plusargs("pipe_ctl")) fc = $fopen("pipe_ctl.log", "w");
  end
  always @(posedge clk) if (f != 0)
    $fdisplay(f, "%0t L%02h T%b%b%b %04h R%b%b%b %04h P%02h", $time, ltssm, txei, txk[1], txk[0], txd, rxv, rxk[1], rxk[0], rxd, rp_ltssm);
  reg [37:0] last = 38'h3fffffffff;
  wire [37:0] cur = {rp_ltssm, ltssm, pd, det, rate, pol, phys, rxst, rxei, txei, cmp, dmp, rdy, rxv};
  always @(posedge clk) if (fc != 0 && cur !== last) begin
    last <= cur;
    $fdisplay(fc, "%0t rp_ltssm=%02h ltssm=%02h pd=%b det=%b rate=%b pol=%b phystatus=%b rxstatus=%b rxei=%b txei=%b cmpl=%b deemph=%b phy_rdy_n=%b rxvalid=%b",
      $time, rp_ltssm, ltssm, pd, det, rate, pol, phys, rxst, rxei, txei, cmp, dmp, rdy, rxv);
  end
endmodule

// +dll_mon : print pci_eerie DLL TX pointer changes (only meaningful in eerie builds)
module dll_mon;
`ifdef EERIE_DLL_MON
  wire clk = board.EP.pcie_7x_i.pcie_block_inst.pcie_2_1_block.uclk;
  wire [5:0] d_wr   = board.EP.pcie_7x_i.pcie_block_inst.pcie_2_1_block.dll.d_wr;
  wire [5:0] d_send = board.EP.pcie_7x_i.pcie_block_inst.pcie_2_1_block.dll.d_send;
  wire [5:0] d_ack  = board.EP.pcie_7x_i.pcie_block_inst.pcie_2_1_block.dll.d_ack;
  wire [5:0] s_ptr  = board.EP.pcie_7x_i.pcie_block_inst.pcie_2_1_block.dll.s_ptr;
  wire [11:0] ackd  = board.EP.pcie_7x_i.pcie_block_inst.pcie_2_1_block.dll.ackd_seq;
  wire [11:0] ntx   = board.EP.pcie_7x_i.pcie_block_inst.pcie_2_1_block.dll.next_tx_seq;
  wire [5:0] slots  = board.EP.pcie_7x_i.pcie_block_inst.pcie_2_1_block.dll.txq_slots;
  wire ev  = board.EP.pcie_7x_i.pcie_block_inst.pcie_2_1_block.dll.ev_acknak;
  wire [11:0] evs = board.EP.pcie_7x_i.pcie_block_inst.pcie_2_1_block.dll.ev_seq;
  reg [47:0] last;
  always @(posedge clk) begin
    if ({d_wr, d_send, d_ack, s_ptr, slots, ackd[5:0], ntx[5:0]} !== last) begin
      last <= {d_wr, d_send, d_ack, s_ptr, slots, ackd[5:0], ntx[5:0]};
      if ($test$plusargs("dll_mon"))
        $display("[%t] dll_mon: d_wr=%0d d_send=%0d d_ack=%0d s_ptr=%0d slots=%0d ackd_seq=%0d next_tx_seq=%0d",
                 $realtime, d_wr, d_send, d_ack, s_ptr, slots, ackd, ntx);
    end
    if (ev && $test$plusargs("dll_mon")) $display("[%t] dll_mon: ack/nak event seq=%0d", $realtime, evs);
  end
  wire tl_end = board.EP.pcie_7x_i.pcie_block_inst.pcie_2_1_block.tl_rx.tlrx_end;
  wire tl_ok  = board.EP.pcie_7x_i.pcie_block_inst.pcie_2_1_block.tl_rx.tlrx_ok;
  wire cfg_v  = board.EP.pcie_7x_i.pcie_block_inst.pcie_2_1_block.tl_rx.cfg_req_v;
  wire [9:0] cfg_a = board.EP.pcie_7x_i.pcie_block_inst.pcie_2_1_block.tl_rx.cfg_req_dwaddr;
  wire icpl_v = board.EP.pcie_7x_i.pcie_block_inst.pcie_2_1_block.tl_rx.icpl_v;
  wire icpl_ack = board.EP.pcie_7x_i.pcie_block_inst.pcie_2_1_block.tl_rx.icpl_ack;
  wire [2:0] ist = board.EP.pcie_7x_i.pcie_block_inst.pcie_2_1_block.tl_rx.ist;
  wire [2:0] txst = board.EP.pcie_7x_i.pcie_block_inst.pcie_2_1_block.tl_tx.st;
  wire tcfg_req = board.EP.pcie_7x_i.pcie_block_inst.pcie_2_1_block.tl_tx.trn_tcfg_req;
  wire tcfg_gnt = board.EP.pcie_7x_i.pcie_block_inst.pcie_2_1_block.tl_tx.trn_tcfg_gnt;
  wire [7:0] df_w = board.EP.pcie_7x_i.pcie_block_inst.pcie_2_1_block.tl_rx.df_w;
  wire [7:0] df_r = board.EP.pcie_7x_i.pcie_block_inst.pcie_2_1_block.tl_rx.df_r;
  reg [15:0] last2;
  always @(posedge clk) if ($test$plusargs("dll_mon")) begin
    if (tl_end) $display("[%t] tl_mon: TLP end ok=%b df_w=%0d df_r=%0d", $realtime, tl_ok, df_w, df_r);
    if (cfg_v) $display("[%t] tl_mon: cfg access dw=%03x", $realtime, cfg_a);
    if ({ist, txst, tcfg_req, tcfg_gnt, icpl_v, icpl_ack} !== last2[9:0]) begin
      last2[9:0] <= {ist, txst, tcfg_req, tcfg_gnt, icpl_v, icpl_ack};
      $display("[%t] tl_mon: rx_ist=%0d tx_st=%0d tcfg_req=%b gnt=%b icpl_v=%b ack=%b", $realtime, ist, txst, tcfg_req, tcfg_gnt, icpl_v, icpl_ack);
    end
  end
`endif
endmodule
