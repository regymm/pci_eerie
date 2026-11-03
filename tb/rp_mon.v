// SPDX-License-Identifier: CERN-OHL-P
// pci_eerie testbench helpers
//  * captures every TLP the root port model delivers on its TRN RX interface
//  * optional PIPE-level error injection on the endpoint side:
//      +inject_rx_tlp=N  flip one bit inside the N-th TLP received by the EP
//      +inject_tx_tlp=N  flip one bit inside the N-th TLP transmitted by the EP
`timescale 1ps/1ps
module rp_mon;
    // ---------------- TLP capture (root port TRN RX) ----------------
    wire        clk  = board.RP.trn_clk;
    wire [63:0] rd   = board.RP.trn_rd;
    wire        sof  = board.RP.trn_rsof;
    wire        eof  = board.RP.trn_reof;
    wire        srdy = board.RP.trn_rsrc_rdy;
    wire        drdy = !board.RP.trn_rdst_rdy_n;
    wire        rrem = board.RP.trn_rrem[0];

    reg [31:0]  cur [0:1100];
    integer     cur_n;
    reg [31:0]  last [0:1100];     // last completed TLP
    integer     last_n;
    integer     tlp_count;
    initial begin tlp_count = 0; cur_n = 0; last_n = 0; end
    always @(posedge clk) if (srdy && drdy) begin
        if (sof) cur_n = 0;
        cur[cur_n] = rd[63:32]; cur_n = cur_n + 1;
        if (!eof || rrem) begin cur[cur_n] = rd[31:0]; cur_n = cur_n + 1; end
        if (eof) begin : copy
            integer k;
            for (k = 0; k < cur_n; k = k + 1) last[k] = cur[k];
            last_n = cur_n;
            tlp_count = tlp_count + 1;
            if ($test$plusargs("rp_mon_verbose"))
                $display("[%t] rp_mon: TLP %0d dw0=%h dw1=%h dw2=%h dw3=%h (%0d DW)", $realtime, tlp_count,
                         cur[0], cur[1], cur[2], cur[3], cur_n);
        end
    end

    // wait for the next TLP whose DW0[28:24] type matches (mask) and return
    task wait_tlp;
        input [4:0] typ;
        input [4:0] typ_mask;
        input integer timeout_clks;
        output reg  found;
        integer start, t;
        begin
            found = 0; start = tlp_count; t = 0;
            while (!found && t < timeout_clks) begin
                @(posedge clk); t = t + 1;
                if (tlp_count != start) begin
                    start = tlp_count;
                    if (((last[0][28:24] ^ typ) & typ_mask) == 0) found = 1;
                end
            end
        end
    endtask

    // pcie_7x_top_aximm leaves cfg_pciecap_interrupt_msgnum undriven; X on it reaches the
    // PCIe capability register (0x60) and poisons that completion, for PCIE_2_1 as well
`ifndef EERIE_APP
    initial force board.EP.cfg_pciecap_interrupt_msgnum = 5'd0;
`endif

    // legacy interrupt messages are consumed by the root port and reported on its cfg interface
    integer inta_assert, inta_deassert;
    initial begin inta_assert = 0; inta_deassert = 0; end
    always @(posedge clk) begin
        if (board.RP.rport.cfg_msg_received_assert_int_a)   inta_assert   = inta_assert + 1;
        if (board.RP.rport.cfg_msg_received_deassert_int_a) inta_deassert = inta_deassert + 1;
    end

    // ---------------- error injection on the endpoint PIPE ----------------
    wire        pclk = board.EP.pcie_7x_i.pcie_block_inst.pipe_clk;
    wire [15:0] erxd = board.EP.pcie_7x_i.pcie_block_inst.pipe_rx0_data_gt;
    wire [1:0]  erxk = board.EP.pcie_7x_i.pcie_block_inst.pipe_rx0_char_is_k_gt;
    wire [15:0] etxd = board.EP.pcie_7x_i.pcie_block_inst.pipe_tx0_data_gt;
    wire [1:0]  etxk = board.EP.pcie_7x_i.pcie_block_inst.pipe_tx0_char_is_k_gt;
    integer inj_rx, inj_tx, n_rx, n_tx, rx_cd, tx_cd;
    reg [15:0] fval;
    initial begin
        if (!$value$plusargs("inject_rx_tlp=%d", inj_rx)) inj_rx = -1;
        if (!$value$plusargs("inject_tx_tlp=%d", inj_tx)) inj_tx = -1;
        n_rx = 0; n_tx = 0; rx_cd = -1; tx_cd = -1;
    end
    always @(posedge pclk) begin
        if ((erxk[0] && erxd[7:0] == 8'hFB) || (erxk[1] && erxd[15:8] == 8'hFB)) begin
            n_rx = n_rx + 1;
            if (n_rx == inj_rx) rx_cd = 4;
        end
        if (rx_cd == 0) begin
            $display("[%t] rp_mon: injecting bit error into EP RX TLP #%0d", $realtime, n_rx);
            fval = erxd ^ 16'h0010;
            force board.EP.pcie_7x_i.pcie_block_inst.pipe_rx0_data_gt = fval;
            @(posedge pclk); #100;
            release board.EP.pcie_7x_i.pcie_block_inst.pipe_rx0_data_gt;
        end
        if (rx_cd >= 0) rx_cd = rx_cd - 1;
        if ((etxk[0] && etxd[7:0] == 8'hFB) || (etxk[1] && etxd[15:8] == 8'hFB)) begin
            n_tx = n_tx + 1;
            if (n_tx == inj_tx) tx_cd = 4;
        end
        if (tx_cd == 0) begin
            $display("[%t] rp_mon: injecting bit error into EP TX TLP #%0d", $realtime, n_tx);
            fval = etxd ^ 16'h0100;
            force board.EP.pcie_7x_i.pcie_block_inst.pipe_tx0_data_gt = fval;
            @(posedge pclk); #100;
            release board.EP.pcie_7x_i.pcie_block_inst.pipe_tx0_data_gt;
        end
        if (tx_cd >= 0) tx_cd = tx_cd - 1;
    end
endmodule
