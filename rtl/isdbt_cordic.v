// isdbt_cordic: 16 段パイプラインの CORDIC（角度は 2^32 = 1 回転の符号なし 32bit、"turns"）
//
//   isdbt_atan2  : ベクトルモード。(x, y) → 角度 atan2(y, x) [turns, 32bit] と振幅（CORDIC ゲイン込み、未使用可）
//   isdbt_rotate : 回転モード。(x, y) を角度 phase だけ回転する（phase > 0 で反時計回り）。
//                 入力を 0.6073（1/K）に事前スケールしてゲインを打ち消す
//
// どちらも入力 16bit、レイテンシ LAT = 18 クロック（事前象限補正 1 + 16 段 + 出力 1）。valid は同じ遅延で通す。
//
// SPDX-License-Identifier: MIT
// Copyright (c) 2026 k-iseri

`timescale 1ns/100ps


module isdbt_atan2 (
  input                   clk,
  input                   valid_in,
  input  signed [15:0]    x_in,
  input  signed [15:0]    y_in,
  output reg              valid_out,
  output reg  [31:0]      angle_out      // turns（0 = +x 軸、0x40000000 = +y 軸）
);
  localparam LAT = 18;
  // atan(2^-i) / (2π) × 2^32
  function [31:0] atab(input integer i);
    case (i)
      0: atab = 32'd536870912;  1: atab = 32'd316933406;  2: atab = 32'd167458907;  3: atab = 32'd85004756;
      4: atab = 32'd42667331;   5: atab = 32'd21354465;   6: atab = 32'd10679838;   7: atab = 32'd5340245;
      8: atab = 32'd2670163;    9: atab = 32'd1335087;   10: atab = 32'd667544;    11: atab = 32'd333772;
      12: atab = 32'd166886;   13: atab = 32'd83443;     14: atab = 32'd41722;     15: atab = 32'd20861;
      default: atab = 32'd0;
    endcase
  endfunction

  // 段 0: 象限補正（x<0 なら ±90° 回して x≥0 にする）。語長は 18bit に広げる
  reg signed [17:0] x [0:16];
  reg signed [17:0] y [0:16];
  reg        [31:0] z [0:16];
  reg               v [0:16];
  integer k;
  always @(posedge clk) begin
    v[0] <= valid_in;
    if (x_in < 0) begin
      if (y_in >= 0) begin x[0] <= y_in;  y[0] <= -x_in; z[0] <= 32'h40000000; end   // +90°
      else           begin x[0] <= -y_in; y[0] <= x_in;  z[0] <= 32'hC0000000; end   // −90°
    end else begin
      x[0] <= x_in; y[0] <= y_in; z[0] <= 32'd0;
    end
    for (k = 0; k < 16; k = k + 1) begin
      v[k + 1] <= v[k];
      if (y[k] >= 0) begin
        x[k + 1] <= x[k] + (y[k] >>> k);
        y[k + 1] <= y[k] - (x[k] >>> k);
        z[k + 1] <= z[k] + atab(k);
      end else begin
        x[k + 1] <= x[k] - (y[k] >>> k);
        y[k + 1] <= y[k] + (x[k] >>> k);
        z[k + 1] <= z[k] - atab(k);
      end
    end
    valid_out <= v[16];
    angle_out <= z[16];
  end
endmodule

module isdbt_rotate (
  input                   clk,
  input                   valid_in,
  input  signed [15:0]    x_in,
  input  signed [15:0]    y_in,
  input       [31:0]      phase_in,      // turns
  input       [63:0]      idx_in,        // サンプル番号（同じ遅延で通す）
  output reg              valid_out,
  output reg signed [15:0] x_out,
  output reg signed [15:0] y_out,
  output reg  [63:0]      idx_out
);
  reg   [63:0] idx_d [0:16];
  integer kk;
  always @(posedge clk) begin
    idx_d[0] <= idx_in;
    for (kk = 0; kk < 16; kk = kk + 1) idx_d[kk + 1] <= idx_d[kk];
    idx_out <= idx_d[16];
  end
  function [31:0] atab(input integer i);
    case (i)
      0: atab = 32'd536870912;  1: atab = 32'd316933406;  2: atab = 32'd167458907;  3: atab = 32'd85004756;
      4: atab = 32'd42667331;   5: atab = 32'd21354465;   6: atab = 32'd10679838;   7: atab = 32'd5340245;
      8: atab = 32'd2670163;    9: atab = 32'd1335087;   10: atab = 32'd667544;    11: atab = 32'd333772;
      12: atab = 32'd166886;   13: atab = 32'd83443;     14: atab = 32'd41722;     15: atab = 32'd20861;
      default: atab = 32'd0;
    endcase
  endfunction

  // 事前スケール 1/K ≈ 0.6073 = 1/2 + 1/8 − 1/64 − 1/512（誤差 0.03%）
  function signed [17:0] presc(input signed [15:0] a);
    reg signed [21:0] t;
    begin
      t = (a <<< 6);                                  // 22bit に広げて計算
      t = (t >>> 1) + (t >>> 3) - (t >>> 6) - (t >>> 9);
      presc = t >>> 4;                                // 18bit（2bit 余裕）
    end
  endfunction

  reg signed [17:0] x [0:16];
  reg signed [17:0] y [0:16];
  reg signed [31:0] z [0:16];   // 残り回転角（符号付き）
  reg               v [0:16];
  integer k;
  always @(posedge clk) begin
    v[0] <= valid_in;
    // 象限補正: |phase| > 90° なら先に ±180° 回す（符号反転）
    if (phase_in[31] ^ phase_in[30]) begin           // 2 or 3 象限（0x4000_0000〜0xBFFF_FFFF）
      x[0] <= -presc(x_in); y[0] <= -presc(y_in); z[0] <= phase_in + 32'h80000000;
    end else begin
      x[0] <= presc(x_in); y[0] <= presc(y_in); z[0] <= phase_in;
    end
    for (k = 0; k < 16; k = k + 1) begin
      v[k + 1] <= v[k];
      if (z[k] >= 0) begin
        x[k + 1] <= x[k] - (y[k] >>> k);
        y[k + 1] <= y[k] + (x[k] >>> k);
        z[k + 1] <= z[k] - $signed(atab(k));
      end else begin
        x[k + 1] <= x[k] + (y[k] >>> k);
        y[k + 1] <= y[k] - (x[k] >>> k);
        z[k + 1] <= z[k] + $signed(atab(k));
      end
    end
    valid_out <= v[16];
    x_out <= (x[16] > 18'sd32767) ? 16'sd32767 : (x[16] < -18'sd32768) ? -16'sd32768 : x[16][15:0];
    y_out <= (y[16] > 18'sd32767) ? 16'sd32767 : (y[16] < -18'sd32768) ? -16'sd32768 : y[16][15:0];
  end
endmodule
