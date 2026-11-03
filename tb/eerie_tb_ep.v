// SPDX-License-Identifier: CERN-OHL-P
// pci_eerie testbench endpoint: pcie_7x (with either PCIE_2_1 or pci_eerie inside
// pcie_block) plus a small memory application on the AXI-stream interface.
//
// Application:
//   * MWr32/MWr64 of any length into a 4 KB memory (address bits [11:2])
//   * MRd32/MRd64 up to 32 DW answered with a single CplD
//   * write to offset 0xFF0 triggers an interrupt (data bit 0 = assert for INTx)
`timescale 1ns / 1ps
module eerie_tb_ep #(
    parameter ENABLE_GEN2 = 0,
    parameter GT_DEVICE   = "GTX"
) (
    output pci_exp_txp, output pci_exp_txn,
    input  pci_exp_rxp, input  pci_exp_rxn,
    input  sys_clk_p,   input  sys_clk_n,
    input  sys_rst_n
);
    wire sys_clk;
    IBUFDS_GTE2 refclk_ibuf (.O(sys_clk), .ODIV2(), .I(sys_clk_p), .CEB(1'b0), .IB(sys_clk_n));

    wire        user_clk, user_reset, user_lnk_up;
    wire        s_axis_tx_tready;
    reg  [63:0] s_axis_tx_tdata;
    reg  [7:0]  s_axis_tx_tkeep;
    reg         s_axis_tx_tlast, s_axis_tx_tvalid;
    wire [63:0] m_axis_rx_tdata;
    wire [7:0]  m_axis_rx_tkeep;
    wire        m_axis_rx_tlast, m_axis_rx_tvalid;
    wire [21:0] m_axis_rx_tuser;
    wire [7:0]  cfg_bus_number;
    wire [4:0]  cfg_device_number;
    wire [2:0]  cfg_function_number;
    wire        cfg_to_turnoff, cfg_interrupt_rdy, cfg_interrupt_msienable;
    reg         cfg_interrupt, cfg_interrupt_assert;
    reg         user_reset_q;
    always @(posedge user_clk) user_reset_q <= user_reset;

    pcie_7x #(
        .PCIE_GT_DEVICE(GT_DEVICE), .PCIE_USE_MODE("3.0"),
        .LINK_CAP_MAX_LINK_SPEED(ENABLE_GEN2 ? 4'h2 : 4'h1), .LINK_CTRL2_TARGET_LINK_SPEED(ENABLE_GEN2 ? 4'h2 : 4'h1),
        .LINK_STATUS_SLOT_CLOCK_CONFIG("TRUE"), .USER_CLK_FREQ(ENABLE_GEN2 ? 2 : 1),
        .CFG_DEV_ID(16'h9999), .BAR0(32'hFFFFF000),
        .DEV_CAP_MAX_PAYLOAD_SUPPORTED(1), .VC0_RX_RAM_LIMIT(13'h3FF),
        .VC0_TOTAL_CREDITS_CD(370), .VC0_TOTAL_CREDITS_CH(72), .VC0_TOTAL_CREDITS_NPH(4),
        .VC0_TOTAL_CREDITS_NPD(8), .VC0_TOTAL_CREDITS_PD(32), .VC0_TOTAL_CREDITS_PH(4), .VC0_TX_LASTPACKET(28)
    ) pcie_7x_i (
        .pci_exp_txn(pci_exp_txn), .pci_exp_txp(pci_exp_txp), .pci_exp_rxn(pci_exp_rxn), .pci_exp_rxp(pci_exp_rxp),
        .pipe_mmcm_lock(), .pipe_mmcm_rst_n(1'b1),
        .user_clk_out(user_clk), .user_reset_out(user_reset), .user_lnk_up(user_lnk_up),
        .s_axis_tx_tready(s_axis_tx_tready), .s_axis_tx_tdata(s_axis_tx_tdata), .s_axis_tx_tkeep(s_axis_tx_tkeep),
        .s_axis_tx_tuser(4'd0), .s_axis_tx_tlast(s_axis_tx_tlast), .s_axis_tx_tvalid(s_axis_tx_tvalid),
        .m_axis_rx_tdata(m_axis_rx_tdata), .m_axis_rx_tkeep(m_axis_rx_tkeep), .m_axis_rx_tlast(m_axis_rx_tlast),
        .m_axis_rx_tvalid(m_axis_rx_tvalid), .m_axis_rx_tready(1'b1), .m_axis_rx_tuser(m_axis_rx_tuser),
        .tx_cfg_gnt(1'b1), .rx_np_ok(1'b1), .rx_np_req(1'b1), .cfg_trn_pending(1'b0),
        .cfg_pm_halt_aspm_l0s(1'b0), .cfg_pm_halt_aspm_l1(1'b0), .cfg_pm_force_state_en(1'b0),
        .cfg_pm_force_state(2'b00), .cfg_dsn(64'h0000000101000a35), .cfg_turnoff_ok(cfg_to_turnoff), .cfg_pm_wake(1'b0),
        .cfg_interrupt(cfg_interrupt), .cfg_interrupt_rdy(cfg_interrupt_rdy), .cfg_interrupt_assert(cfg_interrupt_assert),
        .cfg_interrupt_di(8'h00), .cfg_interrupt_do(), .cfg_interrupt_mmenable(),
        .cfg_interrupt_msienable(cfg_interrupt_msienable), .cfg_interrupt_msixenable(), .cfg_interrupt_msixfm(),
        .cfg_interrupt_stat(1'b0), .cfg_pciecap_interrupt_msgnum(5'd0),
        .cfg_status(), .cfg_command(), .cfg_dstatus(), .cfg_lstatus(), .cfg_pcie_link_state(), .cfg_dcommand(),
        .cfg_lcommand(), .cfg_dcommand2(), .cfg_pmcsr_pme_en(), .cfg_pmcsr_powerstate(), .cfg_pmcsr_pme_status(),
        .cfg_received_func_lvl_rst(), .tx_buf_av(), .tx_err_drop(), .tx_cfg_req(), .cfg_to_turnoff(cfg_to_turnoff),
        .cfg_bus_number(cfg_bus_number), .cfg_device_number(cfg_device_number), .cfg_function_number(cfg_function_number),
        .sys_clk(sys_clk), .sys_rst_n(sys_rst_n), .gt_reset_fsm(), .pl_ltssm_state(),
        .pipe_pclk_in(1'b0), .pipe_dclk_in(1'b0), .pipe_oobclk_in(1'b0), .pipe_userclk1_in(1'b0),
        .pipe_userclk2_in(1'b0), .pipe_mmcm_lock_in(1'b0), .pipe_rxusrclk_in(1'b0), .pipe_rxoutclk_in(1'b0),
        .pipe_pclk_sel_out(), .pipe_txoutclk_out()
    );

    // ---------------------------------------------------------------- memory
    reg [31:0] mem [0:1023];
    integer mi;
    initial for (mi = 0; mi < 1024; mi = mi + 1) mem[mi] = 32'h0;

    // ---------------------------------------------------------------- RX
    // AXI 7-series format: tdata[31:0] = first DW, [63:32] = second DW
    reg        rx_in, rx_wr, rx_4dw, rx_first;
    reg [9:0]  rx_addr;
    reg [31:0] h0, h1;
    reg        rd_req; reg [31:0] rd_h0, rd_h1; reg [9:0] rd_addr;
    reg        irq_req; reg irq_val;
    wire [31:0] d_lo = m_axis_rx_tdata[31:0], d_hi = m_axis_rx_tdata[63:32];
    reg        rd_busy;
    always @(posedge user_clk) begin
        if (user_reset_q) begin
            rx_in <= 1'b0; rd_req <= 1'b0; irq_req <= 1'b0;
        end else begin
            if (rd_req && rd_busy) rd_req <= 1'b0;
            if (m_axis_rx_tvalid) begin
                if (!rx_in) begin
                    // beat 0: DW0, DW1
                    h0 <= d_lo; h1 <= d_hi; rx_in <= !m_axis_rx_tlast; rx_first <= 1'b1;
                    rx_wr <= d_lo[30]; rx_4dw <= d_lo[29];
                end else begin
                    rx_first <= 1'b0;
                    if (rx_first) begin
                        // beat 1: DW2, DW3
                        if (!rx_4dw) begin
                            rx_addr <= d_lo[11:2] + 1'b1;
                            if (rx_wr) begin
                                mem[d_lo[11:2]] <= d_hi;
                                if (d_lo[11:2] == 10'h3FC) begin irq_req <= 1'b1; irq_val <= d_hi[24]; end
                            end else if (h0[28:24] == 5'b00000) begin
                                rd_req <= 1'b1; rd_h0 <= h0; rd_h1 <= h1; rd_addr <= d_lo[11:2];
                            end
                        end else begin
                            rx_addr <= d_hi[11:2];
                            if (!rx_wr && h0[28:24] == 5'b00000) begin
                                rd_req <= 1'b1; rd_h0 <= h0; rd_h1 <= h1; rd_addr <= d_hi[11:2];
                            end
                        end
                    end else if (rx_wr && h0[28:24] == 5'b00000) begin
                        mem[rx_addr] <= d_lo;
                        if (m_axis_rx_tkeep[4]) mem[rx_addr + 1'b1] <= d_hi;
                        if (rx_addr == 10'h3FC) begin irq_req <= 1'b1; irq_val <= d_lo[24]; end
                        rx_addr <= rx_addr + 2'd2;
                    end
                    if (m_axis_rx_tlast) rx_in <= 1'b0;
                end
            end
            if (irq_req && cfg_interrupt_rdy) irq_req <= 1'b0;
        end
    end

    // ---------------------------------------------------------------- TX (completions)
    reg [9:0]  c_len, c_left;
    reg [9:0]  c_addr;
    reg [1:0]  c_st;
    reg        c_odd;
    wire [15:0] cid = {cfg_bus_number, cfg_device_number, cfg_function_number};
    always @(posedge user_clk) begin
        if (user_reset_q) begin
            rd_busy <= 1'b0; s_axis_tx_tvalid <= 1'b0; c_st <= 2'd0;
        end else begin
            case (c_st)
            2'd0: begin
                s_axis_tx_tvalid <= 1'b0;
                if (rd_req && !rd_busy) begin
                    rd_busy <= 1'b1;
                    c_len  <= rd_h0[9:0]; c_addr <= rd_addr;
                    // DW0 CplD, DW1 completer/bytecount
                    s_axis_tx_tdata <= {cid, 3'b000, 1'b0, {rd_h0[9:0], 2'b00},
                                        {3'b010, 5'b01010, 1'b0, rd_h0[22:20], 4'h0, 2'b00, rd_h0[13:12], 2'b00, rd_h0[9:0]}};
                    s_axis_tx_tkeep <= 8'hFF; s_axis_tx_tlast <= 1'b0; s_axis_tx_tvalid <= 1'b1;
                    c_st <= 2'd1;
                end
            end
            2'd1: if (s_axis_tx_tready) begin
                // DW2 requester/tag/lower address, DW3 first data
                s_axis_tx_tdata <= {mem[c_addr], rd_h1[31:16], rd_h1[15:8], 1'b0, c_addr[4:0], 2'b00};
                s_axis_tx_tlast <= (c_len == 10'd1);
                c_addr <= c_addr + 1'b1; c_left <= c_len - 1'b1;
                c_st <= (c_len == 10'd1) ? 2'd3 : 2'd2;
            end
            2'd2: if (s_axis_tx_tready) begin
                s_axis_tx_tdata <= {mem[c_addr + 1'b1], mem[c_addr]};
                s_axis_tx_tkeep <= (c_left == 10'd1) ? 8'h0F : 8'hFF;
                s_axis_tx_tlast <= (c_left <= 10'd2);
                c_addr <= c_addr + 2'd2;
                c_left <= (c_left <= 10'd2) ? 10'd0 : c_left - 2'd2;
                if (c_left <= 10'd2) c_st <= 2'd3;
            end
            default: if (s_axis_tx_tready) begin
                s_axis_tx_tvalid <= 1'b0; s_axis_tx_tlast <= 1'b0; rd_busy <= 1'b0; c_st <= 2'd0;
            end
            endcase
        end
    end

    // ---------------------------------------------------------------- interrupt
    always @(posedge user_clk) begin
        if (user_reset_q) begin cfg_interrupt <= 1'b0; cfg_interrupt_assert <= 1'b0; end
        else if (cfg_interrupt && cfg_interrupt_rdy) cfg_interrupt <= 1'b0;
        else if (irq_req && !cfg_interrupt) begin cfg_interrupt <= 1'b1; cfg_interrupt_assert <= irq_val; end
    end
endmodule
