// isdbt_cordic: 16 段パイプラインの CORDIC（角度は 2^32 = 1 回転の符号なし 32bit、"turns"）
//
//   isdbt_atan2  : ベクトルモード。(x, y) → 角度 atan2(y, x) [turns, 32bit] と振幅（CORDIC ゲイン込み、未使用可）
//   isdbt_rotate : 回転モード。(x, y) を角度 phase だけ回転する（phase > 0 で反時計回り）。
//                 入力を 0.6073（1/K）に事前スケールしてゲインを打ち消す
//
// どちらも入力 16bit、レイテンシ ITER + 2 クロック（事前象限補正 1 + ITER 段 + 出力 1）。valid は同じ遅延で通す。
//
// SPDX-License-Identifier: MIT
// Copyright (c) 2026 k-iseri

`timescale 1ns/100ps


module isdbt_atan2 #(
  parameter ITER = 12            // 反復回数（角度精度 2^-(ITER+2) 回転程度）
) (
  input                   clk,
  input                   valid_in,
  input  signed [15:0]    x_in,
  input  signed [15:0]    y_in,
  output reg              valid_out,
  output reg  [31:0]      angle_out      // turns（0 = +x 軸、0x40000000 = +y 軸）
);
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
  reg signed [17:0] x [0:ITER];
  reg signed [17:0] y [0:ITER];
  reg        [31:0] z [0:ITER];
  reg               v [0:ITER];
  integer k;
  always @(posedge clk) begin
    v[0] <= valid_in;
    if (x_in < 0) begin
      if (y_in >= 0) begin x[0] <= y_in;  y[0] <= -x_in; z[0] <= 32'h40000000; end   // +90°
      else           begin x[0] <= -y_in; y[0] <= x_in;  z[0] <= 32'hC0000000; end   // −90°
    end else begin
      x[0] <= x_in; y[0] <= y_in; z[0] <= 32'd0;
    end
    for (k = 0; k < ITER; k = k + 1) begin
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
    valid_out <= v[ITER];
    angle_out <= z[ITER];
  end
endmodule

module isdbt_rotate #(
  parameter ITER = 12
) (
  input                   clk,
  input       [3:0]       mode,          // 2 のとき回転、それ以外は入力をそのまま（同じ遅延で）通す
  input                   valid_in,
  input  signed [15:0]    x_in,
  input  signed [15:0]    y_in,
  input       [31:0]      phase_in,      // turns
  input       [31:0]      idx_in,        // サンプル番号（同じ遅延で通す）
  output reg              valid_out,
  output reg signed [15:0] x_out,
  output reg signed [15:0] y_out,
  output reg  [31:0]      idx_out
);
  reg   [31:0] idx_d [0:ITER];
  integer kk;
  always @(posedge clk) begin
    idx_d[0] <= idx_in;
    for (kk = 0; kk < ITER; kk = kk + 1) idx_d[kk + 1] <= idx_d[kk];
    idx_out <= idx_d[ITER];
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

  // 事前スケール 1/K ≈ 0.60725 = 1/2 + 1/8 − 1/64 − 1/512 − 1/4096（誤差 0.01%）。内部は 20bit（小数 4bit）
  function signed [19:0] presc(input signed [15:0] a);
    reg signed [23:0] t;
    begin
      t = (a <<< 8);                                  // 24bit に広げて計算
      t = (t >>> 1) + (t >>> 3) - (t >>> 6) - (t >>> 9) - (t >>> 12);
      presc = t >>> 4;                                // 20bit（小数 4bit）
    end
  endfunction

  reg signed [19:0] x [0:ITER];
  reg signed [19:0] y [0:ITER];
  // バイパス用の遅延線（回転と同じ ITER + 2 段）
  reg signed [15:0] bx [0:ITER];
  reg signed [15:0] by [0:ITER];
  reg               bmode [0:ITER];
  integer kb;
  always @(posedge clk) begin
    bx[0] <= x_in; by[0] <= y_in; bmode[0] <= (mode == 4'd2) || (mode == 4'd3) || (mode == 4'd4);
    for (kb = 0; kb < ITER; kb = kb + 1) begin bx[kb + 1] <= bx[kb]; by[kb + 1] <= by[kb]; bmode[kb + 1] <= bmode[kb]; end
  end
  reg signed [31:0] z [0:ITER];   // 残り回転角（符号付き）
  reg               v [0:ITER];
  wire signed [19:0] xr = (x[ITER] + 20'sd8) >>> 4;
  wire signed [19:0] yr = (y[ITER] + 20'sd8) >>> 4;
  integer k;
  always @(posedge clk) begin
    v[0] <= valid_in;
    // 象限補正: |phase| > 90° なら先に ±180° 回す（符号反転）
    if (phase_in[31] ^ phase_in[30]) begin           // 2 or 3 象限（0x4000_0000〜0xBFFF_FFFF）
      x[0] <= -presc(x_in); y[0] <= -presc(y_in); z[0] <= phase_in + 32'h80000000;
    end else begin
      x[0] <= presc(x_in); y[0] <= presc(y_in); z[0] <= phase_in;
    end
    for (k = 0; k < ITER; k = k + 1) begin
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
    valid_out <= v[ITER];
    // presc は 20bit に 4bit 分桁上げしている（×16）ので丸めて戻し 16bit に飽和。回転モード以外はバイパス
    if (!bmode[ITER]) begin
      x_out <= bx[ITER];
      y_out <= by[ITER];
    end else begin
      x_out <= (xr > 20'sd32767) ? 16'sd32767 : (xr < -20'sd32768) ? -16'sd32768 : xr[15:0];
      y_out <= (yr > 20'sd32767) ? 16'sd32767 : (yr < -20'sd32768) ? -16'sd32768 : yr[15:0];
    end
  end
endmodule
