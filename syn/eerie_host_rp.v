// SPDX-License-Identifier: CERN-OHL-P
// pci_eerie root port for hardware tests: the Vivado 7-series root port core of the root port
// example (pcie_2_1_rport_7x, with pci_eerie in place of PCIE_2_1; sed-patched by vivado_impl.tcl
// and sim/run_host.sh) plus eerie_host_app on its AXI-stream and cfg_mgmt ports.
`timescale 1ns / 1ps
module eerie_host_rp #(
    parameter LANES       = 4,
    parameter ENABLE_GEN2 = 1,
    parameter UCF         = 2,          // user clock: 1 62.5, 2 125, 3 250 MHz
    parameter GT_DEVICE   = "GTX",
    parameter FAST_TRAIN  = "FALSE"
) (
    output [LANES-1:0] pci_exp_txp, output [LANES-1:0] pci_exp_txn,
    input  [LANES-1:0] pci_exp_rxp, input  [LANES-1:0] pci_exp_rxn,
    input  sys_clk,                     // 100 MHz reference clock (IBUFDS_GTE2 output)
    input  sys_rst_n,
    output user_clk,
    output user_lnk_up,
    // register bus (user_clk)
    input         req, input we, input [15:0] addr, input [31:0] wdata,
    output [31:0] rdata, output ack
);
    wire        user_reset;
    wire        s_axis_tx_tready;
    wire [63:0] s_axis_tx_tdata;
    wire [7:0]  s_axis_tx_tkeep;
    wire        s_axis_tx_tlast, s_axis_tx_tvalid;
    wire [63:0] m_axis_rx_tdata;
    wire [7:0]  m_axis_rx_tkeep;
    wire        m_axis_rx_tlast, m_axis_rx_tvalid;
    wire [21:0] m_axis_rx_tuser;
    wire [9:0]  cfg_mgmt_dwaddr;
    wire [31:0] cfg_mgmt_di, cfg_mgmt_do;
    wire [3:0]  cfg_mgmt_byte_en;
    wire        cfg_mgmt_rd_en, cfg_mgmt_wr_en, cfg_mgmt_rd_wr_done;
    wire [6:0]  pl_ctl;
    wire [5:0]  ltssm;
    wire        sel_rate, phy_lnk_up, gen2_cap, partner_gen2, upcfg_cap, change_done, rx_hot_rst;
    wire [1:0]  sel_width, lane_rev;
    wire [2:0]  init_width;
    wire [15:0] cfg_lstatus;
    wire [49:0] dbg;            // pci_eerie DBGVECA (pclk), when the core export patch is applied
    wire [49:0] gtdbg;          // GT wrapper reset state (syn/core_rp_dbg.sed)
    wire        msg_rx;
    reg  [7:0]  msg_cnt;
    always @(posedge user_clk) if (user_reset) msg_cnt <= 8'd0; else if (msg_rx) msg_cnt <= msg_cnt + 1'b1;

    // status: [0] user_lnk_up, [1] phy_lnk_up, [7:2] LTSSM, [8] 5.0 GT/s, [10:9] width (0 x1 .. 3 x8),
    // [13:11] initial width, [14] partner Gen2, [15] directed change done, [19:16] LnkSta width
    // [3:0] of cfg_lstatus[7:4], [23:20] cfg_lstatus[3:0] speed, [31:24] messages received
    wire [31:0] status = {msg_cnt, cfg_lstatus[3:0], cfg_lstatus[7:4], change_done, partner_gen2,
                          init_width, sel_width, sel_rate, ltssm, phy_lnk_up, user_lnk_up};

    pcie_2_1_rport_7x #(
        .PL_FAST_TRAIN(FAST_TRAIN), .C_DATA_WIDTH(64),
        .PCIE_GT_DEVICE(GT_DEVICE), .PCIE_USE_MODE(GT_DEVICE == "GTP" ? "1.0" : "3.0"),
        .PCIE_CHAN_BOND(GT_DEVICE == "GTP" ? 1 : 0),
        .LINK_CAP_MAX_LINK_WIDTH(LANES), .LTSSM_MAX_LINK_WIDTH(LANES),
        .LINK_CAP_MAX_LINK_SPEED(ENABLE_GEN2 ? 4'h2 : 4'h1), .LINK_CTRL2_TARGET_LINK_SPEED(ENABLE_GEN2 ? 4'h2 : 4'h1),
        .USER_CLK_FREQ(UCF), .DEV_CAP_MAX_PAYLOAD_SUPPORTED(1),
        // type-1 masks: bus numbers, memory and prefetchable windows writable, no I/O window
        .BAR0(32'h0), .BAR1(32'h0), .BAR2(32'h00FFFFFF), .BAR3(32'h0), .BAR4(32'hFFF0FFF0), .BAR5(32'hFFF1FFF1),
        .VC0_TX_LASTPACKET(28), .VC0_RX_RAM_LIMIT(13'h03FF), .VC0_CPL_INFINITE("TRUE"),
        .VC0_TOTAL_CREDITS_PD(154), .VC0_TOTAL_CREDITS_CD(154)
    ) core (
        .pci_exp_txp(pci_exp_txp), .pci_exp_txn(pci_exp_txn), .pci_exp_rxp(pci_exp_rxp), .pci_exp_rxn(pci_exp_rxn),
        .pipe_pclk_in(1'b0), .pipe_rxusrclk_in(1'b0), .pipe_rxoutclk_in({LANES{1'b0}}), .pipe_dclk_in(1'b0),
        .pipe_userclk1_in(1'b0), .pipe_userclk2_in(1'b0), .pipe_oobclk_in(1'b0), .pipe_mmcm_lock_in(1'b0),
        .pipe_txoutclk_out(), .pipe_rxoutclk_out(), .pipe_pclk_sel_out(), .pipe_gen3_out(),
        .user_clk_out(user_clk), .user_reset_out(user_reset), .user_lnk_up(user_lnk_up),
        .tx_buf_av(), .tx_cfg_req(), .tx_err_drop(), .tx_cfg_gnt(1'b1),
        .s_axis_tx_tdata(s_axis_tx_tdata), .s_axis_tx_tvalid(s_axis_tx_tvalid), .s_axis_tx_tready(s_axis_tx_tready),
        .s_axis_tx_tkeep(s_axis_tx_tkeep), .s_axis_tx_tlast(s_axis_tx_tlast), .s_axis_tx_tuser(4'd0),
        .m_axis_rx_tdata(m_axis_rx_tdata), .m_axis_rx_tvalid(m_axis_rx_tvalid), .m_axis_rx_tready(1'b1),
        .m_axis_rx_tkeep(m_axis_rx_tkeep), .m_axis_rx_tlast(m_axis_rx_tlast), .m_axis_rx_tuser(m_axis_rx_tuser),
        .rx_np_ok(1'b1), .rx_np_req(1'b1),
        .fc_cpld(), .fc_cplh(), .fc_npd(), .fc_nph(), .fc_pd(), .fc_ph(), .fc_sel(3'b0),
        .cfg_status(), .cfg_command(), .cfg_dstatus(), .cfg_dcommand(), .cfg_lstatus(cfg_lstatus), .cfg_lcommand(),
        .cfg_dcommand2(), .cfg_pcie_link_state(), .cfg_pmcsr_pme_en(), .cfg_pmcsr_pme_status(),
        .cfg_pmcsr_powerstate(), .cfg_received_func_lvl_rst(),
        .cfg_mgmt_do(cfg_mgmt_do), .cfg_mgmt_rd_wr_done(cfg_mgmt_rd_wr_done), .cfg_mgmt_di(cfg_mgmt_di),
        .cfg_mgmt_byte_en(cfg_mgmt_byte_en), .cfg_mgmt_dwaddr(cfg_mgmt_dwaddr),
        .cfg_mgmt_wr_en(cfg_mgmt_wr_en), .cfg_mgmt_rd_en(cfg_mgmt_rd_en), .cfg_mgmt_wr_readonly(1'b0),
        .cfg_err_ecrc(1'b0), .cfg_err_ur(1'b0), .cfg_err_cpl_timeout(1'b0), .cfg_err_cpl_unexpect(1'b0),
        .cfg_err_cpl_abort(1'b0), .cfg_err_posted(1'b0), .cfg_err_cor(1'b0), .cfg_err_atomic_egress_blocked(1'b0),
        .cfg_err_internal_cor(1'b0), .cfg_err_malformed(1'b0), .cfg_err_mc_blocked(1'b0), .cfg_err_poisoned(1'b0),
        .cfg_err_norecovery(1'b0), .cfg_err_tlp_cpl_header(48'h0), .cfg_err_cpl_rdy(), .cfg_err_locked(1'b0),
        .cfg_err_acs(1'b0), .cfg_err_internal_uncor(1'b0),
        .cfg_trn_pending(1'b0), .cfg_pm_halt_aspm_l0s(1'b0), .cfg_pm_halt_aspm_l1(1'b0),
        .cfg_pm_force_state_en(1'b0), .cfg_pm_force_state(2'b00), .cfg_dsn(64'h0),
        .cfg_msg_received(msg_rx), .cfg_msg_data(),
        .cfg_interrupt(1'b0), .cfg_interrupt_rdy(), .cfg_interrupt_assert(1'b0),
        .cfg_interrupt_di(8'h00), .cfg_interrupt_do(), .cfg_interrupt_mmenable(), .cfg_interrupt_msienable(),
        .cfg_interrupt_msixenable(), .cfg_interrupt_msixfm(), .cfg_interrupt_stat(1'b0),
        .cfg_pciecap_interrupt_msgnum(5'h00), .cfg_to_turnoff(), .cfg_turnoff_ok(1'b0),
        .cfg_bus_number(), .cfg_device_number(), .cfg_function_number(),
        .cfg_pm_wake(1'b0), .cfg_msg_received_pm_as_nak(), .cfg_msg_received_setslotpowerlimit(),
        .cfg_pm_send_pme_to(1'b0), .cfg_ds_bus_number(8'h0), .cfg_ds_device_number(5'h0), .cfg_ds_function_number(3'b000),
        .cfg_mgmt_wr_rw1c_as_rw(1'b0), .cfg_bridge_serr_en(), .cfg_slot_control_electromech_il_ctl_pulse(),
        .cfg_root_control_syserr_corr_err_en(), .cfg_root_control_syserr_non_fatal_err_en(),
        .cfg_root_control_syserr_fatal_err_en(), .cfg_root_control_pme_int_en(),
        .cfg_aer_rooterr_corr_err_reporting_en(), .cfg_aer_rooterr_non_fatal_err_reporting_en(),
        .cfg_aer_rooterr_fatal_err_reporting_en(), .cfg_aer_rooterr_corr_err_received(),
        .cfg_aer_rooterr_non_fatal_err_received(), .cfg_aer_rooterr_fatal_err_received(),
        .cfg_msg_received_err_cor(), .cfg_msg_received_err_non_fatal(), .cfg_msg_received_err_fatal(),
        .cfg_msg_received_pm_pme(), .cfg_msg_received_pme_to_ack(),
        .cfg_msg_received_assert_int_a(), .cfg_msg_received_assert_int_b(), .cfg_msg_received_assert_int_c(),
        .cfg_msg_received_assert_int_d(), .cfg_msg_received_deassert_int_a(), .cfg_msg_received_deassert_int_b(),
        .cfg_msg_received_deassert_int_c(), .cfg_msg_received_deassert_int_d(),
        .pl_directed_link_change(pl_ctl[1:0]), .pl_directed_link_width(pl_ctl[3:2]),
        .pl_directed_link_speed(pl_ctl[4]), .pl_directed_link_auton(pl_ctl[5]),
        .pl_upstream_prefer_deemph(1'b1), .pl_sel_lnk_rate(sel_rate), .pl_sel_lnk_width(sel_width),
        .pl_ltssm_state(ltssm), .pl_lane_reversal_mode(lane_rev), .pl_phy_lnk_up(phy_lnk_up), .pl_tx_pm_state(),
        .pl_rx_pm_state(), .pl_link_upcfg_cap(upcfg_cap), .pl_link_gen2_cap(gen2_cap),
        .pl_link_partner_gen2_supported(partner_gen2), .pl_initial_link_width(init_width),
        .pl_directed_change_done(change_done), .pl_received_hot_rst(rx_hot_rst), .pl_downstream_deemph_source(1'b0),
        .pl_transmit_hot_rst(pl_ctl[6]),
        .cfg_err_aer_headerlog(128'b0), .cfg_aer_interrupt_msgnum(5'b0), .cfg_err_aer_headerlog_set(),
        .cfg_aer_ecrc_check_en(), .cfg_aer_ecrc_gen_en(), .cfg_vc_tcvc_map(),
        .common_commands_in(12'b0), .pipe_rx_0_sigs(25'b0), .pipe_rx_1_sigs(25'b0), .pipe_rx_2_sigs(25'b0),
        .pipe_rx_3_sigs(25'b0), .pipe_rx_4_sigs(25'b0), .pipe_rx_5_sigs(25'b0), .pipe_rx_6_sigs(25'b0),
        .pipe_rx_7_sigs(25'b0), .common_commands_out(), .pipe_tx_0_sigs(dbg[24:0]), .pipe_tx_1_sigs(dbg[49:25]), .pipe_tx_2_sigs(gtdbg[24:0]),
        .pipe_tx_3_sigs(gtdbg[49:25]), .pipe_tx_4_sigs(), .pipe_tx_5_sigs(), .pipe_tx_6_sigs(), .pipe_tx_7_sigs(),
        .pipe_mmcm_rst_n(1'b1), .sys_clk(sys_clk), .sys_rst_n(sys_rst_n)
    );

    eerie_host_app app (
        .clk(user_clk), .rst(user_reset),
        .req(req), .we(we), .addr(addr), .wdata(wdata), .rdata(rdata), .ack(ack),
        .s_axis_tx_tready(s_axis_tx_tready), .s_axis_tx_tdata(s_axis_tx_tdata), .s_axis_tx_tkeep(s_axis_tx_tkeep),
        .s_axis_tx_tlast(s_axis_tx_tlast), .s_axis_tx_tvalid(s_axis_tx_tvalid),
        .m_axis_rx_tdata(m_axis_rx_tdata), .m_axis_rx_tkeep(m_axis_rx_tkeep), .m_axis_rx_tlast(m_axis_rx_tlast),
        .m_axis_rx_tvalid(m_axis_rx_tvalid), .m_axis_rx_tuser(m_axis_rx_tuser),
        .cfg_mgmt_dwaddr(cfg_mgmt_dwaddr), .cfg_mgmt_di(cfg_mgmt_di), .cfg_mgmt_byte_en(cfg_mgmt_byte_en),
        .cfg_mgmt_rd_en(cfg_mgmt_rd_en), .cfg_mgmt_wr_en(cfg_mgmt_wr_en), .cfg_mgmt_do(cfg_mgmt_do),
        .cfg_mgmt_rd_wr_done(cfg_mgmt_rd_wr_done), .status(status), .dbg(dbg), .gtdbg(gtdbg), .pl_ctl(pl_ctl)
    );
endmodule
