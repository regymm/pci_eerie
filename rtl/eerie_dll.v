// SPDX-License-Identifier: CERN-OHL-P
// pci_eerie: Data Link Layer (user clock domain)
//
//  * DL control: DL_Inactive -> DL_Init (FC_INIT1/FC_INIT2) -> DL_Active
//  * RX: sequence number checking, Ack/Nak scheduling, DLLP decode
//  * TX: TLP queue + replay buffer in one RAM (the PCIE_2_1 "MIM TX" BRAM),
//        descriptor ring, credit gating, framing (STP/seq/LCRC/END), DLLP
//        generation, replay timer / REPLAY_NUM.
//
// TLP beats are 64 bit, first DW in [63:31], each DW big-endian (TRN order).
`timescale 1ns / 1ps
module eerie_dll #(
    parameter TXB_AW          = 10,     // TX buffer depth 2**TXB_AW beats
    parameter TXB_RLAT        = 2,      // TX buffer read latency
    parameter MAX_TLP_BEATS   = 34,     // largest TLP accepted from the TL (hdr + MPS)
    parameter NDESC_AW        = 5,      // descriptor ring 2**NDESC_AW
    parameter MAX_UNACKED     = 29,     // VC0_TX_LASTPACKET + 1
    parameter REPLAY_TIMEOUT  = 16'd700,// user clocks
    parameter ACK_DELAY       = 8'd4,   // user clocks to coalesce Acks
    parameter UPDFC_PERIOD    = 16'd1500,
    parameter CPL_INFINITE    = 1
) (
    input             clk,
    input             rst,
    input             link_up,          // from LTSSM (synchronized)
    input             link_l0,          // LTSSM in L0 (replay timer runs only then)
    output reg        dl_up,            // DL_Active
    output reg        dl_init,
    output reg        retrain_req,      // pulse: REPLAY_NUM rollover

    // PL RX stream (FWFT async FIFO, user clock side)
    input      [81:0] plrx_d,
    input             plrx_empty,
    output            plrx_rd,

    // PL TX framed packets (packet-mode async FIFO write side)
    output reg        pltx_we,
    output reg [66:0] pltx_wd,          // {half,last,sop,data}
    input             pltx_full,
    input      [7:0]  pltx_free,

    // TL RX stream
    output reg        tlrx_v,           // data beat (two DWs, or one if tlrx_half)
    output reg [63:0] tlrx_d,
    output reg        tlrx_sop,
    output reg        tlrx_half,        // only [63:32] valid (final DW)
    output reg        tlrx_end,         // end of TLP (no data unless tlrx_v)
    output reg        tlrx_ok,          // with tlrx_end: commit (1) or discard (0)

    // TL TX queue write port
    input             txq_v,
    input      [63:0] txq_d,
    input             txq_sop,
    input             txq_eop,
    input             txq_half,
    input             txq_abort,
    output reg [5:0]  txq_slots,        // free max-size TLP slots (trn_tbuf_av)

    // flow control: values to advertise (CREDITS_ALLOCATED), from TL
    input      [7:0]  fc_ph,  input [11:0] fc_pd,
    input      [7:0]  fc_nph, input [11:0] fc_npd,
    input      [7:0]  fc_cplh,input [11:0] fc_cpld,
    input      [2:0]  fc_upd_req,       // pulse per type: credits were returned
    // link partner credits (for status / TRNFC* outputs)
    output reg [7:0]  lim_ph, output reg [11:0] lim_pd,
    output reg [7:0]  lim_nph, output reg [11:0] lim_npd,
    output reg [7:0]  lim_cplh, output reg [11:0] lim_cpld,
    output reg [7:0]  cons_ph, output reg [11:0] cons_pd,
    output reg [7:0]  cons_nph, output reg [11:0] cons_npd,
    output reg [7:0]  cons_cplh, output reg [11:0] cons_cpld,
    output reg [5:0]  inf_mask,         // {cpld,cplh,npd,nph,pd,ph} infinite

    // status
    output reg        err_bad_tlp,
    output reg        err_bad_dllp,
    output reg        err_replay_rollover,
    output reg        err_replay_timeout,
    output reg        err_dl_protocol,
    output reg [31:0] dllp_rx_data,     // last received good DLLP
    output reg        dllp_rx_v,

    // TX buffer RAM (MIM TX)
    output reg            txb_we,
    output reg [12:0]     txb_waddr,
    output reg [68:0]     txb_wdata,
    output reg            txb_re,
    output reg [12:0]     txb_raddr,
    input      [68:0]     txb_rdata
);
    `include "eerie_funcs.vh"

    localparam K_STP = 8'hFB, K_SDP = 8'h5C, K_END = 8'hFD;
    localparam NDESC = 1 << NDESC_AW;
    localparam TXB_DEPTH = 1 << TXB_AW;

    // =====================================================================
    // DL control state
    // =====================================================================
    localparam DL_INACTIVE = 2'd0, DL_FC1 = 2'd1, DL_FC2 = 2'd2, DL_ACTIVE = 2'd3;
    reg [1:0] dls;
    reg [2:0] fc1_got;          // P, NP, Cpl InitFC received
    reg       fi2;
    reg       link_rst;         // flush state while link is down (registered: high fanout)
    always @(posedge clk) link_rst <= rst || !link_up;

    // =====================================================================
    // RX side
    // =====================================================================
    wire [63:0] e_data = plrx_d[63:0];
    wire        e_sop  = plrx_d[64];
    wire [11:0] e_seq  = plrx_d[76:65];
    wire        e_eop  = plrx_d[77];
    wire        e_dllp = plrx_d[78];
    wire        e_bad  = plrx_d[79];
    wire        e_null = plrx_d[80];
    wire        e_half = plrx_d[81];
    assign plrx_rd = !plrx_empty;
    wire        e_v = !plrx_empty;

    reg [11:0] next_rcv_seq;
    reg        nak_scheduled;
    reg        ack_req, nak_req;      // to TX scheduler
    reg [7:0]  ack_timer;
    reg        rx_accept;             // current TLP is being forwarded
    reg        rx_in_tlp;
    reg        rx_dup;                // current TLP is a duplicate

    // events to TX side
    reg        ev_acknak;
    reg        ev_nak;
    reg [11:0] ev_seq;
    reg        ev_fc;                 // InitFC/UpdateFC received
    reg [3:0]  ev_fc_type;            // dllp[31:28]
    reg [7:0]  ev_fc_hdr;
    reg [11:0] ev_fc_data;

    wire [11:0] seq_diff = next_rcv_seq - e_seq;   // >0 and <=2048 : duplicate

    always @(posedge clk) begin
        tlrx_v <= 1'b0; tlrx_end <= 1'b0; tlrx_ok <= 1'b0; tlrx_half <= 1'b0;
        ev_acknak <= 1'b0; ev_fc <= 1'b0;
        err_bad_tlp <= 1'b0; err_bad_dllp <= 1'b0; dllp_rx_v <= 1'b0;
        if (link_rst) begin
            next_rcv_seq <= 12'd0; nak_scheduled <= 1'b0; rx_accept <= 1'b0; rx_in_tlp <= 1'b0;
            rx_dup <= 1'b0;
        end else if (e_v) begin
            if (e_dllp) begin
                if (e_bad) err_bad_dllp <= 1'b1;
                else begin
                    dllp_rx_data <= e_data[63:32]; dllp_rx_v <= 1'b1;
                    if (e_data[63:56] == 8'h00) begin
                        ev_acknak <= 1'b1; ev_nak <= 1'b0; ev_seq <= e_data[43:32];
                    end else if (e_data[63:56] == 8'h10) begin
                        ev_acknak <= 1'b1; ev_nak <= 1'b1; ev_seq <= e_data[43:32];
                    end else if (e_data[59:56] == 4'h0 &&
                                 (e_data[63:60] == 4'h4 || e_data[63:60] == 4'h5 || e_data[63:60] == 4'h6 ||
                                  e_data[63:60] == 4'hC || e_data[63:60] == 4'hD || e_data[63:60] == 4'hE ||
                                  e_data[63:60] == 4'h8 || e_data[63:60] == 4'h9 || e_data[63:60] == 4'hA)) begin
                        ev_fc <= 1'b1; ev_fc_type <= e_data[63:60];
                        ev_fc_hdr <= e_data[53:46]; ev_fc_data <= e_data[43:32];
                    end
                end
            end else if (!e_eop) begin
                // TLP data beat
                if (e_sop) begin
                    rx_in_tlp <= 1'b1;
                    if (e_seq == next_rcv_seq && dls != DL_INACTIVE) begin
                        rx_accept <= 1'b1; rx_dup <= 1'b0;
                        tlrx_v <= 1'b1; tlrx_d <= e_data; tlrx_sop <= 1'b1;
                    end else begin
                        rx_accept <= 1'b0;
                        rx_dup <= (seq_diff != 12'd0) && (seq_diff <= 12'd2048);
                    end
                end else if (rx_accept) begin
                    tlrx_v <= 1'b1; tlrx_d <= e_data; tlrx_sop <= 1'b0;
                end
            end else begin
                // end marker
                rx_in_tlp <= 1'b0;
                if (rx_accept && e_half && !e_bad && !e_null) begin
                    tlrx_v <= 1'b1; tlrx_d <= e_data; tlrx_sop <= e_sop; tlrx_half <= 1'b1;
                end
                if (rx_accept) begin
                    tlrx_end <= 1'b1;
                    tlrx_ok  <= rx_accept && !e_bad && !e_null;
                end
                if (e_null) begin
                    ;   // nullified TLP: silently discarded
                end else if (e_bad) begin
                    err_bad_tlp <= 1'b1;
                    if (!nak_scheduled) begin nak_scheduled <= 1'b1; end
                end else if (rx_accept) begin
                    next_rcv_seq  <= next_rcv_seq + 1'b1;
                    nak_scheduled <= 1'b0;
                end else if (rx_dup) begin
                    ;   // duplicate: Ack only (scheduled below)
                end else if (dls != DL_INACTIVE) begin
                    // sequence number ahead of expected: lost TLP
                    if (!nak_scheduled) nak_scheduled <= 1'b1;
                end
                rx_accept <= 1'b0;
            end
        end
    end

    // Ack / Nak request generation
    reg nak_scheduled_d;
    reg ack_sent, nak_sent;           // from TX scheduler
    always @(posedge clk) begin
        if (link_rst) begin
            ack_req <= 1'b0; nak_req <= 1'b0; ack_timer <= 8'd0; nak_scheduled_d <= 1'b0;
        end else begin
            nak_scheduled_d <= nak_scheduled;
            if (nak_scheduled && !nak_scheduled_d) nak_req <= 1'b1;
            else if (nak_sent) nak_req <= 1'b0;
            // a good TLP or a duplicate -> Ack
            if (e_v && e_eop && !e_dllp && !e_bad && !e_null && (rx_accept || rx_dup)) begin
                ack_req <= 1'b1;
                if (!ack_req) ack_timer <= ACK_DELAY;
            end else if (ack_sent) ack_req <= 1'b0;
            else if (ack_timer != 8'd0) ack_timer <= ack_timer - 1'b1;
        end
    end

    // =====================================================================
    // DL control / FC init / credit limits
    // =====================================================================
    always @(posedge clk) begin
        if (link_rst) begin
            dls <= DL_INACTIVE; dl_up <= 1'b0; dl_init <= 1'b0; fc1_got <= 3'b000; fi2 <= 1'b0;
            lim_ph <= 0; lim_pd <= 0; lim_nph <= 0; lim_npd <= 0; lim_cplh <= 0; lim_cpld <= 0;
            inf_mask <= 6'd0;
        end else begin
            case (dls)
            DL_INACTIVE: begin dls <= DL_FC1; dl_init <= 1'b1; end
            DL_FC1: if (fc1_got == 3'b111) dls <= DL_FC2;
            DL_FC2: if (fi2) begin dls <= DL_ACTIVE; dl_up <= 1'b1; dl_init <= 1'b0; end
            default: ;
            endcase
            if (ev_fc) begin
                if (ev_fc_type[3:2] == 2'b01 || ev_fc_type[3:2] == 2'b11) begin
                    // InitFC1 / InitFC2: record limits during init
                    if (dls == DL_FC1 || (dls == DL_FC2 && ev_fc_type[3:2] == 2'b01)) begin
                        case (ev_fc_type[1:0])
                        2'b00: if (!fc1_got[0]) begin lim_ph <= ev_fc_hdr; lim_pd <= ev_fc_data;
                                   inf_mask[0] <= ev_fc_hdr == 0; inf_mask[1] <= ev_fc_data == 0; fc1_got[0] <= 1'b1; end
                        2'b01: if (!fc1_got[1]) begin lim_nph <= ev_fc_hdr; lim_npd <= ev_fc_data;
                                   inf_mask[2] <= ev_fc_hdr == 0; inf_mask[3] <= ev_fc_data == 0; fc1_got[1] <= 1'b1; end
                        default: if (!fc1_got[2]) begin lim_cplh <= ev_fc_hdr; lim_cpld <= ev_fc_data;
                                   inf_mask[4] <= ev_fc_hdr == 0; inf_mask[5] <= ev_fc_data == 0; fc1_got[2] <= 1'b1; end
                        endcase
                    end
                    if (dls == DL_FC2 && ev_fc_type[3:2] == 2'b11) fi2 <= 1'b1;
                end else begin
                    // UpdateFC
                    if (dls == DL_FC2) fi2 <= 1'b1;
                    if (dls == DL_ACTIVE || dls == DL_FC2) begin
                        case (ev_fc_type[1:0])
                        2'b00: begin if (!inf_mask[0]) lim_ph <= ev_fc_hdr;  if (!inf_mask[1]) lim_pd <= ev_fc_data;  end
                        2'b01: begin if (!inf_mask[2]) lim_nph <= ev_fc_hdr; if (!inf_mask[3]) lim_npd <= ev_fc_data; end
                        default: begin if (!inf_mask[4]) lim_cplh <= ev_fc_hdr; if (!inf_mask[5]) lim_cpld <= ev_fc_data; end
                        endcase
                    end
                end
            end
            if (dls == DL_FC2 && tlrx_end && tlrx_ok) fi2 <= 1'b1;
        end
    end

    // =====================================================================
    // TX buffer: TL write side + descriptor ring
    // =====================================================================
    // descriptor: {data_cred[9:0], ctype[1:0], nbeats[6:0]? , half, start[TXB_AW-1:0]}
    localparam DW_ = TXB_AW + 22;
    localparam SLOT_SH = (MAX_TLP_BEATS <= 16) ? 4 : (MAX_TLP_BEATS <= 32) ? 5 : (MAX_TLP_BEATS <= 64) ? 6 :
                         (MAX_TLP_BEATS <= 128) ? 7 : 8;
    reg [DW_-1:0] desc [0:NDESC-1];
    reg [NDESC_AW:0] d_wr, d_send, d_ack, s_ptr;
    reg [TXB_AW:0]   w_addr, w_start;          // write pointer (beats), with wrap bit
    reg [7:0]        w_nbeats;
    reg [1:0]        w_ctype;
    reg [9:0]        w_dcred;
    reg              w_in;

    function [9:0] f_dcred;   // data credits of a TLP from DW0 fields
        input       has_data;
        input [9:0] len;
        begin
            if (!has_data) f_dcred = 10'd0;
            else if (len == 10'd0) f_dcred = 10'd256;
            else f_dcred = ({1'b0, len} + 11'd3) >> 2;
        end
    endfunction

    function [1:0] f_ctype;   // 0: P, 1: NP, 2: Cpl
        input [7:0] fmt_type;
        begin
            if (fmt_type[4:1] == 4'b0101) f_ctype = 2'd2;                       // Cpl/CplD/CplLk
            else if (fmt_type[4:3] == 2'b10) f_ctype = 2'd0;                    // Msg/MsgD
            else if (fmt_type[6] && fmt_type[4:0] == 5'b00000) f_ctype = 2'd0; // MWr
            else f_ctype = 2'd1;                                                // everything else NP
        end
    endfunction

    reg  [TXB_AW:0] desc_ack_start;
    wire [TXB_AW:0] free_ptr = (d_ack == d_wr) ? w_start : desc_ack_start;
    wire [TXB_AW:0] used_beats = w_addr - free_ptr;
    wire [TXB_AW:0] free_beats = TXB_DEPTH - used_beats;
    wire [NDESC_AW:0] used_desc = d_wr - d_ack;
    always @(*) desc_ack_start = desc[d_ack[NDESC_AW-1:0]][TXB_AW:0];

    integer sl;
    reg [TXB_AW:0]   free_beats_r;
    reg [NDESC_AW:0] used_desc_r;
    always @(posedge clk) begin
        // free slots for the throttle logic (whole max-size TLPs, rounded up to 2**SLOT_SH beats);
        // two register stages, the value is conservative because TLPs are written before it updates
        free_beats_r <= free_beats;
        used_desc_r  <= used_desc;
        sl = free_beats_r >> SLOT_SH;
        if (NDESC - 1 - used_desc_r < sl) sl = NDESC - 1 - used_desc_r;
        if (MAX_UNACKED - used_desc_r < sl) sl = MAX_UNACKED - used_desc_r;
        if (sl < 0) sl = 0;
        if (sl > 63) sl = 63;
        txq_slots <= (link_rst || !dl_up) ? 6'd0 : (sl[5:0] > 6'd2 ? sl[5:0] - 6'd2 : 6'd0);
    end

    always @(posedge clk) begin
        txb_we <= 1'b0;
        if (link_rst) begin
            d_wr <= 0; w_addr <= 0; w_start <= 0; w_in <= 1'b0;
        end else begin
            if (txq_v && !txq_abort) begin
                txb_we    <= 1'b1;
                txb_waddr <= w_addr[TXB_AW-1:0];
                txb_wdata <= {5'd0, txq_d};
                w_addr    <= w_addr + 1'b1;
                if (txq_sop) begin
                    w_start  <= w_addr; w_in <= 1'b1; w_nbeats <= 8'd1;
                    w_ctype  <= f_ctype(txq_d[62:56]);
                    w_dcred  <= f_dcred(txq_d[62], txq_d[41:32]);
                end else w_nbeats <= w_nbeats + 1'b1;
                if (txq_eop) begin
                    w_in <= 1'b0;
                    desc[d_wr[NDESC_AW-1:0]] <= {(txq_sop ? f_dcred(txq_d[62], txq_d[41:32]) : w_dcred),
                                                 (txq_sop ? f_ctype(txq_d[62:56]) : w_ctype),
                                                 (txq_sop ? 8'd1 : w_nbeats + 1'b1), txq_half,
                                                 (txq_sop ? w_addr : w_start)};
                    d_wr <= d_wr + 1'b1;
                    w_start <= w_addr + 1'b1;
                end
            end else if (txq_abort) begin
                w_addr <= w_start; w_in <= 1'b0;
            end
        end
    end

    // =====================================================================
    // TX side: Ack/Nak processing, replay, credit gating, scheduler, framer
    // =====================================================================
    reg [11:0] next_tx_seq;      // NEXT_TRANSMIT_SEQ
    reg [11:0] ackd_seq;         // ACKD_SEQ
    reg [11:0] send_seq;         // seq of TLP at s_ptr
    reg [1:0]  replay_num;
    reg [15:0] replay_timer;
    reg        replay_timer_on;
    reg        replay_req;
    reg [15:0] updfc_timer;
    reg [2:0]  updfc_pend;
    reg [1:0]  initfc_rr;

    wire [DW_-1:0] dsend = desc[s_ptr[NDESC_AW-1:0]];
    wire [TXB_AW:0] ds_start = dsend[TXB_AW:0];
    wire        ds_half  = dsend[TXB_AW+1];
    wire [7:0]  ds_nb    = dsend[TXB_AW+9:TXB_AW+2];
    wire [1:0]  ds_ctype = dsend[TXB_AW+11:TXB_AW+10];
    wire [9:0]  ds_dcred = dsend[TXB_AW+21:TXB_AW+12];

    // two-stage prefetch of the descriptor at s_ptr and its credit check; the results are
    // only used when the pointer tag still matches s_ptr (credit/space values may be one or
    // two clocks old, which is conservative: they only ever free up)
    reg [NDESC_AW:0] pf_ptr, cr_ptr;
    reg [TXB_AW:0]   pf_start;
    reg              pf_half;
    reg [7:0]        pf_nb;
    reg [1:0]        pf_ctype;
    reg [9:0]        pf_dcred;
    reg              cr_ok, cr_new, cr_room, cr_has;
    reg              cred_ok;
    always @(*) begin
        case (pf_ctype)
        2'd0: cred_ok = (inf_mask[0] || ((lim_ph  - (cons_ph  + 8'd1))  <= 8'd128)) &&
                        (inf_mask[1] || ((lim_pd  - (cons_pd  + {2'b0, pf_dcred})) <= 12'd2048));
        2'd1: cred_ok = (inf_mask[2] || ((lim_nph - (cons_nph + 8'd1))  <= 8'd128)) &&
                        (inf_mask[3] || ((lim_npd - (cons_npd + {2'b0, pf_dcred})) <= 12'd2048));
        default: cred_ok = (inf_mask[4] || ((lim_cplh - (cons_cplh + 8'd1)) <= 8'd128)) &&
                        (inf_mask[5] || ((lim_cpld - (cons_cpld + {2'b0, pf_dcred})) <= 12'd2048));
        endcase
    end
    always @(posedge clk) begin
        pf_ptr <= s_ptr; pf_start <= ds_start; pf_half <= ds_half; pf_nb <= ds_nb;
        pf_ctype <= ds_ctype; pf_dcred <= ds_dcred;
        cr_ptr  <= pf_ptr;
        cr_ok   <= cred_ok;
        cr_new  <= (pf_ptr == d_send);
        cr_room <= ((d_send - d_ack) < MAX_UNACKED);
        cr_has  <= (pf_ptr != d_wr);
    end
    wire pf_valid = (cr_ptr == s_ptr) && (pf_ptr == s_ptr);

    // ---- Ack/Nak DLLP reception -> purge / replay ----
    // Ack/Nak processing in two steps (Acks are cumulative: a newer one supersedes a pending
    // one; a Nak is sticky until applied):
    //   acc_*  latest received Ack/Nak
    //   a_*    range check computed against ACKD_SEQ / NEXT_TRANSMIT_SEQ, applied next clock
    reg         acc_v, acc_nak;
    reg  [11:0] acc_seq;
    reg         a_busy, a_nak;
    reg  [11:0] a_seq, a_ahead, a_outst;
    reg  [11:0] purge_n;
    reg         purge_v;

    // scheduler / framer state
    localparam T_IDLE = 3'd0, T_DLLP = 3'd1, T_TLP = 3'd2, T_TAIL = 3'd3;
    reg [2:0]  ts;
    reg [31:0] dllp_word;
    reg [7:0]  f_left;       // beats still to read from the buffer
    reg [7:0]  f_out_left;   // data beats still to come out of the RAM pipeline
    reg [TXB_AW:0] f_raddr;
    reg        f_half, f_first;
    reg [23:0] f_carry;
    reg [31:0] f_crc;
    reg [TXB_RLAT+1:0] rd_pipe; // valid bits of in-flight RAM reads (+1: registered read data)
    reg [1:0]  fr_ctype;
    reg [9:0]  fr_dcred;
    reg        f_new;           // first transmission (consumes credits)

    // in-flight reads must always fit in the FIFO: require room for them + a margin
    reg        fifo_room;
    reg        fifo_dllp_ok;
    always @(posedge clk) begin
        fifo_room    <= (pltx_free > (TXB_RLAT + 6)) && !pltx_full;
        fifo_dllp_ok <= (pltx_free > 8'd4) && !pltx_full;
    end

    // RAM read data path
    reg  [63:0] rd_d;
    always @(posedge clk) rd_d <= txb_rdata[63:0];
    wire [31:0] crc_hi   = f_crc32_dw(f_crc, rd_d[63:32]);
    wire [31:0] crc_full = f_crc32_dw(crc_hi, rd_d[31:0]);
    wire [31:0] lcrc_h   = f_lcrc_field(crc_hi);
    wire [31:0] lcrc_f   = f_lcrc_field(f_crc);
    wire rd_valid = rd_pipe[TXB_RLAT+1];
    wire rd_last  = (f_out_left == 8'd1);

    reg ack_sent_r, nak_sent_r;
    always @(*) begin ack_sent = ack_sent_r; nak_sent = nak_sent_r; end

    // DLLP word builders
    function [31:0] mk_fc;
        input [3:0] t; input [7:0] h; input [11:0] d;
        mk_fc = {t, 4'h0, 2'b00, h, 2'b00, d};
    endfunction

    always @(posedge clk) begin
        pltx_we <= 1'b0; txb_re <= 1'b0; retrain_req <= 1'b0;
        ack_sent_r <= 1'b0; nak_sent_r <= 1'b0;
        err_replay_rollover <= 1'b0; err_replay_timeout <= 1'b0; err_dl_protocol <= 1'b0;
        rd_pipe <= {rd_pipe[TXB_RLAT:0], 1'b0};
        if (link_rst) begin
            next_tx_seq <= 12'd0; ackd_seq <= 12'hFFF; send_seq <= 12'd0;
            d_send <= 0; d_ack <= 0; s_ptr <= 0;
            replay_num <= 2'd0; replay_timer <= 16'd0; replay_timer_on <= 1'b0; replay_req <= 1'b0;
            updfc_timer <= 16'd0; updfc_pend <= 3'b000; initfc_rr <= 2'd0;
            cons_ph <= 0; cons_pd <= 0; cons_nph <= 0; cons_npd <= 0; cons_cplh <= 0; cons_cpld <= 0;
            ts <= T_IDLE; rd_pipe <= 0; purge_v <= 1'b0;
            acc_v <= 1'b0; acc_nak <= 1'b0; a_busy <= 1'b0;
        end else begin
            // ---------------- Ack/Nak handling ----------------
            if (!a_busy && acc_v) begin
                a_busy <= 1'b1; a_seq <= acc_seq; a_nak <= acc_nak;
                a_ahead <= acc_seq - ackd_seq;                 // TLPs newly acknowledged
                a_outst <= next_tx_seq - 1'b1 - ackd_seq;       // TLPs outstanding
            end
            if (ev_acknak) begin
                acc_v <= 1'b1; acc_seq <= ev_seq;
                acc_nak <= ((!a_busy && acc_v) ? 1'b0 : acc_nak) | ev_nak;
            end else if (!a_busy && acc_v) begin
                acc_v <= 1'b0; acc_nak <= 1'b0;
            end
            if (a_busy) begin
                a_busy <= 1'b0;
                if (a_ahead <= a_outst) begin
                    // valid: purge a_ahead TLPs
                    if (a_ahead != 12'd0) begin
                        purge_v <= 1'b1; purge_n <= a_ahead;
                        replay_num <= 2'd0;
                        replay_timer <= 16'd0;
                        replay_timer_on <= (a_ahead != a_outst);
                    end
                    ackd_seq <= a_seq;
                    if (a_nak) replay_req <= 1'b1;
                end else err_dl_protocol <= 1'b1;
            end
            if (purge_v) begin
                purge_v <= 1'b0;
                d_ack <= d_ack + purge_n[NDESC_AW:0];
                // if the replay pointer fell behind the new ack pointer, skip ahead
                if (((s_ptr - d_ack) & {(NDESC_AW+1){1'b1}}) < purge_n[NDESC_AW:0] && ts != T_TLP && ts != T_TAIL) begin
                    s_ptr <= d_ack + purge_n[NDESC_AW:0];
                    send_seq <= ackd_seq + 1'b1;
                end
            end
            // ---------------- replay timer ----------------
            if (replay_timer_on) begin
                if (replay_timer >= REPLAY_TIMEOUT) begin
                    replay_timer <= 16'd0;
                    replay_req <= 1'b1;
                    err_replay_timeout <= 1'b1;
                    replay_num <= replay_num + 1'b1;
                    if (replay_num == 2'd3) begin retrain_req <= 1'b1; err_replay_rollover <= 1'b1; end
                end else if (link_l0)
                    replay_timer <= replay_timer + 1'b1;
            end
            // ---------------- UpdateFC timer ----------------
            if (fc_upd_req[0]) updfc_pend[0] <= 1'b1;
            if (fc_upd_req[1]) updfc_pend[1] <= 1'b1;
            if (fc_upd_req[2] && !CPL_INFINITE) updfc_pend[2] <= 1'b1;
            if (dls == DL_ACTIVE) begin
                if (updfc_timer >= UPDFC_PERIOD) begin
                    updfc_timer <= 16'd0;
                    updfc_pend <= CPL_INFINITE ? 3'b011 : 3'b111;
                end else updfc_timer <= updfc_timer + 1'b1;
            end

            // ---------------- scheduler ----------------
            case (ts)
            T_IDLE: begin
                if (((s_ptr - d_ack) & {(NDESC_AW+1){1'b1}}) > ((d_send - d_ack) & {(NDESC_AW+1){1'b1}})) begin
                    // replay pointer fell behind the acknowledged TLPs: resynchronize
                    s_ptr <= d_ack; send_seq <= ackd_seq + 1'b1;
                end else if (dls == DL_FC1 || dls == DL_FC2) begin
                    // keep the InitFC backlog small: the PHY only sends packets in L0
                    if (fifo_dllp_ok && pltx_free >= 8'd124) begin
                        ts <= T_DLLP;
                        initfc_rr <= (initfc_rr == 2'd2) ? 2'd0 : initfc_rr + 1'b1;
                        case (initfc_rr)
                        2'd0: dllp_word <= mk_fc(dls == DL_FC1 ? 4'h4 : 4'hC, fc_ph, fc_pd);
                        2'd1: dllp_word <= mk_fc(dls == DL_FC1 ? 4'h5 : 4'hD, fc_nph, fc_npd);
                        default: dllp_word <= mk_fc(dls == DL_FC1 ? 4'h6 : 4'hE,
                                                    CPL_INFINITE ? 8'd0 : fc_cplh, CPL_INFINITE ? 12'd0 : fc_cpld);
                        endcase
                    end
                end else if (dls == DL_ACTIVE && fifo_dllp_ok) begin
                    if (nak_req) begin
                        ts <= T_DLLP; nak_sent_r <= 1'b1; ack_sent_r <= 1'b1;
                        dllp_word <= {8'h10, 12'd0, next_rcv_seq - 1'b1};
                    end else if (ack_req && ack_timer == 8'd0) begin
                        ts <= T_DLLP; ack_sent_r <= 1'b1;
                        dllp_word <= {8'h00, 12'd0, next_rcv_seq - 1'b1};
                    end else if (updfc_pend[0]) begin
                        ts <= T_DLLP; updfc_pend[0] <= 1'b0; dllp_word <= mk_fc(4'h8, fc_ph, fc_pd);
                    end else if (updfc_pend[1]) begin
                        ts <= T_DLLP; updfc_pend[1] <= 1'b0; dllp_word <= mk_fc(4'h9, fc_nph, fc_npd);
                    end else if (updfc_pend[2]) begin
                        ts <= T_DLLP; updfc_pend[2] <= 1'b0; dllp_word <= mk_fc(4'hA, fc_cplh, fc_cpld);
                    end else if (replay_req && !purge_v && !a_busy) begin
                        replay_req <= 1'b0;
                        s_ptr <= d_ack; send_seq <= ackd_seq + 1'b1;
                        replay_timer <= 16'd0; replay_timer_on <= (d_ack != d_send);
                    end else if (pf_valid && cr_has && !purge_v && !a_busy && fifo_room &&
                                 (!cr_new || (cr_ok && cr_room))) begin
                        // start a TLP (replay if s_ptr != d_send, else new)
                        ts <= T_TLP;
                        f_new   <= cr_new;
                        f_raddr <= pf_start; f_left <= pf_nb; f_out_left <= pf_nb; f_half <= pf_half;
                        f_first <= 1'b1;
                        fr_ctype <= pf_ctype; fr_dcred <= pf_dcred;
                        f_carry <= {K_STP, 4'h0, send_seq[11:8], send_seq[7:0]};
                        f_crc   <= f_crc32_byte(f_crc32_byte(32'hFFFFFFFF, {4'h0, send_seq[11:8]}), send_seq[7:0]);
                    end
                end
            end
            T_DLLP: begin
                pltx_we <= 1'b1;
                pltx_wd <= {1'b0, 1'b1, 1'b1, K_SDP, dllp_word, f_dllp_crc(dllp_word), K_END};
                ts <= T_IDLE;
            end
            T_TLP: begin
                // issue RAM reads (throttled by FIFO space)
                if (f_left != 8'd0 && fifo_room) begin
                    txb_re <= 1'b1; txb_raddr <= f_raddr[TXB_AW-1:0];
                    f_raddr <= f_raddr + 1'b1; f_left <= f_left - 1'b1;
                    rd_pipe[0] <= 1'b1;
                end
                if (rd_valid) begin
                    f_out_left <= f_out_left - 1'b1;
                    f_first <= 1'b0;
                    pltx_we <= 1'b1;
                    if (rd_last && f_half) begin
                        // {carry3, DW, L0} then tail {L1,L2,L3,END}
                        f_crc   <= crc_hi;
                        pltx_wd <= {1'b0, 1'b0, f_first, f_carry, rd_d[63:32], lcrc_h[31:24]};
                        f_carry <= lcrc_h[23:0];
                        ts <= T_TAIL;
                    end else begin
                        f_crc   <= crc_full;
                        pltx_wd <= {1'b0, 1'b0, f_first, f_carry, rd_d[63:24]};
                        f_carry <= rd_d[23:0];
                        if (rd_last) ts <= T_TAIL;
                    end
                end
            end
            T_TAIL: begin
                pltx_we <= 1'b1;
                if (f_half) // f_carry = {L1,L2,L3}
                    pltx_wd <= {1'b1, 1'b1, 1'b0, f_carry, K_END, 32'd0};
                else
                    pltx_wd <= {1'b0, 1'b1, 1'b0, f_carry, lcrc_f, K_END};
                ts <= T_IDLE;
                // TLP done
                s_ptr <= s_ptr + 1'b1; send_seq <= send_seq + 1'b1;
                if (f_new) begin
                    d_send <= d_send + 1'b1; next_tx_seq <= next_tx_seq + 1'b1;
                    case (fr_ctype)
                    2'd0: begin cons_ph <= cons_ph + 1'b1; cons_pd <= cons_pd + fr_dcred; end
                    2'd1: begin cons_nph <= cons_nph + 1'b1; cons_npd <= cons_npd + fr_dcred; end
                    default: begin cons_cplh <= cons_cplh + 1'b1; cons_cpld <= cons_cpld + fr_dcred; end
                    endcase
                end
                if (!replay_timer_on) begin replay_timer_on <= 1'b1; replay_timer <= 16'd0; end
            end
            default: ts <= T_IDLE;
            endcase
        end
    end
endmodule
