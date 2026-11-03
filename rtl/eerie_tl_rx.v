// SPDX-License-Identifier: CERN-OHL-P
// pci_eerie: Transaction Layer receive side (user clock domain)
//
//  DLL stream -> RX buffer RAM (MIM RX, speculative write, commit/rewind)
//             -> descriptor FIFO -> read engine -> { TRN RX (user) | internal handler }
//
//  The internal handler executes config requests (CfgRd0/CfgWr0), generates
//  Unsupported Request completions, and decodes messages.
`timescale 1ns / 1ps
module eerie_tl_rx #(
    parameter RXB_AW   = 10,          // RX buffer depth 2**RXB_AW beats
    parameter RXB_RLAT = 2,           // RX buffer read latency
    parameter [31:0] BAR0 = 32'hFFFFF000,
    parameter [31:0] BAR1 = 32'h00000000,
    parameter [31:0] BAR2 = 32'h00000000,
    parameter [31:0] BAR3 = 32'h00000000,
    parameter [31:0] BAR4 = 32'h00000000,
    parameter [31:0] BAR5 = 32'h00000000,
    parameter [31:0] EXPANSION_ROM = 32'h00000000,
    parameter [7:0]  INIT_PH = 8'd32,  parameter [11:0] INIT_PD = 12'd437,
    parameter [7:0]  INIT_NPH = 8'd12, parameter [11:0] INIT_NPD = 12'd24,
    parameter [7:0]  INIT_CPLH = 8'd36, parameter [11:0] INIT_CPLD = 12'd461,
    parameter        CPL_INFINITE = 1
) (
    input             clk,
    input             rst,              // link reset

    // from the DLL
    input             tlrx_v,
    input      [63:0] tlrx_d,
    input             tlrx_sop,
    input             tlrx_half,
    input             tlrx_end,
    input             tlrx_ok,

    // RX buffer RAM (MIM RX)
    output reg        rxb_we,
    output reg [12:0] rxb_waddr,
    output reg [67:0] rxb_wdata,
    output reg        rxb_re,
    output reg [12:0] rxb_raddr,
    input      [67:0] rxb_rdata,

    // config space control / BARs
    input      [15:0] command,
    input      [31:0] bar0, bar1, bar2, bar3, bar4, bar5, rom_bar,
    input             rom_en,

    // TRN RX
    output     [63:0] trn_rd,
    output            trn_rrem,         // 1: both DWs valid
    output            trn_rsof,
    output            trn_reof,
    output            trn_rsrc_rdy,
    input             trn_rdst_rdy,
    output            trn_rerrfwd,
    output     [7:0]  trn_rbar_hit,

    // config space access
    output reg        cfg_req_v,
    output reg        cfg_req_wr,
    output reg [9:0]  cfg_req_dwaddr,
    output reg [3:0]  cfg_req_be,
    output reg [31:0] cfg_req_wdata,
    input      [31:0] cfg_rd_data,      // valid one cycle after cfg_req_v
    output reg [7:0]  bus_num,
    output reg [4:0]  dev_num,

    // internal completion request (to TL TX)
    output reg        icpl_v,
    output reg [2:0]  icpl_status,
    output reg        icpl_hasd,
    output reg [31:0] icpl_data,        // register order (byte 0 in [7:0])
    output reg [15:0] icpl_reqid,
    output reg [7:0]  icpl_tag,
    output reg [2:0]  icpl_tc,
    output reg [1:0]  icpl_attr,
    output reg [6:0]  icpl_laddr,
    output reg [11:0] icpl_bcnt,
    input             icpl_ack,

    // message / error events
    output reg        msg_received,
    output reg [15:0] msg_data,
    output reg        msg_pme_to,
    output reg        msg_unlock,
    output reg        msg_setslot,
    output reg [9:0]  msg_slot_pwr,
    output reg        err_ur,           // unsupported request detected
    output reg        err_ur_np,        // ... that was non-posted (completion sent)
    output reg        err_malformed,
    output reg        err_overflow,
    output reg        err_poisoned,

    // flow control credits to advertise
    output reg [7:0]  fc_ph,  output reg [11:0] fc_pd,
    output reg [7:0]  fc_nph, output reg [11:0] fc_npd,
    output reg [7:0]  fc_cplh,output reg [11:0] fc_cpld,
    output reg [2:0]  fc_upd_req
);
    localparam DEPTH = 1 << RXB_AW;
    localparam R_USER = 3'd0, R_CFG = 3'd1, R_UR = 3'd2, R_MSG = 3'd3, R_DROP = 3'd4;

    // ---------------- BAR helpers ----------------
    function [31:0] bmask; input [31:0] p;
        bmask = (p == 0) ? 32'd0 : p[0] ? {p[31:2], 2'b00} : {p[31:4], 4'b0000};
    endfunction
    function is_mem32; input [31:0] p; is_mem32 = (p != 0) && !p[0] && p[2:1] == 2'b00; endfunction
    function is_mem64; input [31:0] p; is_mem64 = (p != 0) && !p[0] && p[2:1] == 2'b10; endfunction
    function is_io;    input [31:0] p; is_io    = (p != 0) && p[0]; endfunction
    localparam [31:0] MROM = (EXPANSION_ROM == 0) ? 32'd0 : {EXPANSION_ROM[31:11], 11'd0};

    // =====================================================================
    // write side
    // =====================================================================
    reg [RXB_AW:0] wp, w_start, rp;
    reg [10:0]     w_nbeats;
    reg [31:0]     h0, h1, h2, h3;
    reg            w_half, w_in, w_ovf;
    reg            end_q, ok_q;

    wire [RXB_AW:0] used = wp - rp;
    wire            full = used[RXB_AW];

    always @(posedge clk) begin
        rxb_we <= 1'b0; end_q <= 1'b0; err_overflow <= 1'b0;
        if (rst) begin
            wp <= 0; w_start <= 0; w_in <= 1'b0; w_ovf <= 1'b0;
        end else begin
            if (tlrx_v) begin
                if (tlrx_sop) begin
                    w_start <= wp; w_nbeats <= 11'd1; h0 <= tlrx_d[63:32]; h1 <= tlrx_d[31:0];
                    h2 <= 32'd0; h3 <= 32'd0; w_in <= 1'b1; w_ovf <= full; w_half <= tlrx_half;
                end else begin
                    w_nbeats <= w_nbeats + 1'b1; w_half <= tlrx_half;
                    if (w_nbeats == 11'd1) begin h2 <= tlrx_d[63:32]; h3 <= tlrx_d[31:0]; end
                    if (full) w_ovf <= 1'b1;
                end
                if (!full) begin
                    rxb_we <= 1'b1; rxb_waddr <= wp[RXB_AW-1:0]; rxb_wdata <= {4'd0, tlrx_d};
                    wp <= wp + 1'b1;
                end
            end
            if (tlrx_end) begin
                end_q <= 1'b1; w_in <= 1'b0;
                ok_q <= tlrx_ok && !(w_ovf || (tlrx_v && full));
                if (!tlrx_ok || w_ovf || (tlrx_v && full)) begin
                    wp <= w_start;              // discard (a new TLP may start next cycle)
                    if (tlrx_ok) err_overflow <= 1'b1;
                end
            end
        end
    end

    // ---------------- classification (valid in the end_q cycle) ----------------
    wire [2:0] fmt  = h0[31:29];
    wire [4:0] typ  = h0[28:24];
    wire [9:0] len  = h0[9:0];
    wire       is4  = fmt[0];
    wire       hasd = fmt[1];
    wire [31:0] a_lo = is4 ? h3 : h2;
    wire [31:0] a_hi = is4 ? h2 : 32'd0;
    wire [10:0] len_dw = (len == 10'd0) ? 11'd1024 : {1'b0, len};
    wire [11:0] exp_dw = (is4 ? 12'd4 : 12'd3) + (hasd ? {1'b0, len_dw} : 12'd0);
    wire [11:0] got_dw = {w_nbeats, 1'b0} - (w_half ? 12'd1 : 12'd0);

    wire t_mem  = (typ == 5'b00000);
    wire t_mrdlk= (typ == 5'b00001) && !hasd;
    wire t_io   = (typ == 5'b00010);
    wire t_cfg0 = (typ == 5'b00100);
    wire t_cfg1 = (typ == 5'b00101);
    wire t_cpl  = (typ[4:1] == 4'b0101);
    wire t_msg  = (typ[4:3] == 2'b10);
    wire t_atom = (typ == 5'b01100 || typ == 5'b01101 || typ == 5'b01110) && hasd;

    wire mem_en = command[1], io_en = command[0];
    reg [6:0] hit;
    always @(*) begin
        hit = 7'd0;
        if (t_mem && mem_en) begin
            if (is_mem32(BAR0) && a_hi == 0 && (a_lo & bmask(BAR0)) == bar0) hit[0] = 1'b1;
            if (is_mem64(BAR0) && ({a_hi, a_lo} & {BAR1, bmask(BAR0)}) == {bar1, bar0}) hit[1:0] = 2'b11;
            if (is_mem32(BAR1) && !is_mem64(BAR0) && a_hi == 0 && (a_lo & bmask(BAR1)) == bar1) hit[1] = 1'b1;
            if (is_mem32(BAR2) && a_hi == 0 && (a_lo & bmask(BAR2)) == bar2) hit[2] = 1'b1;
            if (is_mem64(BAR2) && ({a_hi, a_lo} & {BAR3, bmask(BAR2)}) == {bar3, bar2}) hit[3:2] = 2'b11;
            if (is_mem32(BAR3) && !is_mem64(BAR2) && a_hi == 0 && (a_lo & bmask(BAR3)) == bar3) hit[3] = 1'b1;
            if (is_mem32(BAR4) && a_hi == 0 && (a_lo & bmask(BAR4)) == bar4) hit[4] = 1'b1;
            if (is_mem64(BAR4) && ({a_hi, a_lo} & {BAR5, bmask(BAR4)}) == {bar5, bar4}) hit[5:4] = 2'b11;
            if (is_mem32(BAR5) && !is_mem64(BAR4) && a_hi == 0 && (a_lo & bmask(BAR5)) == bar5) hit[5] = 1'b1;
            if (!hasd && rom_en && MROM != 0 && a_hi == 0 && (a_lo & MROM) == rom_bar) hit[6] = 1'b1;
        end
        if (t_io && io_en) begin
            if (is_io(BAR0) && (a_lo & bmask(BAR0)) == bar0) hit[0] = 1'b1;
            if (is_io(BAR1) && (a_lo & bmask(BAR1)) == bar1) hit[1] = 1'b1;
            if (is_io(BAR2) && (a_lo & bmask(BAR2)) == bar2) hit[2] = 1'b1;
            if (is_io(BAR3) && (a_lo & bmask(BAR3)) == bar3) hit[3] = 1'b1;
            if (is_io(BAR4) && (a_lo & bmask(BAR4)) == bar4) hit[4] = 1'b1;
            if (is_io(BAR5) && (a_lo & bmask(BAR5)) == bar5) hit[5] = 1'b1;
        end
    end

    reg [2:0] route;
    reg [1:0] ctype;        // 0 P, 1 NP, 2 Cpl
    reg       malformed;
    always @(*) begin
        malformed = (got_dw < exp_dw) || (fmt[2]);
        if (t_cpl) ctype = 2'd2;
        else if (t_msg || (t_mem && hasd)) ctype = 2'd0;
        else ctype = 2'd1;
        if (malformed) route = R_DROP;
        else if (t_mem && !t_mrdlk) route = (hit != 0) ? R_USER : (hasd ? R_DROP : R_UR);
        else if (t_mrdlk) route = R_UR;
        else if (t_io) route = (hit != 0) ? R_USER : R_UR;
        else if (t_cfg0) route = R_CFG;
        else if (t_cpl) route = R_USER;
        else if (t_msg) route = R_MSG;
        else if (t_cfg1 || t_atom) route = R_UR;
        else route = hasd ? R_DROP : R_UR;
    end
    wire [9:0] dcred = hasd ? ((len == 10'd0) ? 10'd256 : (({1'b0, len} + 11'd3) >> 2)) : 10'd0;

    // ---------------- descriptor FIFO ----------------
    // {dcred[9:0], ctype[1:0], route[2:0], hit[6:0], half, nbeats[10:0], start[RXB_AW:0]}
    localparam DSW = 10 + 2 + 3 + 7 + 1 + 11 + RXB_AW + 1;
    reg [DSW-1:0] dfifo [0:127];
    reg [7:0] df_w, df_r;
    wire df_empty = (df_w == df_r);
    // classification registered in the end_q cycle, descriptor written one clock later
    reg           cl_v;
    reg [DSW-1:0] cl_desc;
    reg           cl_malformed, cl_ur, cl_poisoned;
    always @(posedge clk) begin
        err_malformed <= 1'b0; err_ur <= 1'b0; err_poisoned <= 1'b0;
        cl_v <= 1'b0;
        if (rst) df_w <= 8'd0;
        else begin
            if (end_q && ok_q) begin
                cl_v <= 1'b1;
                cl_desc <= {dcred, ctype, route, hit, w_half, w_nbeats, w_start};
                cl_malformed <= malformed;
                cl_ur <= (route == R_UR || (route == R_DROP && !malformed));
                cl_poisoned <= h0[14];
            end
            if (cl_v) begin
                dfifo[df_w[6:0]] <= cl_desc;
                df_w <= df_w + 1'b1;
                err_malformed <= cl_malformed; err_ur <= cl_ur; err_poisoned <= cl_poisoned;
            end
        end
    end

    // =====================================================================
    // read engine: RAM -> rdq (small FIFO), credits returned per TLP
    // =====================================================================
    reg  [DSW-1:0] cur_d;
    wire [RXB_AW:0] d_start = cur_d[RXB_AW:0];
    wire [10:0]     d_nb    = cur_d[RXB_AW+11:RXB_AW+1];
    wire            d_half  = cur_d[RXB_AW+12];
    wire [6:0]      d_hit   = cur_d[RXB_AW+19:RXB_AW+13];
    wire [2:0]      d_route = cur_d[RXB_AW+22:RXB_AW+20];
    wire [1:0]      d_ctype = cur_d[RXB_AW+24:RXB_AW+23];
    wire [9:0]      d_dcred = cur_d[RXB_AW+34:RXB_AW+25];

    // rdq entry: {route[2:0], hit[6:0], first, last, half, data[63:0]}
    localparam QW = 3 + 7 + 3 + 64;
    reg [QW-1:0] rdq [0:7];
    reg [3:0]    q_w, q_r;
    wire [3:0]   q_cnt = q_w - q_r;
    reg          r_busy;
    reg [10:0]   r_left, r_issued;
    reg [RXB_AW:0] r_addr;
    reg [RXB_RLAT:0] r_pipe;
    reg [12:0]   r_meta [0:RXB_RLAT];     // {route, hit, half, first, last}
    reg [3:0]    inflight;
    wire         q_pop;
    integer      k;

    always @(*) begin
        inflight = 4'd0;
        if (r_pipe[0]) inflight = inflight + 1'b1;
        if (RXB_RLAT >= 1 && r_pipe[1]) inflight = inflight + 1'b1;
        if (RXB_RLAT >= 2 && r_pipe[2]) inflight = inflight + 1'b1;
    end
    reg room_r;              // registered: rdq has room for another read (one clock conservative)
    always @(posedge clk) room_r <= (q_cnt + inflight) < 4'd4;

    always @(posedge clk) begin
        rxb_re <= 1'b0;
        fc_upd_req <= 3'b000;
        r_pipe       <= {r_pipe[RXB_RLAT-1:0], 1'b0};
        for (k = 1; k <= RXB_RLAT; k = k + 1) r_meta[k] <= r_meta[k-1];
        if (rst) begin
            df_r <= 8'd0; r_busy <= 1'b0; rp <= 0; q_w <= 4'd0; r_pipe <= 0;
            fc_ph <= INIT_PH; fc_pd <= INIT_PD; fc_nph <= INIT_NPH; fc_npd <= INIT_NPD;
            fc_cplh <= CPL_INFINITE ? 8'd0 : INIT_CPLH; fc_cpld <= CPL_INFINITE ? 12'd0 : INIT_CPLD;
        end else begin
            if (!r_busy) begin
                if (!df_empty) begin
                    cur_d <= dfifo[df_r[6:0]]; df_r <= df_r + 1'b1; r_busy <= 1'b1;
                    r_left <= 11'd0; r_issued <= 11'd0;
                end
            end else begin
                if (r_issued == 11'd0 && r_left == 11'd0) begin
                    // first cycle with the descriptor loaded
                    r_addr <= d_start; r_left <= d_nb; r_issued <= 11'd1;
                end else if (r_left != 11'd0) begin
                    if (room_r) begin
                        rxb_re <= 1'b1; rxb_raddr <= r_addr[RXB_AW-1:0];
                        r_addr <= r_addr + 1'b1; r_left <= r_left - 1'b1;
                        r_pipe[0] <= 1'b1;
                        r_meta[0] <= {d_route, d_hit, d_half, (r_left == d_nb), (r_left == 11'd1)};
                        if (r_left == 11'd1) begin
                            // whole TLP read out of the RAM: free it and return credits
                            rp <= r_addr + 1'b1;
                            r_busy <= 1'b0;
                            case (d_ctype)
                            2'd0: begin fc_ph <= fc_ph + 1'b1; fc_pd <= fc_pd + d_dcred; fc_upd_req[0] <= 1'b1; end
                            2'd1: begin fc_nph <= fc_nph + 1'b1; fc_npd <= fc_npd + d_dcred; fc_upd_req[1] <= 1'b1; end
                            default: if (!CPL_INFINITE) begin
                                fc_cplh <= fc_cplh + 1'b1; fc_cpld <= fc_cpld + d_dcred; fc_upd_req[2] <= 1'b1; end
                            endcase
                        end
                    end
                end
            end
            if (r_pipe[RXB_RLAT]) begin
                rdq[q_w[2:0]] <= {r_meta[RXB_RLAT][12:10], r_meta[RXB_RLAT][9:3], r_meta[RXB_RLAT][1],
                                  r_meta[RXB_RLAT][0], r_meta[RXB_RLAT][2], rxb_rdata[63:0]};
                q_w <= q_w + 1'b1;
            end
        end
    end
    // =====================================================================
    // rdq consumer: TRN RX or internal handler
    // =====================================================================
    wire [QW-1:0] qh = rdq[q_r[2:0]];
    wire          q_v = (q_w != q_r);
    wire [63:0]   q_d = qh[63:0];
    wire          q_half = qh[64], q_last = qh[65], q_first = qh[66];
    wire [6:0]    q_hit = qh[73:67];
    wire [2:0]    q_route = qh[76:74];

    assign trn_rd       = q_d;
    assign trn_rrem     = !(q_last && q_half);
    assign trn_rsof     = q_first;
    assign trn_reof     = q_last;
    assign trn_rsrc_rdy = q_v && q_route == R_USER;
    assign trn_rbar_hit = {1'b0, q_hit};
    reg    poisoned_cur;
    assign trn_rerrfwd  = q_first ? q_d[46] : poisoned_cur;

    // internal handler
    localparam I_COLLECT = 3'd0, I_EXEC = 3'd1, I_WAIT = 3'd2, I_CPL = 3'd3, I_WAIT0 = 3'd4;
    reg [2:0]  ist;
    reg [31:0] g0, g1, g2, g3, g4;
    reg [1:0]  gcnt;
    reg [2:0]  g_route;
    wire       int_pop = q_v && q_route != R_USER && ist == I_COLLECT;
    assign q_pop = (trn_rsrc_rdy && trn_rdst_rdy) || int_pop;

    always @(posedge clk) begin
        if (rst) q_r <= 4'd0;
        else if (q_pop) q_r <= q_r + 1'b1;
        if (trn_rsrc_rdy && trn_rdst_rdy && q_first) poisoned_cur <= q_d[46];
    end

    // byte count / lower address for memory read completions
    function [11:0] f_bcnt;
        input [9:0] l; input [3:0] fbe; input [3:0] lbe;
        reg [12:0] b; reg [1:0] fs, ls;
        begin
            fs = fbe[0] ? 2'd0 : fbe[1] ? 2'd1 : fbe[2] ? 2'd2 : fbe[3] ? 2'd3 : 2'd0;
            if (l == 10'd1) begin
                ls = fbe[3] ? 2'd0 : fbe[2] ? 2'd1 : fbe[1] ? 2'd2 : fbe[0] ? 2'd3 : 2'd0;
                b = (fbe == 4'd0) ? 13'd1 : 13'd4 - fs - ls;
            end else begin
                ls = lbe[3] ? 2'd0 : lbe[2] ? 2'd1 : lbe[1] ? 2'd2 : 2'd3;
                b = {1'b0, (l == 0 ? 11'd1024 : {1'b0, l}), 2'b00} - fs - ls;
            end
            f_bcnt = b[11:0];   // 4096 encodes as 0
        end
    endfunction
    function [1:0] f_laddr_lo; input [3:0] fbe;
        f_laddr_lo = fbe[0] ? 2'd0 : fbe[1] ? 2'd1 : fbe[2] ? 2'd2 : fbe[3] ? 2'd3 : 2'd0;
    endfunction

    wire [2:0] gfmt = g0[31:29];
    wire [4:0] gtyp = g0[28:24];
    always @(posedge clk) begin
        cfg_req_v <= 1'b0;
        msg_received <= 1'b0; msg_pme_to <= 1'b0; msg_unlock <= 1'b0; msg_setslot <= 1'b0;
        err_ur_np <= 1'b0;
        if (rst) begin
            ist <= I_COLLECT; gcnt <= 2'd0; icpl_v <= 1'b0; bus_num <= 8'd0; dev_num <= 5'd0;
        end else begin
            case (ist)
            I_COLLECT: if (int_pop) begin
                if (q_first) begin
                    g0 <= q_d[63:32]; g1 <= q_d[31:0]; g2 <= 32'd0; g3 <= 32'd0; gcnt <= 2'd1;
                    g_route <= q_route;
                end else if (gcnt == 2'd1) begin
                    g2 <= q_d[63:32]; g3 <= q_d[31:0]; gcnt <= 2'd2;
                end else if (gcnt == 2'd2) begin
                    g4 <= q_d[63:32]; gcnt <= 2'd3;       // first payload DW after a 4DW header
                end
                if (q_last) ist <= I_EXEC;
            end
            I_EXEC: begin
                case (g_route)
                R_CFG: begin
                    cfg_req_v <= 1'b1; cfg_req_wr <= gfmt[1];
                    cfg_req_dwaddr <= g2[11:2]; cfg_req_be <= g1[3:0];
                    // config write data (3DW header: data is DW3), wire byte 0 -> register [7:0]
                    cfg_req_wdata <= {g3[7:0], g3[15:8], g3[23:16], g3[31:24]};
                    if (gfmt[1]) begin bus_num <= g2[31:24]; dev_num <= g2[23:19]; end
                    ist <= I_WAIT0;
                end
                R_UR: begin
                    // UR routes are non-posted requests (posted URs are dropped)
                    icpl_v <= 1'b1;
                    icpl_status <= 3'b001; icpl_hasd <= 1'b0; icpl_data <= 32'd0;
                    icpl_reqid <= g1[31:16]; icpl_tag <= g1[15:8]; icpl_tc <= g0[22:20]; icpl_attr <= g0[13:12];
                    if (gtyp == 5'b00000 || gtyp == 5'b00001) begin
                        icpl_bcnt  <= f_bcnt(g0[9:0], g1[3:0], g1[7:4]);
                        icpl_laddr <= {(gfmt[0] ? g3[6:2] : g2[6:2]), f_laddr_lo(g1[3:0])};
                    end else begin
                        icpl_bcnt <= 12'd4; icpl_laddr <= 7'd0;
                    end
                    err_ur_np <= 1'b1;
                    ist <= I_CPL;
                end
                R_MSG: begin
                    msg_received <= 1'b1; msg_data <= g1[31:16];
                    case (g1[7:0])
                    8'h19: msg_pme_to <= 1'b1;
                    8'h00: msg_unlock <= 1'b1;
                    // Set_Slot_Power_Limit: value = payload bits [7:0], scale = [9:8]
                    8'h50: begin msg_setslot <= 1'b1; msg_slot_pwr <= {g4[17:16], g4[31:24]}; end
                    default: ;
                    endcase
                    ist <= I_COLLECT;
                end
                default: ist <= I_COLLECT;   // R_DROP
                endcase
            end
            I_WAIT0: ist <= I_WAIT;     // config space read data is registered
            I_WAIT: begin
                // cfg_rd_data valid now
                icpl_v <= 1'b1;
                icpl_status <= 3'b000; icpl_hasd <= !gfmt[1]; icpl_data <= cfg_rd_data;
                icpl_reqid <= g1[31:16]; icpl_tag <= g1[15:8]; icpl_tc <= g0[22:20]; icpl_attr <= g0[13:12];
                icpl_bcnt <= 12'd4; icpl_laddr <= 7'd0;
                ist <= I_CPL;
            end
            I_CPL: if (icpl_ack) begin icpl_v <= 1'b0; ist <= I_COLLECT; end
            default: ist <= I_COLLECT;
            endcase
        end
    end
endmodule
