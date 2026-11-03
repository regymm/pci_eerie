// SPDX-License-Identifier: CERN-OHL-P
// pci_eerie: clock domain crossing helpers
`timescale 1ns / 1ps

// multi-bit level synchronizer (only for quasi-static / gray-ish status signals)
module eerie_sync_bits #(parameter W = 1, parameter [W-1:0] INIT = 0) (
    input              clk,
    input  [W-1:0]     d,
    output [W-1:0]     q
);
    (* ASYNC_REG = "TRUE" *) reg [W-1:0] s1 = INIT, s2 = INIT;
    always @(posedge clk) begin s1 <= d; s2 <= s1; end
    assign q = s2;
endmodule

// single pulse crossing (toggle based); pulses must be spaced by a few
// destination clocks
module eerie_sync_pulse (
    input  src_clk,
    input  src_pulse,
    input  dst_clk,
    output dst_pulse
);
    reg t = 1'b0;
    always @(posedge src_clk) if (src_pulse) t <= ~t;
    (* ASYNC_REG = "TRUE" *) reg s1 = 1'b0, s2 = 1'b0;
    reg s3 = 1'b0;
    always @(posedge dst_clk) begin s1 <= t; s2 <= s1; s3 <= s2; end
    assign dst_pulse = s2 ^ s3;
endmodule

// asynchronous assert, synchronous deassert reset (active high output)
module eerie_reset_sync #(parameter STAGES = 4) (
    input  clk,
    input  arst,         // active high, asynchronous
    output rst
);
    (* ASYNC_REG = "TRUE" *) reg [STAGES-1:0] r = {STAGES{1'b1}};
    always @(posedge clk or posedge arst)
        if (arst) r <= {STAGES{1'b1}};
        else r <= {r[STAGES-2:0], 1'b0};
    assign rst = r[STAGES-1];
endmodule
