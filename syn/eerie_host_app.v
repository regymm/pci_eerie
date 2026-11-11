// SPDX-License-Identifier: CERN-OHL-P
// pci_eerie root port hardware test: a register bus (driven over JTAG by eerie_jtag_bus, or by a
// testbench) that sends TLPs written by the host, captures every received TLP, and accesses the
// root port's own configuration space through cfg_mgmt.
//
// Register map (32-bit, user_clk domain, word addresses):
//   0x0000-0x001F  W   TX buffer, TLP DW0..DW31 (PCIe DW order, as in the 7-series AXI format)
//   0x0100         W   send the TX buffer: data = number of DWs (3..32); R: bit0 busy, [31:16] sent count
//   0x0200         R   RX: [9:0] beats captured, bit 16 overflow, [31:24] TLPs captured;  W: clear
//   0x0300         R   status (see below)
//   0x0301         R   free-running user_clk counter
//   0x0303         R   LTSSM trace: [5:0] entries written (64 max, then stops), [13:8] highest state seen
//   0x0304/0x0305  R   pci_eerie DBGVECA[31:0] / [49:32] (PIPE detect / receive status, see pci_eerie.v)
//   0x0306/0x0307  R   GT wrapper reset state [24:0] / [49:25] (see syn/core_rp_dbg.sed)
//   0x2000-0x203F  R   LTSSM trace entries: [5:0] state entered, [31:8] user_clk counter / 64 at entry
//                      (cleared by writing 0x0303)
//   0x0302         R/W PL control: [1:0] directed_link_change, [3:2] directed_link_width,
//                      [4] directed_link_speed, [5] directed_link_auton, [6] transmit_hot_rst
//   0x0400         W   cfg_mgmt dword address [9:0]
//   0x0401         W   cfg_mgmt write data
//   0x0402         W   cfg_mgmt go: bit0 read, bit1 write, [7:4] byte enables; R: bit0 busy, bit1 timeout
//   0x0403         R   cfg_mgmt read data
//   0x1000-0x13FF  R   RX beats: 0x1000 + 2*beat = DW0 (tdata[31:0]), +1 = DW1 (tdata[63:32])
//   0x1800-0x19FF  R   RX beat flags: [0] tlast, [1] tkeep[4] (DW1 valid), [2] err_fwd, [9:3] bar hit
`timescale 1ns / 1ps
module eerie_host_app (
    input             clk,
    input             rst,
    // register bus
    input             req,
    input             we,
    input      [15:0] addr,
    input      [31:0] wdata,
    output reg [31:0] rdata,
    output reg        ack,
    // AXI-stream to/from the root port core
    input             s_axis_tx_tready,
    output reg [63:0] s_axis_tx_tdata,
    output reg [7:0]  s_axis_tx_tkeep,
    output reg        s_axis_tx_tlast,
    output reg        s_axis_tx_tvalid,
    input      [63:0] m_axis_rx_tdata,
    input      [7:0]  m_axis_rx_tkeep,
    input             m_axis_rx_tlast,
    input             m_axis_rx_tvalid,
    input      [21:0] m_axis_rx_tuser,
    // cfg_mgmt
    output reg [9:0]  cfg_mgmt_dwaddr,
    output reg [31:0] cfg_mgmt_di,
    output reg [3:0]  cfg_mgmt_byte_en,
    output reg        cfg_mgmt_rd_en,
    output reg        cfg_mgmt_wr_en,
    input      [31:0] cfg_mgmt_do,
    input             cfg_mgmt_rd_wr_done,
    // status / PL control
    input      [31:0] status,
    input      [49:0] dbg,      // bring-up status from pci_eerie (other clock, quasi-static)
    input      [49:0] gtdbg,    // GT wrapper reset state (other clocks, quasi-static)
    output reg [6:0]  pl_ctl
);
    // ---------------------------------------------------------------- TX
    reg [31:0] txb [0:31];
    reg [5:0]  tx_n, tx_i;      // DW count, next DW index
    reg        tx_busy;
    reg [15:0] tx_cnt;
    wire [5:0] tx_left = tx_n - tx_i;
    always @(posedge clk) begin
        if (rst) begin
            tx_busy <= 1'b0; s_axis_tx_tvalid <= 1'b0; s_axis_tx_tlast <= 1'b0; tx_cnt <= 16'd0;
        end else if (!tx_busy) begin
            s_axis_tx_tvalid <= 1'b0;
            if (req && we && addr == 16'h0100 && wdata[5:0] >= 6'd3) begin
                tx_n <= wdata[5:0]; tx_i <= 6'd0; tx_busy <= 1'b1;
            end
        end else if (!s_axis_tx_tvalid || s_axis_tx_tready) begin
            if (s_axis_tx_tvalid && s_axis_tx_tlast) begin
                s_axis_tx_tvalid <= 1'b0; s_axis_tx_tlast <= 1'b0; tx_busy <= 1'b0; tx_cnt <= tx_cnt + 1'b1;
            end else begin
                s_axis_tx_tdata  <= {txb[tx_i[4:0] + 1'b1], txb[tx_i[4:0]]};
                s_axis_tx_tkeep  <= (tx_left == 6'd1) ? 8'h0F : 8'hFF;
                s_axis_tx_tlast  <= (tx_left <= 6'd2);
                s_axis_tx_tvalid <= 1'b1;
                tx_i <= tx_i + 2'd2;
            end
        end
    end
    always @(posedge clk) if (req && we && addr[15:5] == 11'h000) txb[addr[4:0]] <= wdata;

    // ---------------------------------------------------------------- RX capture
    reg [31:0] rx_lo [0:511];
    reg [31:0] rx_hi [0:511];
    reg [9:0]  rx_fl [0:511];
    reg [9:0]  rx_wp;
    reg        rx_ovf;
    reg [7:0]  rx_tlps;
    wire       rx_clr = req && we && addr == 16'h0200;
    always @(posedge clk) begin
        if (rst || rx_clr) begin
            rx_wp <= 10'd0; rx_ovf <= 1'b0; rx_tlps <= 8'd0;
        end else if (m_axis_rx_tvalid) begin
            if (rx_wp[9]) rx_ovf <= 1'b1;
            else rx_wp <= rx_wp + 1'b1;
            if (m_axis_rx_tlast) rx_tlps <= rx_tlps + 1'b1;
        end
    end
    always @(posedge clk) if (m_axis_rx_tvalid && !rx_wp[9]) begin
        rx_lo[rx_wp[8:0]] <= m_axis_rx_tdata[31:0];
        rx_hi[rx_wp[8:0]] <= m_axis_rx_tdata[63:32];
        rx_fl[rx_wp[8:0]] <= {m_axis_rx_tuser[8:2], m_axis_rx_tuser[1], m_axis_rx_tkeep[4], m_axis_rx_tlast};
    end
    reg [31:0] rx_lo_q, rx_hi_q; reg [9:0] rx_fl_q;
    always @(posedge clk) begin
        rx_lo_q <= rx_lo[addr[9:1]]; rx_hi_q <= rx_hi[addr[9:1]]; rx_fl_q <= rx_fl[addr[8:0]];
    end

    // ---------------------------------------------------------------- cfg_mgmt
    reg        cm_busy, cm_to;
    reg [15:0] cm_t;
    reg [31:0] cm_do;
    always @(posedge clk) begin
        if (rst) begin
            cfg_mgmt_rd_en <= 1'b0; cfg_mgmt_wr_en <= 1'b0; cm_busy <= 1'b0; cm_to <= 1'b0;
            cfg_mgmt_byte_en <= 4'h0;
        end else if (cm_busy) begin
            cm_t <= cm_t + 1'b1;
            if (cfg_mgmt_rd_wr_done || &cm_t) begin
                cfg_mgmt_rd_en <= 1'b0; cfg_mgmt_wr_en <= 1'b0; cm_busy <= 1'b0;
                cm_to <= !cfg_mgmt_rd_wr_done; cm_do <= cfg_mgmt_do;
            end
        end else if (req && we) begin
            if (addr == 16'h0400) cfg_mgmt_dwaddr <= wdata[9:0];
            if (addr == 16'h0401) cfg_mgmt_di <= wdata;
            if (addr == 16'h0402 && wdata[1:0] != 2'b00) begin
                cfg_mgmt_rd_en <= wdata[0]; cfg_mgmt_wr_en <= !wdata[0] && wdata[1];
                cfg_mgmt_byte_en <= wdata[7:4]; cm_busy <= 1'b1; cm_t <= 16'd0;
            end
        end
    end

    // ---------------------------------------------------------------- PL control, counter
    reg [31:0] ucnt;
    always @(posedge clk) begin
        ucnt <= ucnt + 1'b1;
        if (rst) pl_ctl <= 7'd0;
        else if (req && we && addr == 16'h0302) pl_ctl <= wdata[6:0];
    end

    // ---------------------------------------------------------------- LTSSM trace (status[7:2])
    // not reset by rst: the interesting part happens while the link is down
    reg [31:0] tr [0:63];
    reg [6:0]  tr_n = 7'd0;
    reg [5:0]  tr_last = 6'h3F, tr_max = 6'd0;
    wire [5:0] lt = status[7:2];
    always @(posedge clk) begin
        if (req && we && addr == 16'h0303) begin tr_n <= 7'd0; tr_max <= 6'd0; tr_last <= 6'h3F; end
        else if (lt != tr_last) begin
            tr_last <= lt;
            if (lt > tr_max) tr_max <= lt;
            if (!tr_n[6]) begin tr[tr_n[5:0]] <= {ucnt[29:6], 2'b00, lt}; tr_n <= tr_n + 1'b1; end
        end
    end
    (* ASYNC_REG = "TRUE" *) reg [49:0] dbg_s1, dbg_s2;
    always @(posedge clk) begin dbg_s1 <= dbg; dbg_s2 <= dbg_s1; end
    (* ASYNC_REG = "TRUE" *) reg [49:0] gt_s1, gt_s2;
    always @(posedge clk) begin gt_s1 <= gtdbg; gt_s2 <= gt_s1; end
    reg [31:0] tr_q;
    always @(posedge clk) tr_q <= tr[addr[5:0]];

    // ---------------------------------------------------------------- read mux (one cycle after req)
    // TX, RX capture, cfg_mgmt and PL control are reset by rst; the bus itself is not
    reg        req_q;
    reg [15:0] addr_q;
    always @(posedge clk) begin
        // not held by rst (the core's user_reset, asserted while the link is down): status stays readable
        req_q <= req; addr_q <= addr; ack <= req_q;
        if (req_q) begin
            casez (addr_q)
            16'h0100: rdata <= {tx_cnt, 15'd0, tx_busy};
            16'h0200: rdata <= {rx_tlps, 7'd0, rx_ovf, 6'd0, rx_wp};
            16'h0300: rdata <= status;
            16'h0301: rdata <= ucnt;
            16'h0302: rdata <= {25'd0, pl_ctl};
            16'h0303: rdata <= {18'd0, tr_max, 1'b0, tr_n};
            16'h0304: rdata <= dbg_s2[31:0];
            16'h0305: rdata <= {14'd0, dbg_s2[49:32]};
            16'h0306: rdata <= {7'd0, gt_s2[24:0]};
            16'h0307: rdata <= {7'd0, gt_s2[49:25]};
            16'h0402: rdata <= {30'd0, cm_to, cm_busy};
            16'h0403: rdata <= cm_do;
            16'b0001_00??_????_????: rdata <= addr_q[0] ? rx_hi_q : rx_lo_q;
            16'b0001_100?_????_????: rdata <= {22'd0, rx_fl_q};
            16'b0010_0000_00??_????: rdata <= tr_q;
            default:  rdata <= 32'hDEAD_0000 | addr_q;
            endcase
        end
    end
endmodule

// JTAG (BSCANE2 USER1) to register bus. Data register, 50 bits, shifted LSB first:
//   in:  [31:0] data, [47:32] address, [48] write, [49] go (0: no operation, only read back)
//   out: [31:0] read data of the last operation, [39:32] operations completed, [49:40] aux
// Address 0xFFFF is a control register in the JTAG clock domain (ctl), not forwarded.
module eerie_jtag_bus #(
    parameter SIM = 0
) (
    input             clk,          // register bus clock
    output reg        req,
    output reg        we,
    output reg [15:0] addr,
    output reg [31:0] wdata,
    input      [31:0] rdata,
    input             ack,
    input      [9:0]  aux,
    output reg [31:0] ctl
);
    wire tck, tdi, sel, shift, capture, update;
    reg  [49:0] sr;
    generate if (!SIM) begin : g_bscan
        BSCANE2 #(.JTAG_CHAIN(1)) bscan (
            .CAPTURE(capture), .DRCK(), .RESET(), .RUNTEST(), .SEL(sel), .SHIFT(shift), .TCK(tck),
            .TDI(tdi), .TMS(), .UPDATE(update), .TDO(sr[0])
        );
    end else begin : g_nobscan
        assign tck = 1'b0, tdi = 1'b0, sel = 1'b0, shift = 1'b0, capture = 1'b0, update = 1'b0;
    end endgenerate

    // JTAG clock domain
    (* ASYNC_REG = "TRUE" *) reg [9:0] aux_s1, aux_s2;
    reg [31:0] c_data; reg [15:0] c_addr; reg c_we; reg req_t;
    reg [31:0] r_data; reg [7:0] r_cnt;     // user clock domain, stable when captured
    initial begin ctl = 32'd0; req_t = 1'b0; end
    always @(posedge tck) begin
        aux_s1 <= aux; aux_s2 <= aux_s1;
        if (sel && capture) sr <= {aux_s2, r_cnt, r_data};
        else if (sel && shift) sr <= {tdi, sr[49:1]};
        if (sel && update && sr[49]) begin
            if (sr[47:32] == 16'hFFFF) begin
                if (sr[48]) ctl <= sr[31:0];
            end else begin
                c_data <= sr[31:0]; c_addr <= sr[47:32]; c_we <= sr[48]; req_t <= !req_t;
            end
        end
    end

    // register bus clock domain
    (* ASYNC_REG = "TRUE" *) reg [2:0] req_s;
    initial begin r_cnt = 8'd0; req_s = 3'd0; end
    always @(posedge clk) begin
        req_s <= {req_s[1:0], req_t};
        req <= req_s[2] ^ req_s[1];
        if (req_s[2] ^ req_s[1]) begin we <= c_we; addr <= c_addr; wdata <= c_data; end
        if (ack) begin r_data <= rdata; r_cnt <= r_cnt + 1'b1; end
    end
endmodule
