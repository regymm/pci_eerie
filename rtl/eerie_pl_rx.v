// SPDX-License-Identifier: CERN-OHL-P
// pci_eerie: physical layer receive path (one lane, 2 symbols per PIPE clock)
//
//   PIPE RX -> classify -> descrambler -> symbol aligner -> ordered-set / packet parser
//
// * Descrambling happens in arrival order (before alignment) so the LFSR stays
//   in step with the transmitter regardless of how symbols land on the 16-bit
//   PIPE word.
// * The aligner forces every start symbol (COM/STP/SDP) into the first slot
//   of an aligned pair.  When a start symbol arrives in the wrong slot, the
//   symbol immediately preceding it is dropped; that symbol is always a filler
//   (SKP or logical idle) because packets and ordered sets have even length.
// * TLPs: LCRC is checked here (residue check); the stream handed to the DLL
//   contains the TLP DWs only (LCRC stripped) packed in 64-bit beats, followed
//   by a separate end marker carrying the status.
// * DLLPs: CRC16 checked here, delivered as a single entry.
// * Everything is pipelined for 250 MHz (5 GT/s); end-of-packet / end-of-TS
//   checks are evaluated one clock after the closing symbol.
`timescale 1ns / 1ps
module eerie_pl_rx (
    input             clk,
    input             rst,

    input      [15:0] pipe_rxdata,
    input      [1:0]  pipe_rxdatak,
    input             pipe_rxvalid,
    input      [2:0]  pipe_rxstatus,
    input             pipe_rxelecidle,
    input             descramble_en,

    // ordered-set events to the LTSSM
    output reg        os_ts_valid,       // pulse: a TS1/TS2 was received
    output reg        os_ts2,            // 1 = TS2, 0 = TS1
    output reg        os_ts_inv,         // TS identifier received inverted (polarity)
    output reg [7:0]  os_link,
    output reg        os_link_pad,
    output reg [7:0]  os_lane,
    output reg        os_lane_pad,
    output reg [7:0]  os_nfts,
    output reg [7:0]  os_rate,
    output reg [7:0]  os_ctrl,
    output reg        os_eios,           // pulse: EIOS received
    output reg        os_skp,            // pulse: SKP OS received
    output reg        os_idle2,          // both symbols of this aligned pair are idle data
    output reg        os_pkt_start,      // STP/SDP received
    output reg        rx_err,            // pulse: receiver error (decode/framing)

    // packet stream to the DLL (pclk domain, into async FIFO)
    output reg        pkt_we,
    output reg [81:0] pkt_wd
);
    `include "eerie_funcs.vh"

    localparam K_COM = 8'hBC, K_STP = 8'hFB, K_SDP = 8'h5C, K_END = 8'hFD, K_EDB = 8'hFE,
               K_PAD = 8'hF7, K_SKP = 8'h1C, K_FTS = 8'h3C, K_IDL = 8'h7C, K_EIE = 8'hFC;

    // ------------------------------------------------------------------
    // stage 0: input register + symbol classification
    // ------------------------------------------------------------------
    reg [15:0] r_d; reg [1:0] r_k; reg r_v; reg r_err;
    reg [1:0]  r_com, r_skp, r_rawstart;   // rawstart: COM followed by this starts a TS/EIEOS
    reg [7:0]  r_kc0, r_kc1;               // K class {STP,SDP,IDL,FTS,EIE,PAD,END,EDB}
    function [7:0] kclass; input k; input [7:0] d;
        kclass = {k && d == K_STP, k && d == K_SDP, k && d == K_IDL, k && d == K_FTS,
                  k && d == K_EIE, k && d == K_PAD, k && d == K_END, k && d == K_EDB};
    endfunction
    always @(posedge clk) begin
        r_d   <= pipe_rxdata;
        r_k   <= pipe_rxdatak;
        r_v   <= pipe_rxvalid && !pipe_rxelecidle;
        r_err <= pipe_rxvalid && (pipe_rxstatus == 3'b100 || pipe_rxstatus == 3'b111 ||
                                  pipe_rxstatus == 3'b101 || pipe_rxstatus == 3'b110);
        r_com <= {pipe_rxdatak[1] && pipe_rxdata[15:8] == K_COM, pipe_rxdatak[0] && pipe_rxdata[7:0] == K_COM};
        r_skp <= {pipe_rxdatak[1] && pipe_rxdata[15:8] == K_SKP, pipe_rxdatak[0] && pipe_rxdata[7:0] == K_SKP};
        r_rawstart <= {!pipe_rxdatak[1] || pipe_rxdata[15:8] == K_PAD || pipe_rxdata[15:8] == K_EIE,
                       !pipe_rxdatak[0] || pipe_rxdata[7:0] == K_PAD || pipe_rxdata[7:0] == K_EIE};
        r_kc0 <= kclass(pipe_rxdatak[0], pipe_rxdata[7:0]);
        r_kc1 <= kclass(pipe_rxdatak[1], pipe_rxdata[15:8]);
    end

    // ------------------------------------------------------------------
    // stage 1: descrambler (per symbol, arrival order; parallel LFSR candidates)
    // ------------------------------------------------------------------
    reg  [15:0] lfsr;
    reg         after_com;
    reg  [3:0]  raw_left;     // remaining raw (unscrambled) symbols of a TS/EIEOS
    wire [15:0] a8   = f_lfsr_adv8(lfsr);
    wire [15:0] a16  = f_lfsr_adv8(a8);
    wire [7:0]  b_l  = f_lfsr_byte(lfsr);
    wire [7:0]  b_a8 = f_lfsr_byte(a8);
    localparam [15:0] AF = 16'hE817;          // f_lfsr_adv8(16'hFFFF)
    localparam [7:0]  BF = 8'hFF;             // f_lfsr_byte(16'hFFFF)

    // control state after symbol 0
    reg       ac1; reg [3:0] rl1; reg raw_0;
    always @(*) begin
        ac1 = after_com; rl1 = raw_left; raw_0 = 1'b1;
        if (r_com[0]) begin ac1 = 1'b1; rl1 = 4'd0; end
        else if (r_skp[0]) ac1 = 1'b0;
        else if (after_com) begin ac1 = 1'b0; if (r_rawstart[0]) rl1 = 4'd14; end
        else if (raw_left != 4'd0) rl1 = raw_left - 1'b1;
        else raw_0 = 1'b0;          // a scrambled-domain symbol
    end
    reg       ac2; reg [3:0] rl2; reg raw_1;
    always @(*) begin
        ac2 = ac1; rl2 = rl1; raw_1 = 1'b1;
        if (r_com[1]) begin ac2 = 1'b1; rl2 = 4'd0; end
        else if (r_skp[1]) ac2 = 1'b0;
        else if (ac1) begin ac2 = 1'b0; if (r_rawstart[1]) rl2 = 4'd14; end
        else if (rl1 != 4'd0) rl2 = rl1 - 1'b1;
        else raw_1 = 1'b0;
    end
    // scramble byte for slot 1 and final LFSR depending on slot 0
    wire [7:0]  sb1 = r_com[0] ? BF : r_skp[0] ? b_l : b_a8;
    wire [15:0] l1  = r_com[0] ? 16'hFFFF : r_skp[0] ? lfsr : a8;
    wire [15:0] l2  = r_com[1] ? 16'hFFFF : r_skp[1] ? l1 : (r_com[0] ? AF : r_skp[0] ? a8 : a16);

    reg [15:0] ds_d; reg [1:0] ds_k; reg ds_v; reg ds_err;
    reg [9:0]  ds_c0, ds_c1;                // {COM, SKP, K class}
    reg [1:0]  ds_z;                        // descrambled data symbol is 00
    always @(posedge clk) begin
        if (rst) begin
            lfsr <= 16'hFFFF; after_com <= 1'b0; raw_left <= 4'd0; ds_v <= 1'b0;
        end else begin
            if (r_v) begin
                lfsr <= l2; after_com <= ac2; raw_left <= rl2;
            end
            ds_v <= r_v;
        end
        ds_d[7:0]  <= (!r_k[0] && !raw_0 && descramble_en) ? r_d[7:0] ^ b_l : r_d[7:0];
        ds_d[15:8] <= (!r_k[1] && !raw_1 && descramble_en) ? r_d[15:8] ^ sb1 : r_d[15:8];
        ds_k   <= r_k;
        ds_err <= r_err;
        ds_c0  <= {r_com[0], r_skp[0], r_kc0};
        ds_c1  <= {r_com[1], r_skp[1], r_kc1};
        ds_z[0] <= !r_k[0] && ((!raw_0 && descramble_en) ? r_d[7:0] == b_l : r_d[7:0] == 8'h00);
        ds_z[1] <= !r_k[1] && ((!raw_1 && descramble_en) ? r_d[15:8] == sb1 : r_d[15:8] == 8'h00);
    end

    // ------------------------------------------------------------------
    // stage 2: aligner -> pairs with start symbols in slot 0, plus pre-decode
    // ------------------------------------------------------------------
    // start symbol = COM/STP/SDP (flags {COM,SKP,STP,SDP,...} = bits 9,8,7,6)
    reg        h_v; reg [7:0] h_d; reg h_k; reg [9:0] h_c; reg h_z;
    reg        al_v; reg [7:0] al_d0, al_d1; reg al_k0, al_k1; reg al_err;
    wire [7:0] a_d = ds_d[7:0], b_d = ds_d[15:8];
    wire       a_k = ds_k[0],   b_k = ds_k[1];
    wire       a_st = ds_c0[9] | ds_c0[7] | ds_c0[6];
    wire       b_st = ds_c1[9] | ds_c1[7] | ds_c1[6];
    wire       h_st = h_c[9] | h_c[7] | h_c[6];
    reg  [7:0] n_d0, n_d1; reg n_k0, n_k1, n_v; reg [9:0] n_c0, n_c1; reg n_z0, n_z1;
    always @(*) begin
        n_v = 1'b1; n_d0 = a_d; n_k0 = a_k; n_d1 = b_d; n_k1 = b_k;
        n_c0 = ds_c0; n_c1 = ds_c1; n_z0 = ds_z[0]; n_z1 = ds_z[1];
        if (!h_v) begin
            if (b_st && !a_st) n_v = 1'b0;                         // drop a, keep b
        end else if (!(a_st && !h_st)) begin
            n_d0 = h_d; n_k0 = h_k; n_c0 = h_c; n_z0 = h_z;        // (h, a), keep b
            n_d1 = a_d; n_k1 = a_k; n_c1 = ds_c0; n_z1 = ds_z[0];
        end                                                        // else drop h
    end
    // pre-decoded flags of the aligned pair
    reg al_com0, al_stp0, al_sdp0, al_skp0, al_skp1, al_idl1, al_fts1, al_eie1, al_pad1, al_pad0;
    reg al_end1, al_edb1, al_idle;
    always @(posedge clk) begin
        if (rst || !ds_v) begin
            h_v <= 1'b0; al_v <= 1'b0;
        end else begin
            al_v <= n_v;
            if (!h_v) begin
                if (b_st && !a_st) begin h_v <= 1'b1; h_d <= b_d; h_k <= b_k; h_c <= ds_c1; h_z <= ds_z[1]; end
            end else if (a_st && !h_st) h_v <= 1'b0;
            else begin h_d <= b_d; h_k <= b_k; h_c <= ds_c1; h_z <= ds_z[1]; end
        end
        al_d0 <= n_d0; al_d1 <= n_d1; al_k0 <= n_k0; al_k1 <= n_k1;
        al_com0 <= n_c0[9];  al_skp0 <= n_c0[8]; al_stp0 <= n_c0[7]; al_sdp0 <= n_c0[6]; al_pad0 <= n_c0[2];
        al_skp1 <= n_c1[8];  al_idl1 <= n_c1[5]; al_fts1 <= n_c1[4]; al_eie1 <= n_c1[3]; al_pad1 <= n_c1[2];
        al_end1 <= n_c1[1];  al_edb1 <= n_c1[0];
        al_idle <= n_z0 && n_z1;
        al_err  <= ds_err;
    end

    // ------------------------------------------------------------------
    // stage 3: parser
    // ------------------------------------------------------------------
    localparam P_IDLE = 3'd0, P_SKP = 3'd1, P_TS = 3'd2, P_TLP = 3'd3, P_DLLP = 3'd4, P_IGN = 3'd5;
    reg [2:0]  pst;
    reg [3:0]  ts_idx;
    reg [7:0]  ts_link, ts_lane, ts_nfts, ts_rate, ts_ctrl, ts_id;
    reg        ts_lpad, ts_npad, ts_bad, ts_fin;
    reg [1:0]  dl_idx;
    reg [47:0] dl_buf;
    reg        dl_fin, dl_bad;
    reg [15:0] dl_crc;            // DLLP CRC16, accumulated as the bytes arrive
    reg [31:0] crc;
    reg [11:0] seq;
    reg        ph;                // TLP pair phase: 0 -> bytes (1,2) of a DW, 1 -> (3 | 0 of next)
    reg        first_pair;        // first pair after STP: (seq_lo, T0)
    reg [23:0] sr;                // partial DW
    reg        pend_v;  reg [31:0] pend;    // last complete DW (may be LCRC)
    reg        hi_v;    reg [31:0] hi;      // upper DW of the beat being built
    reg        first_beat;
    reg        tlp_err;
    reg [10:0] ndw;               // complete DWs so far (incl. LCRC)
    reg        eop_q, eop_null, eop_flag_bad, eop_hi_v, eop_sop; reg [31:0] eop_hi;

    wire [31:0] crc1 = f_crc32_byte(crc, al_d0);
    wire [31:0] crc2 = f_crc32_byte(crc1, al_d1);

    always @(posedge clk) begin
        os_ts_valid <= 1'b0; os_eios <= 1'b0; os_skp <= 1'b0; os_idle2 <= 1'b0;
        os_pkt_start <= 1'b0; rx_err <= 1'b0; pkt_we <= 1'b0;
        ts_fin <= 1'b0; dl_fin <= 1'b0; eop_q <= 1'b0;
        // deferred completions (one clock after the closing symbol)
        if (eop_q) begin
            pkt_we <= 1'b1;
            pkt_wd <= {eop_hi_v, eop_null, (eop_flag_bad || (!eop_null && crc != 32'hDEBB20E3)),
                       1'b0, 1'b1, seq, eop_sop, eop_hi, 32'd0};
            if (!eop_null && crc != 32'hDEBB20E3) rx_err <= 1'b1;
        end
        if (dl_fin) begin
            pkt_we <= 1'b1;
            pkt_wd <= {1'b0, 1'b0, (dl_bad || {f_rev8(~dl_crc[15:8]), f_rev8(~dl_crc[7:0])} != dl_buf[15:0]),
                       1'b1, 1'b0, 12'd0, 1'b0, dl_buf[47:16], 32'd0};
        end
        if (ts_fin && !ts_bad) begin
            os_ts_valid <= 1'b1;
            os_ts2      <= (ts_id == 8'h45 || ts_id == 8'hBA);
            os_ts_inv   <= (ts_id == 8'hB5 || ts_id == 8'hBA);
            os_link     <= ts_link; os_link_pad <= ts_lpad;
            os_lane     <= ts_lane; os_lane_pad <= ts_npad;
            os_nfts     <= ts_nfts; os_rate <= ts_rate; os_ctrl <= ts_ctrl;
        end

        if (rst) begin
            pst <= P_IDLE; pend_v <= 1'b0; hi_v <= 1'b0;
        end else if (!al_v) begin
            // gap in the symbol stream: abandon any packet in progress
            if (pst == P_TLP) begin
                eop_q <= 1'b1; eop_null <= 1'b0; eop_flag_bad <= 1'b1; eop_hi_v <= 1'b0; eop_sop <= 1'b0;
            end
            if (pst != P_IDLE && pst != P_SKP) pst <= P_IDLE;
        end else begin
            if (al_err) rx_err <= 1'b1;
            case (pst)
            P_IDLE, P_SKP: begin
                if (pst == P_SKP && al_skp0) begin
                    // still inside a SKP ordered set
                end else if (al_com0) begin
                    if (al_skp1) begin
                        pst <= P_SKP; os_skp <= 1'b1;
                    end else if (al_idl1) begin
                        os_eios <= 1'b1; pst <= P_IGN; ts_idx <= 4'd2;  // skip remaining 2 IDL
                    end else if (al_fts1) begin
                        pst <= P_IGN; ts_idx <= 4'd2;
                    end else if (al_eie1) begin
                        pst <= P_IGN; ts_idx <= 4'd14;
                    end else begin
                        pst <= P_TS; ts_idx <= 4'd2;
                        ts_link <= al_d1; ts_lpad <= al_pad1;
                        ts_bad  <= al_k1 && !al_pad1;
                    end
                end else if (al_stp0) begin
                    os_pkt_start <= 1'b1;
                    pst <= P_TLP;
                    crc <= f_crc32_byte(32'hFFFFFFFF, al_d1);
                    seq[11:8] <= al_d1[3:0];
                    ph <= 1'b0; first_pair <= 1'b1; pend_v <= 1'b0; hi_v <= 1'b0; ndw <= 11'd0;
                    first_beat <= 1'b1;
                    tlp_err <= al_k1 || al_err;
                end else if (al_sdp0) begin
                    os_pkt_start <= 1'b1;
                    pst <= P_DLLP; dl_idx <= 2'd1; dl_buf <= {al_d1, 40'd0};
                    dl_crc <= f_crc16_byte(16'hFFFF, al_d1);
                    dl_bad <= al_k1 || al_err;
                end else begin
                    if (pst == P_SKP) pst <= P_IDLE;
                    if (al_idle) os_idle2 <= 1'b1;
                end
            end
            P_IGN: begin
                if (ts_idx <= 4'd2) pst <= P_IDLE; else ts_idx <= ts_idx - 4'd2;
            end
            P_TS: begin
                if (al_k1) ts_bad <= 1'b1;
                case (ts_idx)
                4'd2: begin
                    ts_lane <= al_d0; ts_nfts <= al_d1; ts_npad <= al_pad0;
                    if (al_k0 && !al_pad0) ts_bad <= 1'b1;
                end
                4'd4: begin
                    ts_rate <= al_d0; ts_ctrl <= al_d1;
                    if (al_k0) ts_bad <= 1'b1;
                end
                4'd6: begin
                    ts_id <= al_d0;
                    if (al_k0 || al_d1 != al_d0 ||
                        !(al_d0 == 8'h4A || al_d0 == 8'h45 || al_d0 == 8'hB5 || al_d0 == 8'hBA)) ts_bad <= 1'b1;
                end
                default: if (al_k0 || al_d0 != ts_id || al_d1 != ts_id) ts_bad <= 1'b1;
                endcase
                if (ts_idx == 4'd14) begin pst <= P_IDLE; ts_fin <= 1'b1; end
                else ts_idx <= ts_idx + 4'd2;
            end
            P_DLLP: begin
                dl_idx <= dl_idx + 2'd1;
                case (dl_idx)
                2'd1: begin dl_buf[39:24] <= {al_d0, al_d1}; if (al_k0 || al_k1) dl_bad <= 1'b1;
                            dl_crc <= f_crc16_byte(f_crc16_byte(dl_crc, al_d0), al_d1); end
                2'd2: begin dl_buf[23:8]  <= {al_d0, al_d1}; if (al_k0 || al_k1) dl_bad <= 1'b1;
                            dl_crc <= f_crc16_byte(dl_crc, al_d0); end
                default: begin
                    dl_buf[7:0] <= al_d0;
                    pst <= P_IDLE; dl_fin <= 1'b1;
                    if (al_k0 || !al_end1 || al_err) begin dl_bad <= 1'b1; rx_err <= 1'b1; end
                end
                endcase
            end
            P_TLP: begin
                if (al_err) tlp_err <= 1'b1;
                first_pair <= 1'b0;
                if (al_k0 || (al_k1 && !al_end1 && !al_edb1)) begin
                    // framing error inside the packet
                    pst <= P_IDLE; rx_err <= 1'b1;
                    eop_q <= 1'b1; eop_null <= 1'b0; eop_flag_bad <= 1'b1; eop_hi_v <= 1'b0; eop_sop <= 1'b0;
                end else if (al_k1) begin
                    // END/EDB in slot 1: slot 0 is the last LCRC byte and must close a DW (phase 1)
                    crc <= crc1;
                    pst <= P_IDLE;
                    eop_q <= 1'b1; eop_null <= al_edb1;
                    eop_flag_bad <= tlp_err || !ph || first_pair || ndw < 11'd3;
                    eop_hi_v <= hi_v; eop_hi <= hi;
                    eop_sop <= first_beat && !(ph && pend_v && hi_v);
                    // the completing DW is the LCRC: push the previous one first
                    if (ph && pend_v) begin
                        if (hi_v) begin
                            pkt_we <= 1'b1; first_beat <= 1'b0; hi_v <= 1'b0;
                            pkt_wd <= {1'b0, 1'b0, 1'b0, 1'b0, 1'b0, seq, first_beat, hi, pend};
                            eop_hi_v <= 1'b0;
                        end else begin
                            eop_hi_v <= 1'b1; eop_hi <= pend;
                        end
                    end
                end else begin
                    crc <= crc2;
                    if (first_pair) begin
                        seq[7:0] <= al_d0; sr <= {16'd0, al_d1}; ph <= 1'b0;
                    end else if (!ph) begin
                        sr <= {sr[7:0], al_d0, al_d1}; ph <= 1'b1;
                    end else begin
                        // DW complete with slot 0; slot 1 starts the next DW
                        ph <= 1'b0; sr <= {16'd0, al_d1}; ndw <= ndw + 1'b1;
                        pend <= {sr, al_d0}; pend_v <= 1'b1;
                        if (pend_v) begin
                            if (hi_v) begin
                                pkt_we <= 1'b1; first_beat <= 1'b0; hi_v <= 1'b0;
                                pkt_wd <= {1'b0, 1'b0, 1'b0, 1'b0, 1'b0, seq, first_beat, hi, pend};
                            end else begin
                                hi <= pend; hi_v <= 1'b1;
                            end
                        end
                    end
                end
            end
            default: pst <= P_IDLE;
            endcase
        end
    end

    // pkt_wd layout:
    //  [63:0]  data (TLP DW0 at [63:32])
    //  [64]    sop   : first data beat of a TLP (or: marker of a TLP that had no full beat)
    //  [76:65] seq   : TLP sequence number
    //  [77]    eop   : end marker (no data except [63:32] when half=1)
    //  [78]    dllp  : DLLP entry, DLLP bytes 0..3 in [63:32]
    //  [79]    bad   : LCRC/CRC16/framing error
    //  [80]    null  : nullified TLP (EDB)
    //  [81]    half  : (eop marker) an extra final DW is carried in [63:32]
endmodule
