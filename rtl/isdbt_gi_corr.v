// isdbt_gi_corr: ガードインターバル相関（8bit I/Q、遅延 N、移動和 Ng）
//
//   p[n] = x[n] · conj(x[n−N])
//   c[n] = Σ_{m=n−Ng+1}^{n} p[m]       （再帰: c[n] = c[n−1] + p[n] − p[n−Ng]）
//   mag2[n] = |c[n] >> 10|²            （比較用。|c| ≤ 2·127²·Ng < 2^25 なので >> 10 で 16bit に収まり、mag2 は 2^31 以下。
//                                       以前の >> 12 は −30 dBFS（8bit で rms 4）で c>>12 ≈ 8 になり、ピーク比較と
//                                       atan2 が整数の粗さで崩れて同期が窓を欠かした。2026-10-15）
//
// シンボル（GI 込み長 T = N + Ng）が [s, s+T) にあるとき、GI = [s, s+Ng) と [s+N, s+T) が等しいので
// |c[n]| は n = s + T − 1（シンボルの末尾）で最大になる。
// 入力は 1 サンプル 1 クロック以下（valid）。出力は入力と同じサンプル番号で LAT = 4 クロック遅れ。
//
// SPDX-License-Identifier: MIT
// Copyright (c) 2026 k-iseri

`timescale 1ns/100ps

module isdbt_gi_corr #(
  parameter N = 8192,
  parameter NG = 1024
) (
  input                   clk,
  input                   rst,
  input                   valid_in,
  input  signed [7:0]     i_in,
  input  signed [7:0]     q_in,
  input       [31:0]      idx_in,          // サンプル番号（出力に同じ遅延で付けて返す）
  output reg              valid_out,
  output reg signed [27:0] c_re,
  output reg signed [27:0] c_im,
  output reg  [31:0]      mag2,
  output reg  [31:0]      idx_out
);
  // ---- 遅延 N（BRAM、read-first）----
  reg   [15:0]  dly_mem [0:N-1];
  reg   [$clog2(N)-1:0] dly_ptr = 'd0;
  reg   [15:0]  dly_q = 'd0;
  integer ii;
  initial begin
    for (ii = 0; ii < N; ii = ii + 1) dly_mem[ii] = 16'd0;     // BRAM 初期値 0（シミュレーションの X 回避）
  end
  reg   signed [7:0] i_d1 = 'd0, q_d1 = 'd0;
  reg           v1 = 1'b0;
  always @(posedge clk) begin
    v1 <= valid_in;
    if (valid_in) begin
      dly_q <= dly_mem[dly_ptr];
      dly_mem[dly_ptr] <= {q_in, i_in};
      dly_ptr <= (dly_ptr == N - 1) ? 'd0 : dly_ptr + 1'b1;
      i_d1 <= i_in;
      q_d1 <= q_in;
    end
  end

  // ---- 積 p = x · conj(x_N) ----
  wire signed [7:0] in_d = dly_q[7:0];
  wire signed [7:0] qn_d = dly_q[15:8];
  reg   signed [16:0] p_re = 'd0, p_im = 'd0;
  reg           v2 = 1'b0;
  always @(posedge clk) begin
    v2 <= v1;
    if (v1) begin
      p_re <= i_d1 * in_d + q_d1 * qn_d;
      p_im <= q_d1 * in_d - i_d1 * qn_d;
    end
  end

  // ---- 移動和 Ng（積の遅延線 + 累算）----
  reg   [33:0]  pd_mem [0:NG-1];
  reg   [$clog2(NG)-1:0] pd_ptr = 'd0;
  reg   [33:0]  pd_q = 'd0;
  integer jj;
  initial begin
    for (jj = 0; jj < NG; jj = jj + 1) pd_mem[jj] = 34'd0;
  end
  reg   signed [16:0] p_re2 = 'd0, p_im2 = 'd0;
  reg           v3 = 1'b0;
  always @(posedge clk) begin
    v3 <= v2;
    if (v2) begin
      pd_q <= pd_mem[pd_ptr];
      pd_mem[pd_ptr] <= {p_im, p_re};
      pd_ptr <= (pd_ptr == NG - 1) ? 'd0 : pd_ptr + 1'b1;
      p_re2 <= p_re;
      p_im2 <= p_im;
    end
  end
  wire signed [16:0] pold_re = pd_q[16:0];
  wire signed [16:0] pold_im = pd_q[33:17];
  reg   signed [27:0] acc_re = 'd0, acc_im = 'd0;
  reg           v4 = 1'b0;
  reg   [$clog2(NG+N):0] warm = 'd0;     // 遅延線が埋まるまで古い値は 0 扱い
  always @(posedge clk) begin
    if (rst) begin
      acc_re <= 'd0; acc_im <= 'd0; warm <= 'd0; v4 <= 1'b0;
    end else begin
      v4 <= v3;
      if (v3) begin
        if (warm < N + NG) warm <= warm + 1'b1;
        // 足すのは遅延線が埋まってから（warm ≥ N）。リセット直後の N 個の積は x · conj(古い遅延線の内容) で、
        // これを足してしまうと引き算（warm ≥ N + NG から）が決して取り除かず、移動和に一定の複素オフセットが
        // 一生残る。オフセットは信号レベルに依らないので、弱い信号ほど相関ピークの位相（= CFO 推定）を傾け、
        // 等化モードで残留 CFO → ICI になっていた（実波: ゲイン 24 dB で +41 Hz、B 層 MER −4 dB。2026-10-15）。
        // シミュレーションは BRAM 初期値 0 で積も 0 だったため見えなかった
        acc_re <= acc_re + ((warm >= N) ? p_re2 : 17'sd0) - ((warm >= N + NG) ? pold_re : 17'sd0);
        acc_im <= acc_im + ((warm >= N) ? p_im2 : 17'sd0) - ((warm >= N + NG) ? pold_im : 17'sd0);
      end
    end
  end

  // ---- 振幅² ----
  wire signed [15:0] cr16 = acc_re >>> 10;
  wire signed [15:0] ci16 = acc_im >>> 10;
  // 遅延線が埋まるまで（N + Ng サンプル）は出力しない（相関が移動和になっていない）
  always @(posedge clk) begin
    valid_out <= v4 && (warm >= N + NG);
    if (v4) begin
      c_re <= acc_re;
      c_im <= acc_im;
      mag2 <= cr16 * cr16 + ci16 * ci16;
    end
  end
  // ---- サンプル番号を同じ遅延で通す ----
  reg   [31:0]  idx1 = 'd0, idx2 = 'd0, idx3 = 'd0, idx4 = 'd0;
  always @(posedge clk) begin
    if (valid_in) idx1 <= idx_in;
    if (v1) idx2 <= idx1;
    if (v2) idx3 <= idx2;
    if (v3) idx4 <= idx3;
    if (v4) idx_out <= idx4;
  end
endmodule
