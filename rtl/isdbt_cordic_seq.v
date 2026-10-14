// isdbt_cordic_seq: LUT を節約した位相処理
//   isdbt_atan2_seq : 逐次 CORDIC atan2（1 段を ITER 回使い回す。1 シンボルに数回しか使わない用途向け、LUT は 1/6）
//   isdbt_rotate_lut: sin/cos 表（BRAM 1024 × 32）+ 複素乗算による回転（CORDIC 12 段 ≈ LUT 1000 の置き換え）
// 表は isdbt_eq_tables.vh（scripts/gen_eq_tables.py）の sincos_tab。
//
// SPDX-License-Identifier: MIT
// Copyright (c) 2026 k-iseri

`timescale 1ns/100ps

module isdbt_atan2_seq #(
  parameter ITER = 12
) (
  input                   clk,
  input                   valid_in,
  input  signed [15:0]    x_in,
  input  signed [15:0]    y_in,
  output reg              valid_out,
  output reg  [31:0]      angle_out      // turns（0 = +x 軸、0x40000000 = +y 軸）。処理中（busy）の valid_in は無視
);
  function [31:0] atab(input integer i);
    case (i)
      0: atab = 32'd536870912;  1: atab = 32'd316933406;  2: atab = 32'd167458907;  3: atab = 32'd85004756;
      4: atab = 32'd42667331;   5: atab = 32'd21354465;   6: atab = 32'd10679838;   7: atab = 32'd5340245;
      8: atab = 32'd2670163;    9: atab = 32'd1335087;   10: atab = 32'd667544;    11: atab = 32'd333772;
      12: atab = 32'd166886;   13: atab = 32'd83443;     14: atab = 32'd41722;     15: atab = 32'd20861;
      default: atab = 32'd0;
    endcase
  endfunction
  reg signed [17:0] x = 'd0, y = 'd0;
  reg        [31:0] z = 'd0;
  reg        [4:0]  k = 'd0;
  reg               busy = 1'b0;
  always @(posedge clk) begin
    valid_out <= 1'b0;
    if (!busy) begin
      if (valid_in) begin
        busy <= 1'b1;
        k <= 'd0;
        if (x_in < 0) begin
          if (y_in >= 0) begin x <= y_in;  y <= -x_in; z <= 32'h40000000; end   // +90°
          else           begin x <= -y_in; y <= x_in;  z <= 32'hC0000000; end   // −90°
        end else begin
          x <= x_in; y <= y_in; z <= 32'd0;
        end
      end
    end else begin
      if (y >= 0) begin
        x <= x + (y >>> k);
        y <= y - (x >>> k);
        z <= z + atab(k);
      end else begin
        x <= x - (y >>> k);
        y <= y + (x >>> k);
        z <= z - atab(k);
      end
      k <= k + 1'b1;
      if (k == ITER - 1) begin
        busy <= 1'b0;
        valid_out <= 1'b1;
        angle_out <= (y >= 0) ? z + atab(k) : z - atab(k);
      end
    end
  end
endmodule

module isdbt_rotate_lut (
  input                   clk,
  input       [3:0]       mode,          // 2/3/4 のとき回転、それ以外は入力をそのまま（同じ遅延 3 で）通す
  input                   valid_in,
  input  signed [15:0]    x_in,
  input  signed [15:0]    y_in,
  input       [31:0]      phase_in,      // turns
  input       [31:0]      idx_in,
  output reg              valid_out,
  output reg signed [15:0] x_out,
  output reg signed [15:0] y_out,
  output reg  [31:0]      idx_out
);
  `include "isdbt_eq_tables.vh"
  wire enable = (mode == 4'd2) || (mode == 4'd3) || (mode == 4'd4);
  (* rom_style = "block" *) reg [31:0] rom [0:1023];
  integer ti;
  initial for (ti = 0; ti < 1024; ti = ti + 1) rom[ti] = sincos_tab(ti);
  reg   [31:0]  sc1 = 'd0;
  reg   signed [15:0] x1 = 'd0, y1 = 'd0, x2 = 'd0, y2 = 'd0, x3 = 'd0, y3 = 'd0;
  reg   signed [15:0] c2 = 'd0, s2 = 'd0;
  reg   signed [32:0] pr = 'd0, pi = 'd0;
  reg           v1 = 1'b0, v2 = 1'b0, v3 = 1'b0;
  reg   [31:0]  i1 = 'd0, i2 = 'd0, i3 = 'd0;
  wire signed [32:0] pr_r = pr + 33'sd16384;
  wire signed [32:0] pi_r = pi + 33'sd16384;
  function signed [15:0] sat16(input signed [32:0] v);
    sat16 = (v > 32767) ? 16'sd32767 : (v < -32768) ? -16'sd32768 : v[15:0];
  endfunction
  always @(posedge clk) begin
    v1 <= valid_in; v2 <= v1; v3 <= v2;
    sc1 <= rom[phase_in[31:22]];
    x1 <= x_in; y1 <= y_in; i1 <= idx_in;
    c2 <= sc1[15:0]; s2 <= sc1[31:16];
    x2 <= x1; y2 <= y1; i2 <= i1;
    pr <= x2 * c2 - y2 * s2;          // (x + jy)·(c + js)
    pi <= x2 * s2 + y2 * c2;
    x3 <= x2; y3 <= y2; i3 <= i2;
    valid_out <= v3;
    idx_out <= i3;
    x_out <= enable ? sat16(pr_r >>> 15) : x3;
    y_out <= enable ? sat16(pi_r >>> 15) : y3;
  end
endmodule
