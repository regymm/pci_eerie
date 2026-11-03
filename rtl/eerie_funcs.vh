// SPDX-License-Identifier: CERN-OHL-P
// pci_eerie: shared functions (include inside a module body)
//
// Bit conventions (verified against the PCIE_2_1 hard block, see tools/pipe_decode.py):
//  * Scrambler: 16-bit Galois LFSR X^16+X^5+X^4+X^3+1, seed FFFFh on COM,
//    output bit i of the scramble byte = lfsr[15] before shift i, advances 8
//    shifts per symbol except SKP.
//  * LCRC: reflected CRC-32 (EDB88320h), seed FFFFFFFFh, over seq bytes + TLP
//    bytes in wire order; wire bytes = ~crc[7:0], ~crc[15:8], ... ; a running
//    crc over data+LCRC gives residue DEBB20E3h.
//  * DLLP CRC16: non-reflected 100Bh, seed FFFFh, data bits LSB first;
//    wire byte4 = bitrev(~c[15:8]), byte5 = bitrev(~c[7:0]).

function [15:0] f_lfsr_adv8;
  input [15:0] l;
  integer i;
  reg [15:0] x;
  begin
    x = l;
    for (i = 0; i < 8; i = i + 1)
      x = {x[14:0], 1'b0} ^ (x[15] ? 16'h0039 : 16'h0000);
    f_lfsr_adv8 = x;
  end
endfunction

function [7:0] f_lfsr_byte;
  input [15:0] l;
  integer i;
  reg [15:0] x;
  reg [7:0] o;
  begin
    x = l;
    for (i = 0; i < 8; i = i + 1) begin
      o[i] = x[15];
      x = {x[14:0], 1'b0} ^ (x[15] ? 16'h0039 : 16'h0000);
    end
    f_lfsr_byte = o;
  end
endfunction

function [31:0] f_crc32_byte;
  input [31:0] c;
  input [7:0] d;
  integer i;
  reg [31:0] x;
  begin
    x = c ^ {24'd0, d};
    for (i = 0; i < 8; i = i + 1)
      x = {1'b0, x[31:1]} ^ (x[0] ? 32'hEDB88320 : 32'h0);
    f_crc32_byte = x;
  end
endfunction

function [15:0] f_crc16_byte;
  input [15:0] c;
  input [7:0] d;
  integer i;
  reg [15:0] x;
  reg fb;
  begin
    x = c;
    for (i = 0; i < 8; i = i + 1) begin
      fb = x[15] ^ d[i];
      x = {x[14:0], 1'b0} ^ (fb ? 16'h100B : 16'h0000);
    end
    f_crc16_byte = x;
  end
endfunction

function [7:0] f_rev8;
  input [7:0] d;
  f_rev8 = {d[0], d[1], d[2], d[3], d[4], d[5], d[6], d[7]};
endfunction

// DLLP CRC field for 4 DLLP bytes {b0,b1,b2,b3} (b0 = first on wire = d[31:24]);
// returns {wire byte 4, wire byte 5}
function [15:0] f_dllp_crc;
  input [31:0] d;
  reg [15:0] c;
  begin
    c = f_crc16_byte(16'hFFFF, d[31:24]);
    c = f_crc16_byte(c, d[23:16]);
    c = f_crc16_byte(c, d[15:8]);
    c = f_crc16_byte(c, d[7:0]);
    c = ~c;
    f_dllp_crc = {f_rev8(c[15:8]), f_rev8(c[7:0])};
  end
endfunction

// LCRC update over one DW given in wire order {b0,b1,b2,b3} = d[31:24],d[23:16],...
function [31:0] f_crc32_dw;
  input [31:0] c;
  input [31:0] d;
  reg [31:0] x;
  begin
    x = f_crc32_byte(c, d[31:24]);
    x = f_crc32_byte(x, d[23:16]);
    x = f_crc32_byte(x, d[15:8]);
    f_crc32_dw = f_crc32_byte(x, d[7:0]);
  end
endfunction

// LCRC field (4 wire bytes as a DW, first wire byte in [31:24]) from a running crc
function [31:0] f_lcrc_field;
  input [31:0] c;
  reg [31:0] x;
  begin
    x = ~c;
    f_lcrc_field = {x[7:0], x[15:8], x[23:16], x[31:24]};
  end
endfunction
