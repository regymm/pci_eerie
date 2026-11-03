// SPDX-License-Identifier: CERN-OHL-P
// pci_eerie: dual-clock FIFO (gray-coded pointers, distributed/block RAM inferred)
//
// PKT_MODE=1: the read side only sees entries up to the last committed packet
// boundary (an entry written with wr_last=1), so a reader can stream a whole
// packet without underflow.
`timescale 1ns / 1ps
module eerie_async_fifo #(
    parameter W        = 64,
    parameter AW       = 4,        // depth = 2**AW
    parameter PKT_MODE = 0
) (
    input              wr_clk,
    input              wr_rst,
    input              wr_en,
    input  [W-1:0]     wr_data,
    input              wr_last,    // PKT_MODE: this entry ends a packet
    output             wr_full,
    output [AW:0]      wr_free,    // free entries (conservative)

    input              rd_clk,
    input              rd_rst,
    input              rd_en,
    output [W-1:0]     rd_data,    // first-word fall-through
    output             rd_empty
);
    function [AW:0] bin2gray(input [AW:0] b); bin2gray = b ^ (b >> 1); endfunction
    function [AW:0] gray2bin(input [AW:0] g);
        integer i;
        begin
            gray2bin[AW] = g[AW];
            for (i = AW - 1; i >= 0; i = i - 1) gray2bin[i] = gray2bin[i+1] ^ g[i];
        end
    endfunction

    reg [W-1:0] mem [0:(1<<AW)-1];

    reg  [AW:0] rptr_bin_r, rptr_gray_r;
    // ---------------- write side ----------------
    reg  [AW:0] wptr_bin, wptr_gray;
    reg  [AW:0] cptr_bin, cptr_gray;          // committed pointer (PKT_MODE)
    (* ASYNC_REG = "TRUE" *) reg [AW:0] rptr_gray_w1, rptr_gray_w2;
    reg  [AW:0] rptr_bin_w;                    // decoded one clock later (conservative)
    wire [AW:0] used_w     = wptr_bin - rptr_bin_w;
    assign wr_full = used_w[AW];
    assign wr_free = (1 << AW) - used_w;

    always @(posedge wr_clk) begin
        if (wr_en && !wr_full) mem[wptr_bin[AW-1:0]] <= wr_data;
    end
    always @(posedge wr_clk) begin
        if (wr_rst) begin
            wptr_bin <= 0; wptr_gray <= 0; cptr_bin <= 0; cptr_gray <= 0;
            rptr_gray_w1 <= 0; rptr_gray_w2 <= 0; rptr_bin_w <= 0;
        end else begin
            rptr_gray_w1 <= rptr_gray_r;
            rptr_gray_w2 <= rptr_gray_w1;
            rptr_bin_w   <= gray2bin(rptr_gray_w2);
            if (wr_en && !wr_full) begin
                wptr_bin  <= wptr_bin + 1'b1;
                wptr_gray <= bin2gray(wptr_bin + 1'b1);
                if (!PKT_MODE || wr_last) begin
                    cptr_bin  <= wptr_bin + 1'b1;
                    cptr_gray <= bin2gray(wptr_bin + 1'b1);
                end
            end
        end
    end
    wire [AW:0] pub_gray = PKT_MODE ? cptr_gray : wptr_gray;

    // ---------------- read side ----------------
    (* ASYNC_REG = "TRUE" *) reg [AW:0] wptr_gray_r1, wptr_gray_r2;
    assign rd_empty = (rptr_gray_r == wptr_gray_r2);
    assign rd_data  = mem[rptr_bin_r[AW-1:0]];
    always @(posedge rd_clk) begin
        if (rd_rst) begin
            rptr_bin_r <= 0; rptr_gray_r <= 0; wptr_gray_r1 <= 0; wptr_gray_r2 <= 0;
        end else begin
            wptr_gray_r1 <= pub_gray;
            wptr_gray_r2 <= wptr_gray_r1;
            if (rd_en && !rd_empty) begin
                rptr_bin_r  <= rptr_bin_r + 1'b1;
                rptr_gray_r <= bin2gray(rptr_bin_r + 1'b1);
            end
        end
    end
endmodule
