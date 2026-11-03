// SPDX-License-Identifier: CERN-OHL-P
// pci_eerie: Link Training and Status State Machine (upstream port, x1, Gen1/Gen2)
//
// State encodings follow the PCIE_2_1 pl_ltssm_state[5:0] values (pg054).
`timescale 1ns / 1ps
module eerie_ltssm #(
    parameter MAX_RATE   = 1,       // 1: 2.5 GT/s, 2: 5.0 GT/s
    parameter FAST_TRAIN = 0,       // shorten timers for simulation
    parameter [7:0] N_FTS_GEN1 = 8'd255,
    parameter [7:0] N_FTS_GEN2 = 8'd255,
    parameter       UPCONFIG   = 1       // advertise Link Upconfigure Capability (TS2 symbol 4 bit 6)
) (
    input             clk,
    input             rst,

    // PIPE control
    output reg        pipe_txdetectrx,
    output reg [1:0]  pipe_powerdown,
    output reg        pipe_rate,
    output reg        pipe_rxpolarity,
    input             i_pipe_phystatus,
    input      [2:0]  i_pipe_rxstatus,
    input             i_pipe_rxelecidle,

    // TX path control
    output reg [2:0]  tx_mode,
    output reg [7:0]  tx_link,
    output reg        tx_link_pad,
    output reg [7:0]  tx_lane,
    output reg        tx_lane_pad,
    output     [7:0]  tx_nfts,
    output reg [7:0]  tx_rate,
    output reg [7:0]  tx_ctrl,
    input             tx_ts_done,
    input             tx_eios_done,
    input             tx_idle_pair,
    input             tx_busy,
    output reg        scramble_en,
    output reg        eieos_clr,

    // RX ordered-set events
    input             i_os_ts_valid,
    input             i_os_ts2,
    input             i_os_ts_inv,
    input      [7:0]  i_os_link,
    input             i_os_link_pad,
    input      [7:0]  i_os_lane,
    input             i_os_lane_pad,
    input      [7:0]  i_os_nfts,
    input      [7:0]  i_os_rate,
    input      [7:0]  i_os_ctrl,
    input             i_os_eios,
    input             i_os_idle2,

    // upper layer interface
    input             retrain_req,       // pulse: go to Recovery (e.g. REPLAY_NUM rollover)
    output reg        link_up,           // LinkUp (to the DLL)
    output reg        in_l0,
    output reg [5:0]  ltssm_state,
    output reg        hot_reset,         // in Hot Reset (upstream: received)
    output reg        link_training,
    output reg        partner_gen2,      // partner advertised 5.0 GT/s
    output reg [7:0]  link_num,
    output reg        rcvr_err_ltssm     // unused hook
);
    localparam M_EIDLE = 3'd0, M_TS1 = 3'd1, M_TS2 = 3'd2, M_DATA = 3'd3, M_EIOS = 3'd4,
               M_IDLE = 3'd5;   // M_IDLE: logical idle only (Configuration.Idle / Recovery.Idle)

    localparam ST_DQUIET = 6'h00, ST_DACTIVE = 6'h02, ST_PACTIVE = 6'h04, ST_PCONFIG = 6'h05,
               ST_CLWSTART = 6'h0B, ST_CLWACCEPT = 6'h0D, ST_CLNWAIT = 6'h0F, ST_CLNACCEPT = 6'h10,
               ST_CCOMPLETE = 6'h11, ST_CIDLE = 6'h15, ST_L0 = 6'h16,
               ST_RLOCK = 6'h1C, ST_RCFG = 6'h1D, ST_RSPEED = 6'h1E, ST_RIDLE = 6'h20,
               ST_HOTRST = 6'h21, ST_DISABLED = 6'h22;

    // GT status outputs arrive late in the clock period: register them first
    reg        pipe_phystatus, pipe_rxelecidle;
    reg [2:0]  pipe_rxstatus;
    always @(posedge clk) begin
        pipe_phystatus <= i_pipe_phystatus; pipe_rxstatus <= i_pipe_rxstatus; pipe_rxelecidle <= i_pipe_rxelecidle;
    end

    // ---------------- timers ----------------
    // pclk is 125 MHz at 2.5 GT/s and 250 MHz at 5.0 GT/s (2 symbols / clock)
    reg [7:0]  us_div;
    reg        us_tick;
    reg [15:0] t_us;            // microseconds since state entry
    reg        t_clr;
    always @(posedge clk) begin
        us_tick <= 1'b0;
        if (rst || t_clr) begin
            us_div <= 8'd0; t_us <= 16'd0;
        end else if (us_div == (pipe_rate ? 8'd249 : 8'd124)) begin
            us_div <= 8'd0; us_tick <= 1'b1;
            if (t_us != 16'hFFFF) t_us <= t_us + 1'b1;
        end else us_div <= us_div + 1'b1;
    end
    // nanosecond-ish counter for short electrical idle windows
    reg [11:0] t_cyc;
    reg        ei_time_ok;   // registered: minimum electrical idle time in Recovery.Speed elapsed
    reg [2:0]  sub_d;
    reg        rs_go;        // registered: leave Recovery.Speed

    function [15:0] tmo;     // timeout in us; FAST_TRAIN shrinks the long ones
        input [15:0] ms_val; // value in ms*1000 (i.e. microseconds)
        input [15:0] fast_us;
        tmo = FAST_TRAIN ? fast_us : ms_val;
    endfunction

    localparam [15:0] T_12MS = 16'd12000, T_24MS = 16'd24000, T_48MS = 16'd48000,
                      T_2MS = 16'd2000, T_1MS = 16'd1000;

    // registered timeout flags (valid from the second clock after a state change)
    reg r_to1, r_to2, r_to20, r_to100, r_to1000, r_to12, r_to24, r_to48, r_to2ms, r_tohot;
    reg t_clr_d;
    always @(posedge clk) begin
        t_clr_d  <= t_clr;
        r_to1    <= !t_clr && t_us >= 16'd1;
        r_to2    <= !t_clr && t_us >= 16'd2;
        r_to20   <= !t_clr && t_us >= 16'd20;
        r_to100  <= !t_clr && t_us >= 16'd100;
        r_to1000 <= !t_clr && t_us >= 16'd1000;
        r_to12   <= !t_clr && t_us >= tmo(T_12MS, 16'd2);
        r_to24   <= !t_clr && t_us >= tmo(T_24MS, 16'd400);
        r_to48   <= !t_clr && t_us >= tmo(T_48MS, 16'd800);
        r_to2ms  <= !t_clr && t_us >= tmo(T_2MS, 16'd200);
        r_tohot  <= !t_clr && t_us >= tmo(T_2MS, 16'd20);
    end
    wire to_ok   = !t_clr && !t_clr_d;
    wire to1     = r_to1 && to_ok,    to2   = r_to2 && to_ok,   to20 = r_to20 && to_ok;
    wire to100   = r_to100 && to_ok,  to1000 = r_to1000 && to_ok;
    wire to12    = r_to12 && to_ok,   to24  = r_to24 && to_ok,  to48 = r_to48 && to_ok;
    wire to2ms   = r_to2ms && to_ok,  tohot = r_tohot && to_ok;

    // ---------------- state ----------------
    reg [5:0]  st;
    reg [2:0]  sub;
    reg [10:0] ts_tx_cnt;        // TS sent (in state)
    reg [5:0]  tx_after;         // TS / idle sent after first qualifying receive
    reg        rx_first;         // received first qualifying TS / idle
    reg [3:0]  cnt_a, cnt_b;     // consecutive receive counters
    reg [7:0]  rx_rate_rec;
    reg        directed_speed_change, changed_speed_recovery, successful_speed_neg;
    reg        idle_to_rlock;
    reg        rx_ei_seen;
    reg        rx_ts2_seen;
    reg        cur_gen2;
    reg [7:0]  lane_num;
    reg [7:0]  lane_at_entry;
    reg        rate_target;
    reg        hot_from_rx;
    reg        dis_scr_seen;

    wire [7:0] my_rates = (MAX_RATE >= 2) ? 8'h06 : 8'h02;
    // symbol 4 bit 6: Link Upconfigure Capability in Configuration TS2s, selectable
    // de-emphasis (-3.5 dB) in Recovery; set like the PCIE_2_1 block does
    wire [7:0] my_rates_b6 = my_rates | (UPCONFIG ? 8'h40 : 8'h00);
    assign tx_nfts = cur_gen2 ? N_FTS_GEN2 : N_FTS_GEN1;

    // received ordered-set events, registered together with their classification
    reg        os_ts_valid, os_ts2, os_ts_inv, os_link_pad, os_lane_pad, os_eios, os_idle2;
    reg [7:0]  os_link, os_lane, os_nfts, os_rate, os_ctrl;
    reg        ts1, ts2, ts_padpad, ts_match;
    reg        ts_link_eq, ts_lane_eq, ts_lane_eq_entry;   // vs link_num / lane_num / lane_at_entry
    always @(posedge clk) begin
        os_ts_valid <= i_os_ts_valid && !rst; os_eios <= i_os_eios && !rst; os_idle2 <= i_os_idle2 && !rst;
        os_ts2 <= i_os_ts2; os_ts_inv <= i_os_ts_inv; os_link_pad <= i_os_link_pad; os_lane_pad <= i_os_lane_pad;
        os_link <= i_os_link; os_lane <= i_os_lane; os_nfts <= i_os_nfts; os_rate <= i_os_rate; os_ctrl <= i_os_ctrl;
        ts1 <= i_os_ts_valid && !i_os_ts2 && !rst;
        ts2 <= i_os_ts_valid && i_os_ts2 && !rst;
        ts_padpad <= i_os_link_pad && i_os_lane_pad;
        ts_match  <= !i_os_link_pad && !i_os_lane_pad && i_os_link == link_num && i_os_lane == lane_num;
        ts_link_eq <= (i_os_link == link_num);
        ts_lane_eq <= (i_os_lane == lane_num);
        ts_lane_eq_entry <= (i_os_lane == lane_at_entry);
    end
    wire rx_spd_chg  = os_rate[7];
    wire rx_gen2     = os_rate[2];
    wire both_gen2   = (MAX_RATE >= 2) && rx_gen2;

    // state change; the per-state counters are cleared one clock later from the
    // registered t_clr (keeps the deep transition conditions off their reset cones)
    task goto;
        input [5:0] s;
        begin
            st <= s; sub <= 3'd0; t_clr <= 1'b1;
        end
    endtask

    // registered threshold flags (one clock behind the counters; the counters only move
    // on received/transmitted ordered sets, many clocks apart)
    reg a_ge2, a_ge4, a_ge8, b_ge2, b_ge8, ta_ge8, ta_ge16, ta_ge32, ts_ge1024, ts_ge64;
    always @(posedge clk) begin
        a_ge2 <= cnt_a >= 4'd2; a_ge4 <= cnt_a >= 4'd4; a_ge8 <= cnt_a >= 4'd8;
        b_ge2 <= cnt_b >= 4'd2; b_ge8 <= cnt_b >= 4'd8;
        ta_ge8 <= tx_after >= 6'd8; ta_ge16 <= tx_after >= 6'd16; ta_ge32 <= tx_after >= 6'd32;
        ts_ge1024 <= ts_tx_cnt >= 11'd1024; ts_ge64 <= ts_tx_cnt >= 11'd64;
    end
    wire cnt_fresh = !t_clr && !t_clr_d;     // counters were cleared on state entry
    // registered Recovery.RcvrCfg rate decisions (rx_rate_rec only changes on received TS)
    reg  rr_spd, rr_nospd;
    always @(posedge clk) begin
        rr_spd   <= rx_rate_rec[7] && (cur_gen2 || ((MAX_RATE >= 2) && rx_rate_rec[2]));
        rr_nospd <= !rx_rate_rec[7] || (!cur_gen2 && !((MAX_RATE >= 2) && rx_rate_rec[2]));
    end

    // saturating increment helpers
    function [3:0] inc4(input [3:0] v); inc4 = (v == 4'hF) ? v : v + 1'b1; endfunction

    always @(posedge clk) begin
        t_clr <= 1'b0;
        eieos_clr <= 1'b0;
        if (rst) begin
            st <= ST_DQUIET; sub <= 3'd0; t_clr <= 1'b1;
            pipe_txdetectrx <= 1'b0; pipe_powerdown <= 2'b10; pipe_rate <= 1'b0; pipe_rxpolarity <= 1'b0;
            tx_mode <= M_EIDLE; tx_link <= 8'd0; tx_link_pad <= 1'b1; tx_lane <= 8'd0; tx_lane_pad <= 1'b1;
            tx_rate <= my_rates; tx_ctrl <= 8'd0; scramble_en <= 1'b1;
            link_up <= 1'b0; in_l0 <= 1'b0; ltssm_state <= ST_DQUIET; hot_reset <= 1'b0; link_training <= 1'b0;
            partner_gen2 <= 1'b0; link_num <= 8'd0; lane_num <= 8'd0; rcvr_err_ltssm <= 1'b0;
            ts_tx_cnt <= 11'd0; tx_after <= 6'd0; rx_first <= 1'b0; cnt_a <= 4'd0; cnt_b <= 4'd0;
            directed_speed_change <= 1'b0; changed_speed_recovery <= 1'b0; successful_speed_neg <= 1'b0;
            idle_to_rlock <= 1'b0; rx_ei_seen <= 1'b0; rx_ts2_seen <= 1'b0; cur_gen2 <= 1'b0; t_cyc <= 12'd0;
            rate_target <= 1'b0; hot_from_rx <= 1'b0; dis_scr_seen <= 1'b0; rx_rate_rec <= 8'd0;
        end else begin
            ltssm_state <= st;
            sub_d <= sub;
            rs_go <= ei_time_ok && sub_d == 3'd4 && sub == 3'd4 && st == ST_RSPEED;
            ei_time_ok <= (successful_speed_neg && t_cyc >= (pipe_rate ? 12'd200 : 12'd100)) ||
                          (!successful_speed_neg && t_cyc >= (pipe_rate ? 12'd1500 : 12'd750));
            in_l0 <= (st == ST_L0);
            hot_reset <= (st == ST_HOTRST);
            link_training <= (st >= ST_CLWSTART && st <= ST_CIDLE) || (st >= ST_RLOCK && st <= ST_RIDLE);
            if (t_cyc != 12'hFFF) t_cyc <= t_cyc + 1'b1;
            if (tx_ts_done) ts_tx_cnt <= (ts_tx_cnt == 11'h7FF) ? ts_tx_cnt : ts_tx_cnt + 1'b1;
            if (os_eios || pipe_rxelecidle) rx_ei_seen <= 1'b1;
            if (ts2) rx_ts2_seen <= 1'b1;
            if (tx_link_pad) ; // keep lint quiet

            case (st)
            // ------------------------------------------------------------ Detect
            ST_DQUIET: begin
                tx_mode <= M_EIDLE; pipe_powerdown <= 2'b10; pipe_txdetectrx <= 1'b0;
                link_up <= 1'b0; directed_speed_change <= 1'b0; idle_to_rlock <= 1'b0;
                changed_speed_recovery <= 1'b0; pipe_rxpolarity <= 1'b0; scramble_en <= 1'b1;
                tx_link_pad <= 1'b1; tx_lane_pad <= 1'b1; tx_ctrl <= 8'd0; partner_gen2 <= 1'b0;
                case (sub)
                3'd0: begin
                    if (pipe_rate) begin
                        pipe_rate <= 1'b0; sub <= 3'd1;           // back to 2.5 GT/s
                    end else sub <= 3'd2;
                end
                3'd1: if (pipe_phystatus) begin sub <= 3'd2; t_clr <= 1'b1; end
                default: begin
                    cur_gen2 <= 1'b0;
                    if (to12 || (!pipe_rxelecidle && to1))
                        goto(ST_DACTIVE);
                end
                endcase
            end
            ST_DACTIVE: begin
                tx_mode <= M_EIDLE;
                case (sub)
                3'd0: begin pipe_txdetectrx <= 1'b1; sub <= 3'd1; end
                3'd1: if (pipe_phystatus) begin
                    pipe_txdetectrx <= 1'b0;
                    if (pipe_rxstatus == 3'b011) begin
                        goto(ST_PACTIVE);
                    end else goto(ST_DQUIET);
                end else if (to1000) begin
                    pipe_txdetectrx <= 1'b0; goto(ST_DQUIET);
                end
                default: sub <= 3'd0;
                endcase
            end
            // ------------------------------------------------------------ Polling
            ST_PACTIVE: begin
                tx_link_pad <= 1'b1; tx_lane_pad <= 1'b1; tx_ctrl <= 8'd0; tx_rate <= my_rates;
                case (sub)
                3'd0: begin pipe_powerdown <= 2'b00; sub <= 3'd1; end    // P1 -> P0
                3'd1: if (pipe_phystatus) sub <= 3'd2;
                      else if (to100) sub <= 3'd2;
                default: begin
                    tx_mode <= M_TS1;
                    if (os_ts_valid) begin
                        if (os_ts_inv) pipe_rxpolarity <= ~pipe_rxpolarity;
                        if (ts_padpad && (os_ts2 || !os_ctrl[4] || os_ctrl[2]) && !os_ts_inv)
                            cnt_a <= inc4(cnt_a);
                        else cnt_a <= 4'd0;
                    end
                    if (a_ge8 && cnt_fresh && (FAST_TRAIN ? ts_ge64 : ts_ge1024)) goto(ST_PCONFIG);
                    else if (to24) begin
                        if (a_ge8 && cnt_fresh) goto(ST_PCONFIG); else goto(ST_DQUIET);
                    end
                end
                endcase
            end
            ST_PCONFIG: begin
                tx_mode <= M_TS2;
                if (ts2 && ts_padpad) begin cnt_a <= inc4(cnt_a); rx_first <= 1'b1; end
                else if (os_ts_valid) cnt_a <= 4'd0;
                if (rx_first && tx_ts_done && tx_after != 6'h3F) tx_after <= tx_after + 1'b1;
                if (a_ge8 && ta_ge16 && cnt_fresh) goto(ST_CLWSTART);
                else if (to48) goto(ST_DQUIET);
            end
            // ------------------------------------------------------------ Configuration
            ST_CLWSTART: begin
                tx_mode <= M_TS1; tx_link_pad <= 1'b1; tx_lane_pad <= 1'b1; tx_rate <= my_rates;
                if (ts1 && !os_link_pad && os_lane_pad) begin
                    if (cnt_a != 0 && ts_link_eq) cnt_a <= inc4(cnt_a);
                    else cnt_a <= 4'd1;
                    link_num <= os_link;
                end else if (os_ts_valid) cnt_a <= 4'd0;
                if (ts1 && os_ctrl[1]) cnt_b <= inc4(cnt_b); else if (os_ts_valid) cnt_b <= 4'd0;
                if (b_ge2 && cnt_fresh) goto(ST_DISABLED);
                else if (a_ge2 && cnt_fresh) begin
                    tx_link <= link_num; tx_link_pad <= 1'b0;
                    goto(ST_CLWACCEPT);
                end else if (to24) goto(ST_DQUIET);
            end
            ST_CLWACCEPT: begin
                tx_mode <= M_TS1;
                if (ts1 && !os_link_pad && ts_link_eq && !os_lane_pad) begin
                    if (cnt_a != 0 && ts_lane_eq) cnt_a <= inc4(cnt_a); else cnt_a <= 4'd1;
                    lane_num <= os_lane;
                end else if (os_ts_valid) cnt_a <= 4'd0;
                if (ts1 && ts_padpad) cnt_b <= inc4(cnt_b); else if (os_ts_valid) cnt_b <= 4'd0;
                if (a_ge2 && cnt_fresh) begin
                    tx_lane <= lane_num; tx_lane_pad <= 1'b0; lane_at_entry <= lane_num;
                    goto(ST_CLNWAIT);
                end else if ((b_ge2 && cnt_fresh) || to2ms) goto(ST_DQUIET);
            end
            ST_CLNWAIT: begin
                tx_mode <= M_TS1;
                if (ts1 && !os_lane_pad && !ts_lane_eq_entry && !os_link_pad) cnt_a <= inc4(cnt_a);
                else if (ts2) cnt_a <= inc4(cnt_a);
                else if (os_ts_valid) cnt_a <= 4'd0;
                if (ts1 && ts_padpad) cnt_b <= inc4(cnt_b); else if (os_ts_valid) cnt_b <= 4'd0;
                if (a_ge2 && cnt_fresh) goto(ST_CLNACCEPT);
                else if ((b_ge2 && cnt_fresh) || to2ms) goto(ST_DQUIET);
            end
            ST_CLNACCEPT: begin
                tx_mode <= M_TS1;
                if (ts2 && ts_match) cnt_a <= inc4(cnt_a); else if (os_ts_valid) cnt_a <= 4'd0;
                if (ts1 && !os_link_pad && ts_link_eq && !os_lane_pad && !ts_lane_eq) begin
                    if (cnt_b != 0) cnt_b <= inc4(cnt_b); else cnt_b <= 4'd1;
                    lane_num <= os_lane;
                end else if (os_ts_valid && !(ts2 && ts_match)) cnt_b <= 4'd0;
                if (a_ge2 && cnt_fresh) goto(ST_CCOMPLETE);
                else if (b_ge2 && cnt_fresh) begin
                    tx_lane <= lane_num; lane_at_entry <= lane_num; goto(ST_CLNWAIT);
                end else if (to2ms) goto(ST_DQUIET);
            end
            ST_CCOMPLETE: begin
                tx_mode <= M_TS2; tx_rate <= my_rates_b6;
                if (ts2 && ts_match) begin
                    if (cnt_a != 0 && os_rate == rx_rate_rec) cnt_a <= inc4(cnt_a); else cnt_a <= 4'd1;
                    rx_rate_rec <= os_rate;
                    rx_first <= 1'b1;
                    if (os_ctrl[3]) cnt_b <= inc4(cnt_b); else cnt_b <= 4'd0;
                end else if (os_ts_valid) cnt_a <= 4'd0;
                if (rx_first && tx_ts_done && tx_after != 6'h3F) tx_after <= tx_after + 1'b1;
                if (a_ge8 && ta_ge16 && cnt_fresh) begin
                    partner_gen2 <= rx_rate_rec[2];
                    if (b_ge2) scramble_en <= 1'b0;
                    changed_speed_recovery <= 1'b0;
                    goto(ST_CIDLE);
                end else if (to2ms) goto(ST_DQUIET);
            end
            ST_CIDLE: begin
                tx_mode <= M_IDLE; link_up <= 1'b1;
                if (os_idle2) begin cnt_a <= inc4(cnt_a); rx_first <= 1'b1; end
                else if (os_ts_valid) cnt_a <= 4'd0;
                if (rx_first && tx_idle_pair && tx_after != 6'h3F) tx_after <= tx_after + 1'b1;
                if (a_ge4 && ta_ge8 && cnt_fresh) goto(ST_L0);
                else if (to2ms) begin
                    if (!idle_to_rlock) begin idle_to_rlock <= 1'b1; goto(ST_RLOCK); end
                    else goto(ST_DQUIET);
                end
            end
            // ------------------------------------------------------------ L0
            ST_L0: begin
                tx_mode <= M_DATA; link_up <= 1'b1; idle_to_rlock <= 1'b0;
                tx_ctrl <= 8'd0;
                if (os_ts_valid) begin
                    if (ts1 && os_rate[7] && both_gen2) ; // speed change request handled in RcvrLock
                    goto(ST_RLOCK);
                end else if (retrain_req) goto(ST_RLOCK);
            end
            // ------------------------------------------------------------ Recovery
            ST_RLOCK: begin
                tx_mode <= M_TS1; tx_link_pad <= 1'b0; tx_lane_pad <= 1'b0;
                rx_ei_seen <= 1'b0;            // collect the partner's EIOS from RcvrCfg on
                tx_link <= link_num; tx_lane <= lane_num;
                tx_rate <= {directed_speed_change, my_rates_b6[6:0]};
                successful_speed_neg <= 1'b0;
                if (os_ts_valid && ts_match) begin
                    rx_first <= 1'b1;
                    if (os_rate[7] == directed_speed_change) cnt_a <= inc4(cnt_a); else cnt_a <= 4'd0;
                    if (ts1 && os_rate[7] && both_gen2) begin
                        cnt_b <= inc4(cnt_b);
                        if (cnt_b >= 4'd7 && !directed_speed_change) begin
                            directed_speed_change <= 1'b1; cnt_a <= 4'd0;
                        end
                    end else cnt_b <= 4'd0;
                end else if (os_ts_valid) begin
                    cnt_a <= 4'd0; cnt_b <= 4'd0;
                end
                if (a_ge8 && cnt_fresh) goto(ST_RCFG);
                else if (to24) begin
                    if (cur_gen2 && !changed_speed_recovery) begin
                        rate_target <= 1'b0; goto(ST_RSPEED);
                    end else if (changed_speed_recovery) begin
                        rate_target <= 1'b0; goto(ST_RSPEED);
                    end else if (rx_first) begin
                        directed_speed_change <= 1'b0; goto(ST_CLWSTART);
                    end else goto(ST_DQUIET);
                end
            end
            ST_RCFG: begin
                tx_mode <= M_TS2;
                tx_rate <= {directed_speed_change, my_rates_b6[6:0]};
                if (ts2 && ts_match) begin
                    if (cnt_a != 0 && os_rate == rx_rate_rec) cnt_a <= inc4(cnt_a); else cnt_a <= 4'd1;
                    rx_rate_rec <= os_rate;
                    if (!rx_ts2_seen) eieos_clr <= 1'b1;
                    if (!rx_first) rx_first <= 1'b1;
                end else if (os_ts_valid) cnt_a <= 4'd0;
                if (ts1 && !ts_match) cnt_b <= inc4(cnt_b); else if (os_ts_valid) cnt_b <= 4'd0;
                if (os_ts_valid && !rx_first) rx_first <= 1'b1;
                if (rx_first && tx_ts_done && tx_after != 6'h3F) tx_after <= tx_after + 1'b1;
                if (hot_from_rx) ;
                if (a_ge8 && cnt_fresh && rr_spd && ta_ge32) begin
                    successful_speed_neg <= 1'b1;
                    partner_gen2 <= rx_rate_rec[2];
                    rate_target <= (MAX_RATE >= 2) && rx_rate_rec[2];
                    goto(ST_RSPEED);
                end else if (a_ge8 && cnt_fresh && rr_spd && os_eios) begin
                    // the partner already went to Recovery.Speed (it sent its 32 TS2s first)
                    successful_speed_neg <= 1'b1;
                    partner_gen2 <= rx_rate_rec[2];
                    rate_target <= (MAX_RATE >= 2) && rx_rate_rec[2];
                    goto(ST_RSPEED);
                end else if (a_ge8 && ta_ge16 && cnt_fresh && rr_nospd) begin
                    partner_gen2 <= rx_rate_rec[2];
                    directed_speed_change <= 1'b0; changed_speed_recovery <= 1'b0;
                    goto(ST_RIDLE);
                end else if (b_ge8 && ta_ge16 && cnt_fresh) begin
                    directed_speed_change <= 1'b0; changed_speed_recovery <= 1'b0;
                    goto(ST_CLWSTART);
                end else if (!rx_ts2_seen && (os_eios || (pipe_rxelecidle && to2)) &&
                             (changed_speed_recovery || cur_gen2)) begin
                    rate_target <= 1'b0; goto(ST_RSPEED);
                end else if (to48) goto(ST_DQUIET);
            end
            ST_RSPEED: begin
                directed_speed_change <= 1'b0;
                case (sub)
                3'd0: begin
                    // send EIOS (1 at 2.5 GT/s, 2 at 5 GT/s) then electrical idle
                    tx_mode <= M_EIOS; rx_ei_seen <= rx_ei_seen | os_eios;
                    if (tx_eios_done) begin
                        if (cnt_a >= (cur_gen2 ? 4'd1 : 4'd0)) begin tx_mode <= M_EIDLE; sub <= 3'd1; end
                        cnt_a <= inc4(cnt_a);
                    end
                end
                3'd1: begin
                    tx_mode <= M_EIDLE;
                    if (rx_ei_seen || to20) begin sub <= 3'd2; t_cyc <= 12'd0; end
                end
                3'd2: begin
                    if (pipe_rate != rate_target) begin
                        pipe_rate <= rate_target; sub <= 3'd3;
                    end else sub <= 3'd4;
                    t_cyc <= 12'd0;
                end
                3'd3: if (pipe_phystatus) begin sub <= 3'd4; t_cyc <= 12'd0; end
                default: begin
                    cur_gen2 <= pipe_rate;
                    // >= 800 ns after successful negotiation, >= 6 us otherwise
                    if (rs_go) begin
                        changed_speed_recovery <= successful_speed_neg ? 1'b1 : 1'b0;
                        rx_ei_seen <= 1'b0;
                        goto(ST_RLOCK);
                    end
                end
                endcase
                if (to48) goto(ST_DQUIET);
            end
            ST_RIDLE: begin
                tx_mode <= M_IDLE;
                if (os_idle2) begin cnt_a <= inc4(cnt_a); rx_first <= 1'b1; end
                else if (os_ts_valid) cnt_a <= 4'd0;
                if (ts1 && os_ctrl[0]) cnt_b <= inc4(cnt_b);
                else if (ts1 && os_lane_pad) cnt_b <= 4'd0;
                if (rx_first && tx_idle_pair && tx_after != 6'h3F) tx_after <= tx_after + 1'b1;
                if (b_ge2 && cnt_fresh) goto(ST_HOTRST);
                else if (ts1 && os_ctrl[1]) goto(ST_DISABLED);
                else if (ts1 && os_lane_pad) goto(ST_CLWSTART);
                else if (a_ge4 && ta_ge8 && cnt_fresh) goto(ST_L0);
                else if (to2ms) begin
                    if (!idle_to_rlock) begin idle_to_rlock <= 1'b1; goto(ST_RLOCK); end
                    else goto(ST_DQUIET);
                end
            end
            // ------------------------------------------------------------ Hot Reset / Disabled
            ST_HOTRST: begin
                link_up <= 1'b0;
                tx_mode <= M_TS1; tx_ctrl <= 8'h01;
                if (ts1 && os_ctrl[0]) t_clr <= 1'b1;      // stay while hot reset TS1s arrive
                if (tohot) begin tx_ctrl <= 8'd0; goto(ST_DQUIET); end
            end
            ST_DISABLED: begin
                link_up <= 1'b0;
                case (sub)
                3'd0: begin tx_mode <= M_EIOS; if (tx_eios_done) begin tx_mode <= M_EIDLE; sub <= 3'd1; end end
                3'd1: begin tx_mode <= M_EIDLE; if (pipe_rxelecidle) sub <= 3'd2; end
                default: begin tx_mode <= M_EIDLE; if (!pipe_rxelecidle) goto(ST_DQUIET); end
                endcase
            end
            default: goto(ST_DQUIET);
            endcase
            if (t_clr) begin
                ts_tx_cnt <= 11'd0; tx_after <= 6'd0; rx_first <= 1'b0;
                cnt_a <= 4'd0; cnt_b <= 4'd0; t_cyc <= 12'd0; rx_ts2_seen <= 1'b0;
            end
        end
    end
endmodule
