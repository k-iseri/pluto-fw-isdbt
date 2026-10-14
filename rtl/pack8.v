// pack8: 16 bit コンテナの 12 bit ADC サンプルを 8 bit に量子化する（組み合わせ回路）
//
// 入力は axi_ad9361 の ADC チャネル出力（符号拡張済み 16 bit、実データ 12 bit = [-2048, 2047]）。
// 出力は上位 8 bit 相当（算術右シフト 4）だが、単純切り捨てだと −0.5 LSB のバイアスが乗るので
// 四捨五入（round half away from zero）してから [-128, 127] に飽和させる。
// 12 bit 入力で飽和するのは +2040 以上（→ +128）の場合だけ。DC 除去や IQ 補正で 12 bit を
// わずかに超えた値が来ても安全側に丸まる。
//
// 遅延を持たないので、valid / enable はそのまま素通しでよい（util_cpack2 の fifo_wr_data_N の
// 直前に挟む）。
//
// SPDX-License-Identifier: MIT
// Copyright (c) 2026 k-iseri

`timescale 1ns/100ps

module pack8 #(
  parameter IN_WIDTH = 16,
  parameter SHIFT = 4            // 12 bit → 8 bit
) (
  input  [IN_WIDTH-1:0] din,
  output [7:0]          dout
);

  wire signed [IN_WIDTH-1:0] x = din;
  wire                       neg = x[IN_WIDTH-1];
  // |x| + 半 LSB（切り上げ閾値）を右シフト。負側は絶対値で丸めて符号を戻す = half away from zero
  wire signed [IN_WIDTH:0]   mag = neg ? -x : x;                       // 1 bit 広げる（-2048 の反転対策）
  wire signed [IN_WIDTH:0]   mag_r = (mag + (1 << (SHIFT - 1))) >>> SHIFT;
  wire signed [IN_WIDTH:0]   y = neg ? -mag_r : mag_r;

  assign dout = (y > 127)  ? 8'sd127 :
                (y < -128) ? -8'sd128 :
                y[7:0];

endmodule
