// SPDX-License-Identifier: CERN-OHL-P
// pci_eerie: open-source soft PCI Express endpoint for 7-series FPGAs.
//
// IO-level drop-in replacement for the PCIE_2_1 integrated block: same port
// names and parameters (all accepted, the relevant subset is honoured), PIPE
// interface towards the GT wrapper, TRN interface towards the user, and the
// MIM ports used for the external TX (replay/queue) and RX buffer BRAMs.
//
// Scope: endpoint (UPSTREAM_FACING), x1, 2.5 / 5.0 GT/s, 64-bit TRN,
// USERCLK2 == USERCLK.  See doc/README.md for the list of supported features.
`timescale 1ns / 1ps
module pci_eerie #(
`include "pci_eerie_params.vh"
) (
`include "pci_eerie_ports.vh"
);
    // ------------------------------------------------------------------
    // derived configuration
    // ------------------------------------------------------------------
    localparam MAX_RATE  = (LINK_CAP_MAX_LINK_SPEED >= 4'h2) ? 2 : 1;
    localparam FAST      = (PL_FAST_TRAIN == "TRUE");
    localparam CPL_INF   = (VC0_CPL_INFINITE == "TRUE");
    localparam MPS_BYTES = 128 << DEV_CAP_MAX_PAYLOAD_SUPPORTED;
    localparam MAX_TLP_BEATS = 2 + MPS_BYTES / 8;
    localparam RXB_AW    = (VC0_RX_RAM_LIMIT >= 13'h1000) ? 13 : (VC0_RX_RAM_LIMIT >= 13'h800) ? 12 :
                           (VC0_RX_RAM_LIMIT >= 13'h400) ? 11 : (VC0_RX_RAM_LIMIT >= 13'h200) ? 10 :
                           (VC0_RX_RAM_LIMIT >= 13'h100) ? 9 : 8;
    // round VC0_RX_RAM_LIMIT+1 up to a power of two (the BRAMs are sized the same way)
    localparam TXB_AW    = RXB_AW;
    localparam TXB_RLAT  = TL_TX_RAM_RDATA_LATENCY;
    localparam RXB_RLAT  = TL_RX_RAM_RDATA_LATENCY;
    localparam MAX_UNACK = (VC0_TX_LASTPACKET + 1 > 31) ? 31 : VC0_TX_LASTPACKET + 1;
    // replay timer in user clocks; 4 symbol times per user clock at the
    // supported USERCLK settings (62.5 MHz @ 2.5 GT/s, 125 MHz @ 5 GT/s)
    localparam [15:0] REPLAY_T = (LL_REPLAY_TIMEOUT_EN == "TRUE") ? LL_REPLAY_TIMEOUT[14:2] + 16'd64 :
                                 (MPS_BYTES <= 128) ? 16'd400 : (MPS_BYTES <= 256) ? 16'd500 :
                                 (MPS_BYTES <= 512) ? 16'd700 : 16'd1200;

    wire pclk = PIPECLK;
    wire uclk = USERCLK;

    // ------------------------------------------------------------------
    // configuration-style inputs: in simulation an undriven (Z/X) pin reads as
    // it would in hardware (data/IDs 0, active-low requests inactive), so a
    // floating wrapper port cannot poison TLPs with X.  No logic in synthesis.
    // ------------------------------------------------------------------
`ifndef SYNTHESIS
    // synthesis translate_off
`define EERIE_SIM_XFILTER
    // synthesis translate_on
`endif
`ifdef EERIE_SIM_XFILTER
    function [63:0] xz0; input [63:0] v; integer i;
        begin for (i = 0; i < 64; i = i + 1) xz0[i] = (v[i] === 1'b1); end
    endfunction
    function xz1; input v; xz1 = (v !== 1'b0); endfunction
`else
    function [63:0] xz0; input [63:0] v; xz0 = v; endfunction
    function xz1; input v; xz1 = v; endfunction
`endif
    wire [4:0]  s_msgnum    = xz0(CFGPCIECAPINTERRUPTMSGNUM);
    wire [63:0] s_dsn       = xz0(CFGDSN);
    wire [7:0]  s_int_di    = xz0(CFGINTERRUPTDI);
    wire [15:0] s_vend_id   = xz0(CFGVENDID), s_dev_id = xz0(CFGDEVID);
    wire [15:0] s_ssvid     = xz0(CFGSUBSYSVENDID), s_ssid = xz0(CFGSUBSYSID);
    wire [7:0]  s_rev_id    = xz0(CFGREVID);
    wire        s_int_n     = xz1(CFGINTERRUPTN), s_int_assert_n = xz1(CFGINTERRUPTASSERTN);
    wire        s_trnpend_n = xz1(CFGTRNPENDINGN), s_pmwake_n = xz1(CFGPMWAKEN);
    wire        s_turnoff_n = xz1(CFGPMTURNOFFOKN);
    wire        s_err_ur_n  = xz1(CFGERRURN), s_err_cor_n = xz1(CFGERRCORN), s_err_abort_n = xz1(CFGERRCPLABORTN);
    wire        s_mg_rd_n   = xz1(CFGMGMTRDENN), s_mg_wr_n = xz1(CFGMGMTWRENN);
    wire        s_mg_rw1c_n = xz1(CFGMGMTWRRW1CASRWN), s_mg_ro_n = xz1(CFGMGMTWRREADONLYN);
    wire [3:0]  s_mg_be_n   = ~xz0(~CFGMGMTBYTEENN);
    wire [9:0]  s_mg_addr   = xz0(CFGMGMTDWADDR);
    wire [31:0] s_mg_di     = xz0(CFGMGMTDI);
    wire        s_tcfg_gnt  = xz0(TRNTCFGGNT);

    // ------------------------------------------------------------------
    // resets
    // ------------------------------------------------------------------
    wire arst = !SYSRSTN || !PLRSTN;
    wire p_rst, u_rst;
    eerie_reset_sync rs_p (.clk(pclk), .arst(arst), .rst(p_rst));
    eerie_reset_sync rs_u (.clk(uclk), .arst(arst), .rst(u_rst));

    // ------------------------------------------------------------------
    // physical layer (PIPE clock domain)
    // ------------------------------------------------------------------
    wire        os_ts_valid, os_ts2, os_ts_inv, os_link_pad, os_lane_pad, os_eios, os_skp, os_idle2, os_pkt_start;
    wire [7:0]  os_link, os_lane, os_nfts, os_rate, os_ctrl;
    wire        rx_err;
    wire        plrx_we;
    wire [81:0] plrx_wd;
    wire        scramble_en;
    wire        pl_descr_en = scramble_en && (DISABLE_SCRAMBLING != "TRUE");

    eerie_pl_rx pl_rx (
        .clk(pclk), .rst(p_rst),
        .pipe_rxdata(PIPERX0DATA), .pipe_rxdatak(PIPERX0CHARISK), .pipe_rxvalid(PIPERX0VALID),
        .pipe_rxstatus(PIPERX0STATUS), .pipe_rxelecidle(PIPERX0ELECIDLE), .descramble_en(pl_descr_en),
        .os_ts_valid(os_ts_valid), .os_ts2(os_ts2), .os_ts_inv(os_ts_inv),
        .os_link(os_link), .os_link_pad(os_link_pad), .os_lane(os_lane), .os_lane_pad(os_lane_pad),
        .os_nfts(os_nfts), .os_rate(os_rate), .os_ctrl(os_ctrl),
        .os_eios(os_eios), .os_skp(os_skp), .os_idle2(os_idle2), .os_pkt_start(os_pkt_start), .rx_err(rx_err),
        .pkt_we(plrx_we), .pkt_wd(plrx_wd)
    );

    wire [2:0]  tx_mode;
    wire [7:0]  tx_link, tx_lane, tx_nfts, tx_rate, tx_ctrl;
    wire        tx_link_pad, tx_lane_pad;
    wire        tx_ts_done, tx_eios_done, tx_idle_pair, tx_busy, eieos_clr;
    wire [66:0] pltx_rd_data;
    wire        pltx_rd_empty, pltx_rd_en;
    wire        retrain_p;
    wire        p_link_up, p_in_l0, p_hot_reset, p_link_training, p_partner_gen2;
    wire [5:0]  p_ltssm;
    wire [7:0]  p_link_num;
    wire        p_rate;

    eerie_pl_tx pl_tx (
        .clk(pclk), .rst(p_rst),
        .mode(tx_mode), .ts_link(tx_link), .ts_link_pad(tx_link_pad), .ts_lane(tx_lane), .ts_lane_pad(tx_lane_pad),
        .ts_nfts(tx_nfts), .ts_rate(tx_rate), .ts_ctrl(tx_ctrl),
        .scramble_en(pl_descr_en), .gen2(p_rate), .eieos_clr(eieos_clr),
        .ts_done(tx_ts_done), .eios_done(tx_eios_done), .idle_pair(tx_idle_pair), .busy(tx_busy),
        .pkt_rd_data(pltx_rd_data), .pkt_rd_empty(pltx_rd_empty), .pkt_rd_en(pltx_rd_en),
        .pipe_txdata(PIPETX0DATA), .pipe_txdatak(PIPETX0CHARISK), .pipe_txelecidle(PIPETX0ELECIDLE)
    );

    eerie_ltssm #(
        .MAX_RATE(MAX_RATE), .FAST_TRAIN(FAST), .N_FTS_GEN1(N_FTS_GEN1), .N_FTS_GEN2(N_FTS_GEN2),
        .UPCONFIG(UPCONFIG_CAPABLE == "TRUE")
    ) ltssm (
        .clk(pclk), .rst(p_rst),
        .pipe_txdetectrx(PIPETXRCVRDET), .pipe_powerdown(PIPETX0POWERDOWN), .pipe_rate(p_rate),
        .pipe_rxpolarity(PIPERX0POLARITY), .i_pipe_phystatus(PIPERX0PHYSTATUS), .i_pipe_rxstatus(PIPERX0STATUS),
        .i_pipe_rxelecidle(PIPERX0ELECIDLE),
        .tx_mode(tx_mode), .tx_link(tx_link), .tx_link_pad(tx_link_pad), .tx_lane(tx_lane), .tx_lane_pad(tx_lane_pad),
        .tx_nfts(tx_nfts), .tx_rate(tx_rate), .tx_ctrl(tx_ctrl),
        .tx_ts_done(tx_ts_done), .tx_eios_done(tx_eios_done), .tx_idle_pair(tx_idle_pair), .tx_busy(tx_busy),
        .scramble_en(scramble_en), .eieos_clr(eieos_clr),
        .i_os_ts_valid(os_ts_valid), .i_os_ts2(os_ts2), .i_os_ts_inv(os_ts_inv), .i_os_link(os_link),
        .i_os_link_pad(os_link_pad), .i_os_lane(os_lane), .i_os_lane_pad(os_lane_pad), .i_os_nfts(os_nfts),
        .i_os_rate(os_rate), .i_os_ctrl(os_ctrl), .i_os_eios(os_eios), .i_os_idle2(os_idle2),
        .retrain_req(retrain_p),
        .link_up(p_link_up), .in_l0(p_in_l0), .ltssm_state(p_ltssm), .hot_reset(p_hot_reset),
        .link_training(p_link_training), .partner_gen2(p_partner_gen2), .link_num(p_link_num),
        .rcvr_err_ltssm()
    );
    assign PIPETXRATE        = p_rate;
    assign PIPETXDEEMPH      = 1'b1;          // -3.5 dB
    assign PIPETXMARGIN      = 3'b000;
    assign PIPETXRESET       = 1'b0;
    assign PIPETX0COMPLIANCE = 1'b0;

    assign PLLTSSMSTATE      = p_ltssm;
    assign PLSELLNKRATE      = p_rate;
    assign PLSELLNKWIDTH     = 2'b00;
    assign PLPHYLNKUPN       = !p_link_up;
    assign PLLINKGEN2CAP     = (MAX_RATE >= 2);
    assign PLLINKPARTNERGEN2SUPPORTED = p_partner_gen2;
    assign PLLINKUPCFGCAP    = 1'b0;
    assign PLINITIALLINKWIDTH = 3'b001;
    assign PLLANEREVERSALMODE = 2'b00;
    assign PLRXPMSTATE       = 2'b00;
    assign PLTXPMSTATE       = 3'b000;
    assign PLRECEIVEDHOTRST  = p_hot_reset;
    assign PLDIRECTEDCHANGEDONE = 1'b0;
    assign PLDBGVEC          = 12'd0;
    assign PL2LINKUP         = p_link_up;
    assign PL2RECEIVERERR    = rx_err;
    assign PL2RECOVERY       = (p_ltssm >= 6'h1C && p_ltssm <= 6'h20);
    assign PL2RXELECIDLE     = PIPERX0ELECIDLE;
    assign PL2RXPMSTATE      = 2'b00;
    assign PL2SUSPENDOK      = 1'b0;
    assign PL2L0REQ          = 1'b0;

    // ------------------------------------------------------------------
    // clock domain crossing
    // ------------------------------------------------------------------
    wire u_link_up, u_in_l0, u_rate, u_training, u_hot_reset;
    eerie_sync_bits #(.W(5)) sync_u (.clk(uclk), .d({p_link_up, p_in_l0, p_rate, p_link_training, p_hot_reset}),
                                     .q({u_link_up, u_in_l0, u_rate, u_training, u_hot_reset}));
    reg  u_lrst = 1'b1;                               // link-scope reset, user clock (registered)
    always @(posedge uclk) u_lrst <= u_rst || !u_link_up;
    wire p_lrst;                                      // same, delayed into the PIPE clock domain
    eerie_sync_bits #(.W(1), .INIT(1'b1)) sync_lrst (.clk(pclk), .d(u_lrst), .q(p_lrst));
    wire u_retrain;
    eerie_sync_pulse sync_retrain (.src_clk(uclk), .src_pulse(u_retrain), .dst_clk(pclk), .dst_pulse(retrain_p));

    wire [81:0] plrx_rd_d;
    wire        plrx_rd_empty, plrx_rd;
    eerie_async_fifo #(.W(82), .AW(4), .PKT_MODE(0)) rx_fifo (
        .wr_clk(pclk), .wr_rst(p_lrst || p_rst), .wr_en(plrx_we), .wr_data(plrx_wd), .wr_last(1'b1), .wr_full(), .wr_free(),
        .rd_clk(uclk), .rd_rst(u_lrst), .rd_en(plrx_rd), .rd_data(plrx_rd_d), .rd_empty(plrx_rd_empty)
    );

    wire        pltx_we, pltx_full;
    wire [66:0] pltx_wd;
    wire [7:0]  pltx_free;
    eerie_async_fifo #(.W(67), .AW(7), .PKT_MODE(1)) tx_fifo (
        .wr_clk(uclk), .wr_rst(u_lrst), .wr_en(pltx_we), .wr_data(pltx_wd), .wr_last(pltx_wd[65]),
        .wr_full(pltx_full), .wr_free(pltx_free),
        .rd_clk(pclk), .rd_rst(p_lrst || p_rst), .rd_en(pltx_rd_en), .rd_data(pltx_rd_data), .rd_empty(pltx_rd_empty)
    );

    // ------------------------------------------------------------------
    // data link layer (user clock domain)
    // ------------------------------------------------------------------
    wire        c_pme_en, c_pme_sts, c_msi_en, c_msix_en, c_msix_fm, flr_pulse;
    wire        dl_up, dl_init;
    wire        tlrx_v, tlrx_sop, tlrx_half, tlrx_end, tlrx_ok;
    wire [63:0] tlrx_d;
    wire        txq_v, txq_sop, txq_eop, txq_half, txq_abort;
    wire [63:0] txq_d;
    wire [5:0]  txq_slots;
    wire [7:0]  fc_ph, fc_nph, fc_cplh;
    wire [11:0] fc_pd, fc_npd, fc_cpld;
    wire [2:0]  fc_upd_req;
    wire [7:0]  lim_ph, lim_nph, lim_cplh, cons_ph, cons_nph, cons_cplh;
    wire [11:0] lim_pd, lim_npd, lim_cpld, cons_pd, cons_npd, cons_cpld;
    wire [5:0]  inf_mask;
    wire        e_bad_tlp, e_bad_dllp, e_rro, e_rto, e_dlp;
    wire [31:0] dllp_rx_data;
    wire        dllp_rx_v;
    wire        txb_we, txb_re;
    wire [12:0] txb_waddr, txb_raddr;
    wire [68:0] txb_wdata;

    eerie_dll #(
        .TXB_AW(TXB_AW), .TXB_RLAT(TXB_RLAT), .MAX_TLP_BEATS(MAX_TLP_BEATS), .NDESC_AW(5),
        .MAX_UNACKED(MAX_UNACK), .REPLAY_TIMEOUT(REPLAY_T), .ACK_DELAY(8'd2), .UPDFC_PERIOD(16'd1500),
        .CPL_INFINITE(CPL_INF)
    ) dll (
        .clk(uclk), .rst(u_rst), .link_up(u_link_up), .link_l0(u_in_l0),
        .dl_up(dl_up), .dl_init(dl_init), .retrain_req(u_retrain),
        .plrx_d(plrx_rd_d), .plrx_empty(plrx_rd_empty), .plrx_rd(plrx_rd),
        .pltx_we(pltx_we), .pltx_wd(pltx_wd), .pltx_full(pltx_full), .pltx_free(pltx_free),
        .tlrx_v(tlrx_v), .tlrx_d(tlrx_d), .tlrx_sop(tlrx_sop), .tlrx_half(tlrx_half), .tlrx_end(tlrx_end), .tlrx_ok(tlrx_ok),
        .txq_v(txq_v), .txq_d(txq_d), .txq_sop(txq_sop), .txq_eop(txq_eop), .txq_half(txq_half), .txq_abort(txq_abort),
        .txq_slots(txq_slots),
        .fc_ph(fc_ph), .fc_pd(fc_pd), .fc_nph(fc_nph), .fc_npd(fc_npd), .fc_cplh(fc_cplh), .fc_cpld(fc_cpld),
        .fc_upd_req(fc_upd_req),
        .lim_ph(lim_ph), .lim_pd(lim_pd), .lim_nph(lim_nph), .lim_npd(lim_npd), .lim_cplh(lim_cplh), .lim_cpld(lim_cpld),
        .cons_ph(cons_ph), .cons_pd(cons_pd), .cons_nph(cons_nph), .cons_npd(cons_npd), .cons_cplh(cons_cplh), .cons_cpld(cons_cpld),
        .inf_mask(inf_mask),
        .err_bad_tlp(e_bad_tlp), .err_bad_dllp(e_bad_dllp), .err_replay_rollover(e_rro), .err_replay_timeout(e_rto),
        .err_dl_protocol(e_dlp), .dllp_rx_data(dllp_rx_data), .dllp_rx_v(dllp_rx_v),
        .txb_we(txb_we), .txb_waddr(txb_waddr), .txb_wdata(txb_wdata), .txb_re(txb_re), .txb_raddr(txb_raddr),
        .txb_rdata(MIMTXRDATA)
    );
    assign MIMTXWEN = txb_we;  assign MIMTXWADDR = txb_waddr; assign MIMTXWDATA = txb_wdata;
    assign MIMTXREN = txb_re;  assign MIMTXRADDR = txb_raddr;

    assign LL2BADDLLPERR  = e_bad_dllp;
    assign LL2BADTLPERR   = e_bad_tlp;
    assign LL2PROTOCOLERR = e_dlp;
    assign LL2RECEIVERERR = 1'b0;
    assign LL2REPLAYROERR = e_rro;
    assign LL2REPLAYTOERR = e_rto;
    assign LL2SUSPENDOK   = 1'b0;
    assign LL2TFCINIT1SEQ = 1'b0;
    assign LL2TFCINIT2SEQ = 1'b0;
    assign LL2TXIDLE      = 1'b0;
    assign LL2LINKSTATUS  = {dl_up, dl_init, 3'b000};
    assign TRNRDLLPDATA   = {32'd0, dllp_rx_data};
    assign TRNRDLLPSRCRDY = {1'b0, dllp_rx_v};
    assign TRNTDLLPDSTRDY = 1'b0;
    assign TRNLNKUP       = dl_up;
    assign USERRSTN       = !u_rst;
    assign LNKCLKEN       = 1'b1;
    assign RECEIVEDFUNCLVLRSTN = !flr_pulse;

    // ------------------------------------------------------------------
    // transaction layer + configuration space
    // ------------------------------------------------------------------
    wire [15:0] c_command, c_status, c_devctl, c_devsts, c_lnkctl, c_lnksts, c_devctl2, c_lnkctl2;
    wire [1:0]  c_pm_state;
    wire [2:0]  c_msi_mme;
    wire [63:0] c_msi_addr;
    wire [15:0] c_msi_data;
    wire [7:0]  c_int_line;
    wire [31:0] c_bar0, c_bar1, c_bar2, c_bar3, c_bar4, c_bar5, c_rom;
    wire        c_rom_en;
    wire [31:0] cfg_rd_data;

    // TL RX config requests and the management port share the config space
    wire        tl_cfg_v, tl_cfg_wr;
    wire [9:0]  tl_cfg_a;
    wire [3:0]  tl_cfg_be;
    wire [31:0] tl_cfg_wd;
    reg         mg_busy, mg_done;
    wire        mg_req = (!s_mg_rd_n || !s_mg_wr_n) && !mg_busy && !mg_done && !tl_cfg_v;
    always @(posedge uclk) begin
        if (u_rst) begin mg_busy <= 1'b0; mg_done <= 1'b0; end
        else begin
            mg_done <= mg_busy;
            mg_busy <= mg_req;
        end
    end
    assign CFGMGMTRDWRDONEN = !mg_done;
    assign CFGMGMTDO        = cfg_rd_data;

    wire        icpl_v, icpl_hasd, icpl_ack;
    wire [2:0]  icpl_status, icpl_tc;
    wire [31:0] icpl_data;
    wire [15:0] icpl_reqid;
    wire [7:0]  icpl_tag;
    wire [1:0]  icpl_attr;
    wire [6:0]  icpl_laddr;
    wire [11:0] icpl_bcnt;
    wire [7:0]  bus_num;
    wire [4:0]  dev_num;
    wire        msg_received, msg_pme_to, msg_unlock, msg_setslot;
    wire [15:0] msg_data;
    wire [9:0]  msg_slot_pwr;
    wire        e_ur, e_ur_np, e_malformed, e_overflow, e_poisoned;
    wire        intx_state;

    eerie_cfg #(
        .CLASS_CODE(CLASS_CODE), .BAR0(BAR0), .BAR1(BAR1), .BAR2(BAR2), .BAR3(BAR3), .BAR4(BAR4), .BAR5(BAR5),
        .EXPANSION_ROM(EXPANSION_ROM), .CARDBUS_CIS_POINTER(CARDBUS_CIS_POINTER), .HEADER_TYPE(HEADER_TYPE),
        .INTERRUPT_PIN(INTERRUPT_PIN), .CAPABILITIES_PTR(CAPABILITIES_PTR), .CMD_INTX_IMPLEMENTED(CMD_INTX_IMPLEMENTED),
        .PM_CAP_ON(PM_CAP_ON), .PM_BASE_PTR(PM_BASE_PTR), .PM_CAP_NEXTPTR(PM_CAP_NEXTPTR), .PM_CAP_VERSION(PM_CAP_VERSION),
        .PM_CAP_PME_CLOCK(PM_CAP_PME_CLOCK), .PM_CAP_DSI(PM_CAP_DSI), .PM_CAP_AUXCURRENT(PM_CAP_AUXCURRENT),
        .PM_CAP_D1SUPPORT(PM_CAP_D1SUPPORT), .PM_CAP_D2SUPPORT(PM_CAP_D2SUPPORT), .PM_CAP_PMESUPPORT(PM_CAP_PMESUPPORT),
        .PM_CSR_NOSOFTRST(PM_CSR_NOSOFTRST),
        .MSI_CAP_ON(MSI_CAP_ON), .MSI_BASE_PTR(MSI_BASE_PTR), .MSI_CAP_NEXTPTR(MSI_CAP_NEXTPTR),
        .MSI_CAP_MULTIMSGCAP(MSI_CAP_MULTIMSGCAP), .MSI_CAP_64_BIT_ADDR_CAPABLE(MSI_CAP_64_BIT_ADDR_CAPABLE),
        .MSI_CAP_PER_VECTOR_MASKING_CAPABLE(MSI_CAP_PER_VECTOR_MASKING_CAPABLE),
        .MSIX_CAP_ON(MSIX_CAP_ON), .MSIX_BASE_PTR(MSIX_BASE_PTR), .MSIX_CAP_NEXTPTR(MSIX_CAP_NEXTPTR),
        .MSIX_CAP_TABLE_SIZE(MSIX_CAP_TABLE_SIZE), .MSIX_CAP_TABLE_BIR(MSIX_CAP_TABLE_BIR),
        .MSIX_CAP_TABLE_OFFSET(MSIX_CAP_TABLE_OFFSET), .MSIX_CAP_PBA_BIR(MSIX_CAP_PBA_BIR),
        .MSIX_CAP_PBA_OFFSET(MSIX_CAP_PBA_OFFSET),
        .PCIE_BASE_PTR(PCIE_BASE_PTR), .PCIE_CAP_NEXTPTR(PCIE_CAP_NEXTPTR),
        .PCIE_CAP_CAPABILITY_VERSION(PCIE_CAP_CAPABILITY_VERSION), .PCIE_CAP_DEVICE_PORT_TYPE(PCIE_CAP_DEVICE_PORT_TYPE),
        .PCIE_CAP_SLOT_IMPLEMENTED(PCIE_CAP_SLOT_IMPLEMENTED),
        .DEV_CAP_MAX_PAYLOAD_SUPPORTED(DEV_CAP_MAX_PAYLOAD_SUPPORTED),
        .DEV_CAP_PHANTOM_FUNCTIONS_SUPPORT(DEV_CAP_PHANTOM_FUNCTIONS_SUPPORT),
        .DEV_CAP_EXT_TAG_SUPPORTED(DEV_CAP_EXT_TAG_SUPPORTED),
        .DEV_CAP_ENDPOINT_L0S_LATENCY(DEV_CAP_ENDPOINT_L0S_LATENCY), .DEV_CAP_ENDPOINT_L1_LATENCY(DEV_CAP_ENDPOINT_L1_LATENCY),
        .DEV_CAP_ROLE_BASED_ERROR(DEV_CAP_ROLE_BASED_ERROR),
        .DEV_CAP_FUNCTION_LEVEL_RESET_CAPABLE(DEV_CAP_FUNCTION_LEVEL_RESET_CAPABLE),
        .DEV_CONTROL_EXT_TAG_DEFAULT(DEV_CONTROL_EXT_TAG_DEFAULT),
        .LINK_CAP_MAX_LINK_SPEED(LINK_CAP_MAX_LINK_SPEED), .LINK_CAP_MAX_LINK_WIDTH(LINK_CAP_MAX_LINK_WIDTH),
        .LINK_CAP_ASPM_SUPPORT(LINK_CAP_ASPM_SUPPORT),
        .LINK_CAP_L0S_EXIT_LATENCY_GEN1(LINK_CAP_L0S_EXIT_LATENCY_GEN1), .LINK_CAP_L0S_EXIT_LATENCY_GEN2(LINK_CAP_L0S_EXIT_LATENCY_GEN2),
        .LINK_CAP_L0S_EXIT_LATENCY_COMCLK_GEN1(LINK_CAP_L0S_EXIT_LATENCY_COMCLK_GEN1),
        .LINK_CAP_L0S_EXIT_LATENCY_COMCLK_GEN2(LINK_CAP_L0S_EXIT_LATENCY_COMCLK_GEN2),
        .LINK_CAP_L1_EXIT_LATENCY_GEN1(LINK_CAP_L1_EXIT_LATENCY_GEN1), .LINK_CAP_L1_EXIT_LATENCY_GEN2(LINK_CAP_L1_EXIT_LATENCY_GEN2),
        .LINK_CAP_L1_EXIT_LATENCY_COMCLK_GEN1(LINK_CAP_L1_EXIT_LATENCY_COMCLK_GEN1),
        .LINK_CAP_L1_EXIT_LATENCY_COMCLK_GEN2(LINK_CAP_L1_EXIT_LATENCY_COMCLK_GEN2),
        .LINK_CAP_CLOCK_POWER_MANAGEMENT(LINK_CAP_CLOCK_POWER_MANAGEMENT),
        .LINK_CAP_SURPRISE_DOWN_ERROR_CAPABLE(LINK_CAP_SURPRISE_DOWN_ERROR_CAPABLE),
        .LINK_CAP_DLL_LINK_ACTIVE_REPORTING_CAP(LINK_CAP_DLL_LINK_ACTIVE_REPORTING_CAP),
        .LINK_CAP_LINK_BANDWIDTH_NOTIFICATION_CAP(LINK_CAP_LINK_BANDWIDTH_NOTIFICATION_CAP),
        .LINK_CAP_ASPM_OPTIONALITY(LINK_CAP_ASPM_OPTIONALITY),
        .LINK_STATUS_SLOT_CLOCK_CONFIG(LINK_STATUS_SLOT_CLOCK_CONFIG),
        .LINK_CTRL2_TARGET_LINK_SPEED(LINK_CTRL2_TARGET_LINK_SPEED), .LINK_CTRL2_DEEMPHASIS(LINK_CTRL2_DEEMPHASIS),
        .CPL_TIMEOUT_RANGES_SUPPORTED(CPL_TIMEOUT_RANGES_SUPPORTED),
        .CPL_TIMEOUT_DISABLE_SUPPORTED(CPL_TIMEOUT_DISABLE_SUPPORTED),
        .DSN_CAP_ON(DSN_CAP_ON), .DSN_BASE_PTR(DSN_BASE_PTR), .DSN_CAP_NEXTPTR(DSN_CAP_NEXTPTR)
    ) cfg (
        .clk(uclk), .rst(u_lrst),
        .req_v(tl_cfg_v || mg_req), .req_wr(tl_cfg_v ? tl_cfg_wr : !s_mg_wr_n),
        .req_dwaddr(tl_cfg_v ? tl_cfg_a : s_mg_addr), .req_be(tl_cfg_v ? tl_cfg_be : ~s_mg_be_n),
        .req_wdata(tl_cfg_v ? tl_cfg_wd : s_mg_di),
        .req_rw1c_as_rw(!tl_cfg_v && !s_mg_rw1c_n), .req_ro_wr(!tl_cfg_v && !s_mg_ro_n),
        .rd_data(cfg_rd_data),
        .vend_id(s_vend_id), .dev_id(s_dev_id), .rev_id(s_rev_id), .subsys_vend_id(s_ssvid),
        .subsys_id(s_ssid), .dsn(s_dsn), .pciecap_int_msgnum(s_msgnum),
        .link_speed(u_rate ? 4'd2 : 4'd1), .link_width(6'd1), .link_training(u_training), .dll_active(dl_up),
        .intx_status(intx_state), .trn_pending(!s_trnpend_n),
        .set_ur_detected(e_ur || !s_err_ur_n), .set_corr_detected(!s_err_cor_n || e_bad_tlp || e_bad_dllp || e_rto || e_rro),
        .set_nonfatal_detected(e_poisoned), .set_fatal_detected(e_malformed || e_overflow || e_dlp),
        .set_sig_target_abort(!s_err_abort_n), .set_rcv_master_abort(1'b0), .set_sig_sys_error(1'b0),
        .set_detected_parity(e_poisoned), .set_master_data_parity(1'b0), .set_rcv_target_abort(1'b0),
        .set_pme_status(1'b0), .slot_pwr_v(msg_setslot), .slot_pwr(msg_slot_pwr),
        .command(c_command), .status(c_status), .dev_control(c_devctl), .dev_status(c_devsts),
        .link_control(c_lnkctl), .link_status(c_lnksts), .dev_control2(c_devctl2), .link_control2(c_lnkctl2),
        .pm_power_state(c_pm_state), .pm_pme_en(c_pme_en), .pm_pme_status(c_pme_sts),
        .msi_enable(c_msi_en), .msi_mme(c_msi_mme), .msi_addr(c_msi_addr), .msi_data(c_msi_data),
        .msix_enable(c_msix_en), .msix_fmask(c_msix_fm), .int_line(c_int_line), .flr_pulse(flr_pulse),
        .bar0(c_bar0), .bar1(c_bar1), .bar2(c_bar2), .bar3(c_bar3), .bar4(c_bar4), .bar5(c_bar5),
        .rom_bar(c_rom), .rom_en(c_rom_en)
    );

    eerie_tl_rx #(
        .RXB_AW(RXB_AW), .RXB_RLAT(RXB_RLAT),
        .BAR0(BAR0), .BAR1(BAR1), .BAR2(BAR2), .BAR3(BAR3), .BAR4(BAR4), .BAR5(BAR5), .EXPANSION_ROM(EXPANSION_ROM),
        .INIT_PH(VC0_TOTAL_CREDITS_PH), .INIT_PD(VC0_TOTAL_CREDITS_PD),
        .INIT_NPH(VC0_TOTAL_CREDITS_NPH), .INIT_NPD(VC0_TOTAL_CREDITS_NPD),
        .INIT_CPLH(VC0_TOTAL_CREDITS_CH), .INIT_CPLD(VC0_TOTAL_CREDITS_CD), .CPL_INFINITE(CPL_INF)
    ) tl_rx (
        .clk(uclk), .rst(u_lrst),
        .tlrx_v(tlrx_v), .tlrx_d(tlrx_d), .tlrx_sop(tlrx_sop), .tlrx_half(tlrx_half), .tlrx_end(tlrx_end), .tlrx_ok(tlrx_ok),
        .rxb_we(MIMRXWEN), .rxb_waddr(MIMRXWADDR), .rxb_wdata(MIMRXWDATA),
        .rxb_re(MIMRXREN), .rxb_raddr(MIMRXRADDR), .rxb_rdata(MIMRXRDATA),
        .command(c_command), .bar0(c_bar0), .bar1(c_bar1), .bar2(c_bar2), .bar3(c_bar3), .bar4(c_bar4), .bar5(c_bar5),
        .rom_bar(c_rom), .rom_en(c_rom_en),
        .trn_rd(TRNRD[63:0]), .trn_rrem(TRNRREM[0]), .trn_rsof(TRNRSOF), .trn_reof(TRNREOF),
        .trn_rsrc_rdy(TRNRSRCRDY), .trn_rdst_rdy(TRNRDSTRDY), .trn_rerrfwd(TRNRERRFWD), .trn_rbar_hit(TRNRBARHIT),
        .cfg_req_v(tl_cfg_v), .cfg_req_wr(tl_cfg_wr), .cfg_req_dwaddr(tl_cfg_a), .cfg_req_be(tl_cfg_be),
        .cfg_req_wdata(tl_cfg_wd), .cfg_rd_data(cfg_rd_data), .bus_num(bus_num), .dev_num(dev_num),
        .icpl_v(icpl_v), .icpl_status(icpl_status), .icpl_hasd(icpl_hasd), .icpl_data(icpl_data),
        .icpl_reqid(icpl_reqid), .icpl_tag(icpl_tag), .icpl_tc(icpl_tc), .icpl_attr(icpl_attr),
        .icpl_laddr(icpl_laddr), .icpl_bcnt(icpl_bcnt), .icpl_ack(icpl_ack),
        .msg_received(msg_received), .msg_data(msg_data), .msg_pme_to(msg_pme_to), .msg_unlock(msg_unlock),
        .msg_setslot(msg_setslot), .msg_slot_pwr(msg_slot_pwr),
        .err_ur(e_ur), .err_ur_np(e_ur_np), .err_malformed(e_malformed), .err_overflow(e_overflow), .err_poisoned(e_poisoned),
        .fc_ph(fc_ph), .fc_pd(fc_pd), .fc_nph(fc_nph), .fc_npd(fc_npd), .fc_cplh(fc_cplh), .fc_cpld(fc_cpld),
        .fc_upd_req(fc_upd_req)
    );
    assign TRNRD[127:64]  = 64'd0;
    assign TRNRREM[1]     = 1'b0;
    assign TRNRSRCDSC     = 1'b0;
    assign TRNRECRCERR    = 1'b0;

    // PME_Turn_Off -> PME_TO_Ack once the user agrees (CFGPMTURNOFFOKN)
    reg pme_to_pend, pme_ack_req;
    always @(posedge uclk) begin
        pme_ack_req <= 1'b0;
        if (u_lrst) pme_to_pend <= 1'b0;
        else if (msg_pme_to) pme_to_pend <= 1'b1;
        else if (pme_to_pend && !s_turnoff_n) begin pme_to_pend <= 1'b0; pme_ack_req <= 1'b1; end
    end
    reg pm_wake_d;
    always @(posedge uclk) pm_wake_d <= !s_pmwake_n;
    wire pm_pme_req = !s_pmwake_n && !pm_wake_d;

    wire tdst_rdy;
    wire int_rdy;
    wire [5:0] tbuf_av;
    eerie_tl_tx #(.INTERRUPT_PIN(INTERRUPT_PIN)) tl_tx (
        .clk(uclk), .rst(u_lrst), .dl_up(dl_up),
        .trn_td(TRNTD[63:0]), .trn_trem(TRNTREM[0]), .trn_tsof(TRNTSOF), .trn_teof(TRNTEOF), .trn_tsrc_rdy(TRNTSRCRDY),
        .trn_tsrc_dsc(TRNTSRCDSC), .trn_terrfwd(TRNTERRFWD),
        .trn_tdst_rdy(tdst_rdy), .trn_terr_drop(TRNTERRDROP), .trn_tbuf_av(tbuf_av), .trn_tcfg_req(TRNTCFGREQ),
        .trn_tcfg_gnt(s_tcfg_gnt),
        .txq_v(txq_v), .txq_d(txq_d), .txq_sop(txq_sop), .txq_eop(txq_eop), .txq_half(txq_half), .txq_abort(txq_abort),
        .txq_slots(txq_slots),
        .req_id({bus_num, dev_num, 3'b000}), .command(c_command),
        .msi_enable(c_msi_en), .msi_mme(c_msi_mme), .msi_addr(c_msi_addr), .msi_data(c_msi_data),
        .icpl_v(icpl_v), .icpl_status(icpl_status), .icpl_hasd(icpl_hasd), .icpl_data(icpl_data),
        .icpl_reqid(icpl_reqid), .icpl_tag(icpl_tag), .icpl_tc(icpl_tc), .icpl_attr(icpl_attr),
        .icpl_laddr(icpl_laddr), .icpl_bcnt(icpl_bcnt), .icpl_ack(icpl_ack),
        .int_req(!s_int_n), .int_assert(!s_int_assert_n), .int_di(s_int_di),
        .int_rdy(int_rdy), .intx_state(intx_state),
        .pme_to_ack_req(pme_ack_req), .pm_pme_req(pm_pme_req)
    );
    assign TRNTDSTRDY  = {4{tdst_rdy}};
    assign TRNTBUFAV   = tbuf_av;

    // ------------------------------------------------------------------
    // configuration status outputs
    // ------------------------------------------------------------------
    assign CFGCOMMANDIOENABLE        = c_command[0];
    assign CFGCOMMANDMEMENABLE       = c_command[1];
    assign CFGCOMMANDBUSMASTERENABLE = c_command[2];
    assign CFGCOMMANDSERREN          = c_command[8];
    assign CFGCOMMANDINTERRUPTDISABLE = c_command[10];
    assign CFGBRIDGESERREN           = 1'b0;
    assign CFGDEVCONTROLCORRERRREPORTINGEN  = c_devctl[0];
    assign CFGDEVCONTROLNONFATALREPORTINGEN = c_devctl[1];
    assign CFGDEVCONTROLFATALERRREPORTINGEN = c_devctl[2];
    assign CFGDEVCONTROLURERRREPORTINGEN    = c_devctl[3];
    assign CFGDEVCONTROLENABLERO            = c_devctl[4];
    assign CFGDEVCONTROLMAXPAYLOAD          = c_devctl[7:5];
    assign CFGDEVCONTROLEXTTAGEN            = c_devctl[8];
    assign CFGDEVCONTROLPHANTOMEN           = c_devctl[9];
    assign CFGDEVCONTROLAUXPOWEREN          = c_devctl[10];
    assign CFGDEVCONTROLNOSNOOPEN           = c_devctl[11];
    assign CFGDEVCONTROLMAXREADREQ          = c_devctl[14:12];
    assign CFGDEVSTATUSCORRERRDETECTED      = c_devsts[0];
    assign CFGDEVSTATUSNONFATALERRDETECTED  = c_devsts[1];
    assign CFGDEVSTATUSFATALERRDETECTED     = c_devsts[2];
    assign CFGDEVSTATUSURDETECTED           = c_devsts[3];
    assign CFGDEVCONTROL2CPLTIMEOUTVAL      = c_devctl2[3:0];
    assign CFGDEVCONTROL2CPLTIMEOUTDIS      = c_devctl2[4];
    assign CFGDEVCONTROL2ARIFORWARDEN       = 1'b0;
    assign CFGDEVCONTROL2ATOMICREQUESTEREN  = 1'b0;
    assign CFGDEVCONTROL2ATOMICEGRESSBLOCK  = 1'b0;
    assign CFGDEVCONTROL2IDOREQEN           = 1'b0;
    assign CFGDEVCONTROL2IDOCPLEN           = 1'b0;
    assign CFGDEVCONTROL2LTREN              = 1'b0;
    assign CFGDEVCONTROL2TLPPREFIXBLOCK     = 1'b0;
    assign CFGLINKCONTROLASPMCONTROL        = c_lnkctl[1:0];
    assign CFGLINKCONTROLRCB                = c_lnkctl[3];
    assign CFGLINKCONTROLLINKDISABLE        = c_lnkctl[4];
    assign CFGLINKCONTROLRETRAINLINK        = c_lnkctl[5];
    assign CFGLINKCONTROLCOMMONCLOCK        = c_lnkctl[6];
    assign CFGLINKCONTROLEXTENDEDSYNC       = c_lnkctl[7];
    assign CFGLINKCONTROLCLOCKPMEN          = c_lnkctl[8];
    assign CFGLINKCONTROLHWAUTOWIDTHDIS     = c_lnkctl[9];
    assign CFGLINKCONTROLBANDWIDTHINTEN     = c_lnkctl[10];
    assign CFGLINKCONTROLAUTOBANDWIDTHINTEN = c_lnkctl[11];
    assign CFGLINKSTATUSCURRENTSPEED        = c_lnksts[1:0];
    assign CFGLINKSTATUSNEGOTIATEDWIDTH     = c_lnksts[7:4];
    assign CFGLINKSTATUSLINKTRAINING        = c_lnksts[11];
    assign CFGLINKSTATUSDLLACTIVE           = dl_up;
    assign CFGLINKSTATUSBANDWIDTHSTATUS     = 1'b0;
    assign CFGLINKSTATUSAUTOBANDWIDTHSTATUS = 1'b0;
    assign CFGPMCSRPOWERSTATE  = c_pm_state;
    assign CFGPMCSRPMEEN       = c_pme_en;
    assign CFGPMCSRPMESTATUS   = c_pme_sts;
    assign CFGPCIELINKSTATE    = u_in_l0 ? 3'b000 : 3'b100;
    assign CFGPMRCVASREQL1N    = 1'b1;
    assign CFGPMRCVENTERL1N    = 1'b1;
    assign CFGPMRCVENTERL23N   = 1'b1;
    assign CFGPMRCVREQACKN     = 1'b1;
    assign CFGINTERRUPTRDYN    = !int_rdy;
    assign CFGINTERRUPTDO      = c_msi_data[7:0];
    assign CFGINTERRUPTMMENABLE = c_msi_mme;
    assign CFGINTERRUPTMSIENABLE = c_msi_en;
    assign CFGINTERRUPTMSIXENABLE = c_msix_en;
    assign CFGINTERRUPTMSIXFM  = c_msix_fm;
    // CFGMSGDATA carries the captured bus/device number when no message is reported
    assign CFGMSGRECEIVED      = msg_received;
    assign CFGMSGDATA          = msg_received ? msg_data : {bus_num, dev_num, 3'b000};
    assign CFGMSGRECEIVEDPMETO = msg_pme_to;
    assign CFGMSGRECEIVEDUNLOCK = msg_unlock;
    assign CFGMSGRECEIVEDSETSLOTPOWERLIMIT = msg_setslot;
    assign CFGMSGRECEIVEDASSERTINTA = 1'b0;   assign CFGMSGRECEIVEDDEASSERTINTA = 1'b0;
    assign CFGMSGRECEIVEDASSERTINTB = 1'b0;   assign CFGMSGRECEIVEDDEASSERTINTB = 1'b0;
    assign CFGMSGRECEIVEDASSERTINTC = 1'b0;   assign CFGMSGRECEIVEDDEASSERTINTC = 1'b0;
    assign CFGMSGRECEIVEDASSERTINTD = 1'b0;   assign CFGMSGRECEIVEDDEASSERTINTD = 1'b0;
    assign CFGMSGRECEIVEDERRCOR = 1'b0;      assign CFGMSGRECEIVEDERRFATAL = 1'b0;
    assign CFGMSGRECEIVEDERRNONFATAL = 1'b0;  assign CFGMSGRECEIVEDPMASNAK = 1'b0;
    assign CFGMSGRECEIVEDPMETOACK = 1'b0;     assign CFGMSGRECEIVEDPMPME = 1'b0;
    assign CFGTRANSACTION      = tl_cfg_v;
    assign CFGTRANSACTIONTYPE  = tl_cfg_wr;
    assign CFGTRANSACTIONADDR  = tl_cfg_a[6:0];
    assign CFGVCTCVCMAP        = 7'h7F;
    assign CFGERRCPLRDYN       = 1'b0;
    assign CFGERRAERHEADERLOGSETN = 1'b1;
    assign CFGAERECRCCHECKEN   = 1'b0;  assign CFGAERECRCGENEN = 1'b0;
    assign CFGAERROOTERRCORRERRRECEIVED = 1'b0;  assign CFGAERROOTERRCORRERRREPORTINGEN = 1'b0;
    assign CFGAERROOTERRFATALERRRECEIVED = 1'b0; assign CFGAERROOTERRFATALERRREPORTINGEN = 1'b0;
    assign CFGAERROOTERRNONFATALERRRECEIVED = 1'b0; assign CFGAERROOTERRNONFATALERRREPORTINGEN = 1'b0;
    assign CFGROOTCONTROLPMEINTEN = 1'b0; assign CFGROOTCONTROLSYSERRCORRERREN = 1'b0;
    assign CFGROOTCONTROLSYSERRFATALERREN = 1'b0; assign CFGROOTCONTROLSYSERRNONFATALERREN = 1'b0;
    assign CFGSLOTCONTROLELECTROMECHILCTLPULSE = 1'b0;

    // flow control information (TRNFCSEL: 0xx receive allocation, 1xx transmit available)
    assign TRNFCPH   = TRNFCSEL[2] ? lim_ph   - cons_ph   : fc_ph;
    assign TRNFCPD   = TRNFCSEL[2] ? lim_pd   - cons_pd   : fc_pd;
    assign TRNFCNPH  = TRNFCSEL[2] ? lim_nph  - cons_nph  : fc_nph;
    assign TRNFCNPD  = TRNFCSEL[2] ? lim_npd  - cons_npd  : fc_npd;
    assign TRNFCCPLH = TRNFCSEL[2] ? lim_cplh - cons_cplh : fc_cplh;
    assign TRNFCCPLD = TRNFCSEL[2] ? lim_cpld - cons_cpld : fc_cpld;

    assign TL2ASPMSUSPENDCREDITCHECKOK = 1'b0;
    assign TL2ASPMSUSPENDREQ = 1'b0;
    assign TL2ERRFCPE        = 1'b0;
    assign TL2ERRMALFORMED   = e_malformed;
    assign TL2ERRRXOVERFLOW  = e_overflow;
    assign TL2PPMSUSPENDOK   = 1'b0;
    assign TL2ERRHDR         = 64'd0;

    // ------------------------------------------------------------------
    // unused lanes / debug / DRP
    // ------------------------------------------------------------------
    assign PIPERX1POLARITY = 1'b0; assign PIPERX2POLARITY = 1'b0; assign PIPERX3POLARITY = 1'b0;
    assign PIPERX4POLARITY = 1'b0; assign PIPERX5POLARITY = 1'b0; assign PIPERX6POLARITY = 1'b0;
    assign PIPERX7POLARITY = 1'b0;
    assign PIPETX1COMPLIANCE = 1'b0; assign PIPETX2COMPLIANCE = 1'b0; assign PIPETX3COMPLIANCE = 1'b0;
    assign PIPETX4COMPLIANCE = 1'b0; assign PIPETX5COMPLIANCE = 1'b0; assign PIPETX6COMPLIANCE = 1'b0;
    assign PIPETX7COMPLIANCE = 1'b0;
    assign PIPETX1ELECIDLE = 1'b1; assign PIPETX2ELECIDLE = 1'b1; assign PIPETX3ELECIDLE = 1'b1;
    assign PIPETX4ELECIDLE = 1'b1; assign PIPETX5ELECIDLE = 1'b1; assign PIPETX6ELECIDLE = 1'b1;
    assign PIPETX7ELECIDLE = 1'b1;
    assign PIPETX1DATA = 16'd0; assign PIPETX2DATA = 16'd0; assign PIPETX3DATA = 16'd0; assign PIPETX4DATA = 16'd0;
    assign PIPETX5DATA = 16'd0; assign PIPETX6DATA = 16'd0; assign PIPETX7DATA = 16'd0;
    assign PIPETX1CHARISK = 2'b00; assign PIPETX2CHARISK = 2'b00; assign PIPETX3CHARISK = 2'b00;
    assign PIPETX4CHARISK = 2'b00; assign PIPETX5CHARISK = 2'b00; assign PIPETX6CHARISK = 2'b00;
    assign PIPETX7CHARISK = 2'b00;
    assign PIPETX1POWERDOWN = 2'b10; assign PIPETX2POWERDOWN = 2'b10; assign PIPETX3POWERDOWN = 2'b10;
    assign PIPETX4POWERDOWN = 2'b10; assign PIPETX5POWERDOWN = 2'b10; assign PIPETX6POWERDOWN = 2'b10;
    assign PIPETX7POWERDOWN = 2'b10;

    reg drp_rdy;
    always @(posedge DRPCLK) drp_rdy <= DRPEN;
    assign DRPRDY = drp_rdy;
    assign DRPDO  = 16'd0;
    assign DBGVECA = 64'd0; assign DBGVECB = 64'd0; assign DBGVECC = 12'd0;
    assign DBGSCLRA = 1'b0; assign DBGSCLRB = 1'b0; assign DBGSCLRC = 1'b0; assign DBGSCLRD = 1'b0;
    assign DBGSCLRE = 1'b0; assign DBGSCLRF = 1'b0; assign DBGSCLRG = 1'b0; assign DBGSCLRH = 1'b0;
    assign DBGSCLRI = 1'b0; assign DBGSCLRJ = 1'b0; assign DBGSCLRK = 1'b0;
endmodule
