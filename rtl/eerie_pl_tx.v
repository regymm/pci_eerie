// SPDX-License-Identifier: CERN-OHL-P
// pci_eerie: physical layer transmit path (one lane, 2 symbols per PIPE clock)
//
// Generates TS1/TS2/EIOS/EIEOS/SKP ordered sets as directed by the LTSSM and,
// in data mode, serializes framed packets (already carrying STP/SDP/END and
// LCRC/CRC from the DLL) from a packet-mode FIFO, inserting logical idle and
// SKP ordered sets.  Everything leaves aligned to the 16-bit PIPE word:
// ordered sets and packets always start in byte 0.
//
// Pipeline (for 250 MHz at 5 GT/s):
//   FIFO -> 2-entry beat prefetch -> symbol select (reg) -> scrambler (reg) -> PIPE
`timescale 1ns / 1ps
module eerie_pl_tx #(
    parameter SKP_INTERVAL = 1200      // symbol times between scheduled SKP OS (1180..1538)
) (
    input             clk,
    input             rst,

    // LTSSM control
    input      [2:0]  mode,            // see localparams below
    input      [7:0]  ts_link,
    input             ts_link_pad,
    input      [7:0]  ts_lane,
    input             ts_lane_pad,
    input      [7:0]  ts_nfts,
    input      [7:0]  ts_rate,
    input      [7:0]  ts_ctrl,
    input             scramble_en,
    input             gen2,            // operating at 5.0 GT/s: EIEOS before / every 32 TS
    input             eieos_clr,       // reset the EIEOS interval count (first TS2 in RcvrCfg)
    output reg        ts_done,         // pulse: one TS1/TS2 completely sent
    output reg        eios_done,       // pulse: one EIOS completely sent
    output reg        idle_pair,       // pulse: two logical idle symbols sent
    output reg        busy,            // OS/packet in progress (mode change pending)

    // framed packets (FWFT FIFO, whole packets only)
    input      [66:0] pkt_rd_data,     // {half,last,sop,data[63:0]}
    input             pkt_rd_empty,
    output            pkt_rd_en,

    // PIPE
    output reg [15:0] pipe_txdata,
    output reg [1:0]  pipe_txdatak,
    output reg        pipe_txelecidle
);
    `include "eerie_funcs.vh"

    localparam M_EIDLE = 3'd0, M_TS1 = 3'd1, M_TS2 = 3'd2, M_DATA = 3'd3, M_EIOS = 3'd4,
               M_IDLE = 3'd5;   // M_IDLE: logical idle only (Configuration.Idle / Recovery.Idle)
    localparam K_COM = 8'hBC, K_PAD = 8'hF7, K_SKP = 8'h1C, K_IDL = 8'h7C, K_EIE = 8'hFC;

    localparam S_IDLE = 3'd0, S_TS = 3'd1, S_SKP = 3'd2, S_EIOS = 3'd3, S_PKT = 3'd4, S_EIEOS = 3'd5;

    // ------------------------------------------------------------------
    // beat prefetch (2 entries); the FIFO pop only depends on registers
    // ------------------------------------------------------------------
    reg [66:0] bq0, bq1;
    reg        bq0_v, bq1_v;
    wire       pop = !pkt_rd_empty && !(bq0_v && bq1_v) && !rst;
    assign pkt_rd_en = pop;
    reg        consume;              // head beat fully sent this cycle (from the select stage)

    always @(posedge clk) begin
        if (rst) begin
            bq0_v <= 1'b0; bq1_v <= 1'b0;
        end else begin
            case ({consume, pop})
            2'b01: if (!bq0_v) begin bq0 <= pkt_rd_data; bq0_v <= 1'b1; end
                   else begin bq1 <= pkt_rd_data; bq1_v <= 1'b1; end
            2'b10: begin bq0 <= bq1; bq0_v <= bq1_v; bq1_v <= 1'b0; end
            2'b11: if (bq1_v) begin bq0 <= bq1; bq1 <= pkt_rd_data; end
                   else begin bq0 <= pkt_rd_data; end
            default: ;
            endcase
        end
    end
    wire [63:0] pd = bq0[63:0];
    wire        p_sop = bq0[64], p_last = bq0[65], p_half = bq0[66];

    // ------------------------------------------------------------------
    // stage 1: symbol select
    // ------------------------------------------------------------------
    reg [2:0]  st;
    reg [2:0]  idx;
    reg        cur_ts2;
    reg [10:0] skp_cnt;
    reg [2:0]  skp_pend;
    reg [5:0]  ei_cnt;       // TS sent since the last EIEOS
    reg        ei_due;       // registered: an EIEOS is due before the next TS
    reg        prev_ts;      // the TS sequence is ongoing (no EIEOS needed before the next TS)

    reg [7:0] s0, s1; reg k0, k1; reg raw0, raw1;  // raw: not scrambled (TS / EIEOS data)
    reg       eidle;
    reg [2:0] n_st; reg [2:0] n_idx; reg n_ts2;
    reg       n_ts_done, n_eios_done, n_idle_pair, n_consume, take_skp, n_eieos_start;
    wire      is_ts_mode = (mode == M_TS1 || mode == M_TS2);

    task ts_pair;
        input [2:0] i;
        input       is2;
        begin
            raw0 = 1'b1; raw1 = 1'b1; k0 = 1'b0; k1 = 1'b0;
            case (i)
            3'd0: begin s0 = K_COM; k0 = 1'b1; s1 = ts_link_pad ? K_PAD : ts_link; k1 = ts_link_pad; end
            3'd1: begin s0 = ts_lane_pad ? K_PAD : ts_lane; k0 = ts_lane_pad; s1 = ts_nfts; end
            3'd2: begin s0 = ts_rate; s1 = ts_ctrl; end
            default: begin s0 = is2 ? 8'h45 : 8'h4A; s1 = s0; end
            endcase
        end
    endtask

    always @(*) begin
        s0 = 8'h00; s1 = 8'h00; k0 = 1'b0; k1 = 1'b0; raw0 = 1'b0; raw1 = 1'b0; eidle = 1'b0;
        n_st = st; n_idx = idx; n_ts2 = cur_ts2;
        n_ts_done = 1'b0; n_eios_done = 1'b0; n_idle_pair = 1'b0; n_consume = 1'b0; take_skp = 1'b0;
        n_eieos_start = 1'b0;
        case (st)
        S_TS: begin
            ts_pair(idx, cur_ts2);
            n_idx = idx + 1'b1;
            if (idx == 3'd7) begin n_st = S_IDLE; n_ts_done = 1'b1; end
        end
        S_SKP: begin
            s0 = K_SKP; s1 = K_SKP; k0 = 1'b1; k1 = 1'b1;
            n_st = S_IDLE;
        end
        S_EIEOS: begin
            s0 = K_EIE; k0 = 1'b1;
            if (idx == 3'd7) begin s1 = 8'h4A; k1 = 1'b0; raw1 = 1'b1; n_st = S_IDLE; end
            else begin s1 = K_EIE; k1 = 1'b1; end
            n_idx = idx + 1'b1;
        end
        S_EIOS: begin
            s0 = K_IDL; s1 = K_IDL; k0 = 1'b1; k1 = 1'b1;
            n_st = S_IDLE; n_eios_done = 1'b1;
        end
        S_PKT: begin
            case (idx[1:0])
            2'd0: begin s0 = pd[63:56]; s1 = pd[55:48]; end
            2'd1: begin s0 = pd[47:40]; s1 = pd[39:32]; end
            2'd2: begin s0 = pd[31:24]; s1 = pd[23:16]; end
            default: begin s0 = pd[15:8]; s1 = pd[7:0]; end
            endcase
            k0 = p_sop && idx[1:0] == 2'd0;
            k1 = p_last && (p_half ? idx[1:0] == 2'd1 : idx[1:0] == 2'd3);
            n_idx = idx + 1'b1;
            if ((p_half && idx[1:0] == 2'd1) || idx[1:0] == 2'd3) begin
                n_consume = 1'b1; n_idx = 3'd0;
                if (p_last) n_st = S_IDLE;
            end
        end
        default: begin // S_IDLE: choose what to start this cycle
            if (mode == M_EIDLE) begin
                eidle = 1'b1;
            end else if (skp_pend != 0) begin
                take_skp = 1'b1;
                s0 = K_COM; s1 = K_SKP; k0 = 1'b1; k1 = 1'b1;
                n_st = S_SKP;
            end else if (is_ts_mode && ei_due) begin
                s0 = K_COM; k0 = 1'b1; s1 = K_EIE; k1 = 1'b1;
                n_st = S_EIEOS; n_idx = 3'd1; n_eieos_start = 1'b1;
            end else if (is_ts_mode) begin
                n_ts2 = (mode == M_TS2);
                ts_pair(3'd0, mode == M_TS2);
                n_st = S_TS; n_idx = 3'd1;
            end else if (mode == M_EIOS) begin
                s0 = K_COM; s1 = K_IDL; k0 = 1'b1; k1 = 1'b1;
                n_st = S_EIOS;
            end else if (mode == M_DATA && bq0_v) begin
                s0 = pd[63:56]; s1 = pd[55:48]; k0 = p_sop; k1 = 1'b0;
                n_st = S_PKT; n_idx = 3'd1;
            end else begin
                n_idle_pair = 1'b1;   // logical idle: scrambled 00
            end
        end
        endcase
    end
    always @(*) consume = n_consume && !rst;

    // registered select-stage outputs
    reg [7:0] q_s0, q_s1;
    reg       q_k0, q_k1, q_scr0, q_scr1, q_com0, q_skp0, q_skp1, q_eidle;

    always @(posedge clk) begin
        if (rst) begin
            st <= S_IDLE; idx <= 3'd0; cur_ts2 <= 1'b0; ei_cnt <= 6'd0; ei_due <= 1'b0; prev_ts <= 1'b0;
            skp_cnt <= 11'd0; skp_pend <= 3'd0; q_eidle <= 1'b1;
            ts_done <= 1'b0; eios_done <= 1'b0; idle_pair <= 1'b0; busy <= 1'b0;
        end else begin
            st <= n_st; idx <= n_idx; cur_ts2 <= n_ts2;
            if (n_eieos_start || eieos_clr) ei_cnt <= 6'd0;
            else if (n_ts_done && ei_cnt != 6'h3F) ei_cnt <= ei_cnt + 1'b1;
            if (n_eieos_start || n_ts_done) prev_ts <= 1'b1;
            else if (st == S_IDLE && !is_ts_mode && skp_pend == 0) prev_ts <= 1'b0;
            // EIEOS needed at 5 GT/s before the first TS of a sequence and after every 32 TS
            // (computed from the next-cycle values of prev_ts / ei_cnt)
            ei_due <= gen2 && (
                        !((n_eieos_start || n_ts_done) ||
                          (prev_ts && !(st == S_IDLE && !is_ts_mode && skp_pend == 0))) ||
                        (!(n_eieos_start || eieos_clr) &&
                         (ei_cnt >= 6'd32 || (n_ts_done && ei_cnt == 6'd31))));
            ts_done <= n_ts_done; eios_done <= n_eios_done; idle_pair <= n_idle_pair;
            busy <= (n_st != S_IDLE);
            q_s0 <= s0; q_s1 <= s1; q_k0 <= k0; q_k1 <= k1;
            q_scr0 <= !k0 && !raw0 && scramble_en;
            q_scr1 <= !k1 && !raw1 && scramble_en;
            q_com0 <= k0 && s0 == K_COM;
            q_skp0 <= k0 && s0 == K_SKP;
            q_skp1 <= k1 && s1 == K_SKP;
            q_eidle <= eidle;
            if (eidle) begin
                skp_cnt <= 11'd0; skp_pend <= 3'd0;
            end else if (skp_cnt >= SKP_INTERVAL / 2 - 1) begin
                skp_cnt <= 11'd0;
                if (!take_skp && skp_pend != 3'd7) skp_pend <= skp_pend + 1'b1;
            end else begin
                skp_cnt <= skp_cnt + 1'b1;
                if (take_skp) skp_pend <= skp_pend - 1'b1;
            end
        end
    end

    // ------------------------------------------------------------------
    // stage 2: scrambler (LFSR candidates computed in parallel)
    // ------------------------------------------------------------------
    reg  [15:0] lfsr;
    wire [15:0] a8   = f_lfsr_adv8(lfsr);
    wire [15:0] a16  = f_lfsr_adv8(a8);
    wire [7:0]  b_l  = f_lfsr_byte(lfsr);
    wire [7:0]  b_a8 = f_lfsr_byte(a8);
    localparam [15:0] AF = 16'hE817;          // f_lfsr_adv8(16'hFFFF)
    localparam [7:0]  BF = 8'hFF;             // f_lfsr_byte(16'hFFFF)

    // slot 1 scramble byte / final LFSR depending on what slot 0 did
    wire [7:0]  b1   = q_com0 ? BF : q_skp0 ? b_l : b_a8;
    wire [15:0] l1   = q_com0 ? 16'hFFFF : q_skp0 ? lfsr : a8;
    wire [15:0] l2   = q_skp1 ? l1 : (q_com0 ? AF : q_skp0 ? a8 : a16);

    always @(posedge clk) begin
        if (rst || q_eidle) begin
            lfsr <= 16'hFFFF;
            pipe_txdata <= 16'd0; pipe_txdatak <= 2'b00; pipe_txelecidle <= 1'b1;
        end else begin
            lfsr <= l2;
            pipe_txdata <= {q_scr1 ? (q_s1 ^ b1) : q_s1, q_scr0 ? (q_s0 ^ b_l) : q_s0};
            pipe_txdatak <= {q_k1, q_k0};
            pipe_txelecidle <= 1'b0;
        end
    end
endmodule
