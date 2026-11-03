// SPDX-License-Identifier: CERN-OHL-P
// pci_eerie: Transaction Layer transmit side (user clock domain)
//
// Muxes user TRN TX packets and internally generated TLPs (config / UR
// completions, MSI writes, INTx and PM messages) into the DLL TX queue.
//
// TRN TX note: every beat presented with trn_tsrc_rdy is taken, whatever
// trn_tdst_rdy is (the pcie_7x AXI->TRN bridge does not hold data).  Internal
// TLPs are therefore only inserted between user packets, inside a window
// requested with trn_tcfg_req and granted with trn_tcfg_gnt; trn_tdst_rdy is
// low during that window, as the hard block does.
`timescale 1ns / 1ps
module eerie_tl_tx #(
    parameter [7:0] INTERRUPT_PIN = 8'h1
) (
    input             clk,
    input             rst,
    input             dl_up,

    // TRN TX
    input      [63:0] trn_td,
    input             trn_trem,        // 1: both DWs valid on the last beat
    input             trn_tsof,
    input             trn_teof,
    input             trn_tsrc_rdy,
    input             trn_tsrc_dsc,
    input             trn_terrfwd,
    output reg        trn_tdst_rdy,
    output reg        trn_terr_drop,
    output reg [5:0]  trn_tbuf_av,
    output reg        trn_tcfg_req,
    input             trn_tcfg_gnt,

    // DLL TX queue
    output reg        txq_v,
    output reg [63:0] txq_d,
    output reg        txq_sop,
    output reg        txq_eop,
    output reg        txq_half,
    output reg        txq_abort,
    input      [5:0]  txq_slots,

    // identity / config state
    input      [15:0] req_id,           // {bus, dev, func}
    input      [15:0] command,
    input             msi_enable,
    input      [2:0]  msi_mme,
    input      [63:0] msi_addr,
    input      [15:0] msi_data,

    // internal completion request (from TL RX)
    input             icpl_v,
    input      [2:0]  icpl_status,
    input             icpl_hasd,
    input      [31:0] icpl_data,
    input      [15:0] icpl_reqid,
    input      [7:0]  icpl_tag,
    input      [2:0]  icpl_tc,
    input      [1:0]  icpl_attr,
    input      [6:0]  icpl_laddr,
    input      [11:0] icpl_bcnt,
    output reg        icpl_ack,

    // interrupts (active high here; top level inverts the PCIE_2_1 _n pins)
    input             int_req,
    input             int_assert,
    input      [7:0]  int_di,
    output reg        int_rdy,
    output reg        intx_state,       // legacy INTx currently asserted

    // power management messages
    input             pme_to_ack_req,   // pulse: send PME_TO_Ack
    input             pm_pme_req        // pulse: send PM_PME
);
    // ---------------- user path ----------------
    reg in_pkt;
    reg win;                 // internal insertion window active
    always @(posedge clk) begin
        if (rst) in_pkt <= 1'b0;
        else if (trn_tsrc_rdy) begin
            if (trn_tsof && !trn_teof && !trn_tsrc_dsc) in_pkt <= 1'b1;
            else if (trn_teof || trn_tsrc_dsc) in_pkt <= 1'b0;
        end
    end

    // ---------------- internal request latching ----------------
    reg       pend_pme_ack, pend_pm_pme, pend_int;

    // interrupt decision: MSI write, INTx message, or just a status update
    wire use_msi  = msi_enable;
    wire bm_en    = command[2];
    wire int_dis  = command[10];
    wire int_tlp_needed = use_msi ? bm_en : (!int_dis && (int_assert != intx_state));

    // ---------------- internal TLP builder ----------------
    localparam S_IDLE = 3'd0, S_REQ = 3'd1, S_GAP = 3'd2, S_W0 = 3'd3, S_W1 = 3'd4, S_W2 = 3'd5, S_END = 3'd6;
    reg [2:0]  st;
    reg [2:0]  gap;
    reg [2:0]  kind;         // 0 cpl, 1 msi, 2 intx, 3 pme_ack, 4 pm_pme
    reg [31:0] b0, b1, b2, b3, b4;
    reg [1:0]  nbeats;       // 2 or 3
    reg        lhalf;        // last beat has one DW
    reg        int_assert_q;

    wire [7:0] intx_code = int_assert_q ? (8'h20 + INTERRUPT_PIN - 1'b1) : (8'h24 + INTERRUPT_PIN - 1'b1);
    reg [15:0] msi_vec;
    reg        msi64;
    always @(posedge clk) begin   // config / vector values are quasi-static
        msi_vec <= (msi_mme == 3'd0) ? msi_data :
                   (msi_data & ~((16'd1 << msi_mme) - 1'b1)) | ({8'd0, int_di} & ((16'd1 << msi_mme) - 1'b1));
        msi64   <= (msi_addr[63:32] != 32'd0);
    end

    always @(posedge clk) begin
        txq_v <= 1'b0; txq_abort <= 1'b0; icpl_ack <= 1'b0; int_rdy <= 1'b0; trn_terr_drop <= 1'b0;
        trn_tbuf_av <= txq_slots;
        if (rst) begin
            st <= S_IDLE; win <= 1'b0; trn_tdst_rdy <= 1'b0; trn_tcfg_req <= 1'b0; intx_state <= 1'b0;
            pend_int <= 1'b0; pend_pme_ack <= 1'b0; pend_pm_pme <= 1'b0;
        end else begin
            if (pme_to_ack_req) pend_pme_ack <= 1'b1;
            if (pm_pme_req) pend_pm_pme <= 1'b1;
            trn_tdst_rdy <= dl_up && !win;
            // ---- user beats ----
            if (trn_tsrc_rdy && !(st == S_W0 || st == S_W1 || st == S_W2)) begin
                if (!dl_up) trn_terr_drop <= trn_teof;
                else begin
                    txq_v    <= 1'b1;
                    txq_d    <= trn_tsof ? {trn_td[63:47], trn_td[46] | trn_terrfwd, trn_td[45:0]} : trn_td;
                    txq_sop  <= trn_tsof;
                    txq_eop  <= trn_teof;
                    txq_half <= trn_teof && !trn_trem;
                    txq_abort<= trn_tsrc_dsc;
                end
            end
            // ---- interrupt request handling without a TLP ----
            if (int_req && !int_rdy && st == S_IDLE && !pend_int && dl_up) begin
                if (int_tlp_needed) pend_int <= 1'b1;
                else begin
                    int_rdy <= 1'b1;
                    if (!use_msi) intx_state <= int_assert;
                end
            end
            case (st)
            S_IDLE: if (dl_up && ((icpl_v && !icpl_ack) || pend_pme_ack || pend_pm_pme || pend_int)) begin
                // pick a source and build the header
                if (icpl_v && !icpl_ack) begin
                    kind <= 3'd0;
                    b0 <= {1'b0, icpl_hasd, 1'b0, 5'b01010, 1'b0, icpl_tc, 4'h0, 1'b0, 1'b0, icpl_attr, 2'b00,
                           icpl_hasd ? 10'd1 : 10'd0};
                    b1 <= {req_id, icpl_status, 1'b0, icpl_bcnt};
                    b2 <= {icpl_reqid, icpl_tag, 1'b0, icpl_laddr};
                    b3 <= {icpl_data[7:0], icpl_data[15:8], icpl_data[23:16], icpl_data[31:24]};
                    nbeats <= 2'd2; lhalf <= !icpl_hasd;
                end else if (pend_pme_ack) begin
                    kind <= 3'd3;
                    b0 <= {8'h35, 24'd0}; b1 <= {req_id, 8'h00, 8'h1B}; b2 <= 32'd0; b3 <= 32'd0;
                    nbeats <= 2'd2; lhalf <= 1'b0;
                end else if (pend_pm_pme) begin
                    kind <= 3'd4;
                    b0 <= {8'h30, 24'd0}; b1 <= {req_id, 8'h00, 8'h18}; b2 <= 32'd0; b3 <= 32'd0;
                    nbeats <= 2'd2; lhalf <= 1'b0;
                end else if (use_msi) begin
                    kind <= 3'd1;
                    b0 <= {msi64 ? 8'h60 : 8'h40, 14'd0, 10'd1};
                    b1 <= {req_id, 8'h00, 8'h0F};
                    if (msi64) begin
                        b2 <= msi_addr[63:32]; b3 <= {msi_addr[31:2], 2'b00};
                        b4 <= {msi_vec[7:0], msi_vec[15:8], 16'h0000};
                        nbeats <= 2'd3; lhalf <= 1'b1;
                    end else begin
                        b2 <= {msi_addr[31:2], 2'b00}; b3 <= {msi_vec[7:0], msi_vec[15:8], 16'h0000};
                        nbeats <= 2'd2; lhalf <= 1'b0;
                    end
                end else begin
                    kind <= 3'd2;
                    int_assert_q <= int_assert;
                    b0 <= {8'h34, 24'd0}; b1 <= {req_id, 8'h00, int_assert ? (8'h20 + INTERRUPT_PIN - 1'b1)
                                                                            : (8'h24 + INTERRUPT_PIN - 1'b1)};
                    b2 <= 32'd0; b3 <= 32'd0;
                    nbeats <= 2'd2; lhalf <= 1'b0;
                end
                trn_tcfg_req <= 1'b1;
                st <= S_REQ;
            end
            S_REQ: if (trn_tcfg_gnt) begin
                trn_tcfg_req <= 1'b0; win <= 1'b1; trn_tdst_rdy <= 1'b0; gap <= 3'd0; st <= S_GAP;
            end
            S_GAP: begin
                // let any user beat already in the AXI->TRN pipeline arrive first
                if (gap != 3'd3) gap <= gap + 1'b1;
                if (gap >= 3'd2 && !in_pkt && !trn_tsrc_rdy && txq_slots != 6'd0) st <= S_W0;
            end
            S_W0: begin
                txq_v <= 1'b1; txq_d <= {b0, b1}; txq_sop <= 1'b1; txq_eop <= 1'b0; txq_half <= 1'b0;
                st <= S_W1;
            end
            S_W1: begin
                txq_v <= 1'b1; txq_d <= {b2, b3}; txq_sop <= 1'b0;
                txq_eop <= (nbeats == 2'd2); txq_half <= (nbeats == 2'd2) && lhalf;
                st <= (nbeats == 2'd2) ? S_END : S_W2;
            end
            S_W2: begin
                txq_v <= 1'b1; txq_d <= {b4, 32'd0}; txq_sop <= 1'b0; txq_eop <= 1'b1; txq_half <= lhalf;
                st <= S_END;
            end
            S_END: begin
                win <= 1'b0;
                case (kind)
                3'd0: icpl_ack <= 1'b1;
                3'd1: begin int_rdy <= 1'b1; pend_int <= 1'b0; end
                3'd2: begin int_rdy <= 1'b1; pend_int <= 1'b0; intx_state <= int_assert_q; end
                3'd3: pend_pme_ack <= 1'b0;
                default: pend_pm_pme <= 1'b0;
                endcase
                st <= S_IDLE;
            end
            default: st <= S_IDLE;
            endcase
            if (!dl_up) begin
                trn_tcfg_req <= 1'b0; win <= 1'b0;
                if (st != S_IDLE) st <= S_IDLE;
            end
        end
    end
endmodule
