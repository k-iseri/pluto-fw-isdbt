// isdbt_fe_win: 前段の窓切り出し（FFT 入力生成）
//
// ADC サンプル列（adc_valid でサンプルごとに 1 パルス、12bit 符号拡張 16bit の I/Q）から、
// 開始位置 offset + k*stride、長さ N の窓を切り出して AXI-Stream（{Q,I} 32bit、tlast で窓末尾）として
// Xilinx FFT IP（pipelined streaming、forward、BFP）に流す。窓ごとに 64bit サンプルカウンタ値と連番を
// ヘッダ FIFO に積み、出力側（isdbt_fe_out）が対応する FFT 出力フレームに付ける。
//
// enable が 0 のときは何もしない（モード 0）。enable を立てた時点のサンプルを位置 0 として offset を数える。
// 窓は decim 個に 1 個だけ FFT に送る（USB 帯域に合わせた間引き）。
// FFT が tready を落として（設定前など）サンプルを受け取れなかった窓は捨てて overrun を数える
//（ADC 側はバックプレッシャできないので）。
//
// FFT IP の設定は起動時に 1 回（s_axis_config: forward）。ゲート間（stride - N サンプル）は tvalid を落とす。
// FFT IP（realtime）はフレームの最初のサンプルを受けた直後に 1 サイクル tready を落とす（xsim で確認。
// 無視すると 2 サンプル目が欠けて末尾が重複する）ので、窓のサンプルは小さな FIFO に入れてから
// AXI-Stream の作法どおり tready を見て出す。窓間の空きで追いつく。
//
// SPDX-License-Identifier: MIT
// Copyright (c) 2026 k-iseri

`timescale 1ns/100ps

module isdbt_fe_win #(
  parameter N = 8192,
  parameter HDR_DEPTH = 4          // ヘッダ FIFO の深さ（FFT の滞留フレーム数 + 1）
) (
  input                   clk,
  input                   rst,
  input                   enable,
  input       [15:0]      stride,
  input       [15:0]      offset,
  input       [7:0]       decim,
  input       [63:0]      sample_count,

  input                   adc_valid,
  input       [15:0]      adc_i,
  input       [15:0]      adc_q,

  // FFT 設定（forward のみ）
  output reg  [7:0]       cfg_tdata,
  output reg              cfg_tvalid,
  input                   cfg_tready,

  // FFT データ入力
  output      [31:0]      s_tdata,
  output                  s_tvalid,
  output                  s_tlast,
  input                   s_tready,

  // ヘッダ FIFO（出力側が frame_pop で 1 つ取り出す）
  input                   hdr_pop,
  output      [63:0]      hdr_start,
  output      [31:0]      hdr_seq,
  output                  hdr_valid,

  output reg  [15:0]      overrun_count
);

  // ---- FFT 設定 ----
  reg cfg_done = 1'b0;
  always @(posedge clk) begin
    if (rst) begin
      cfg_tvalid <= 1'b0;
      cfg_tdata <= 8'd1;        // bit0 = FWD_INV (1 = forward)
      cfg_done <= 1'b0;
    end else if (!cfg_done) begin
      cfg_tvalid <= 1'b1;
      if (cfg_tvalid && cfg_tready) begin
        cfg_tvalid <= 1'b0;
        cfg_done <= 1'b1;
      end
    end
  end

  // ---- 窓タイミング ----
  reg   [31:0]  pos = 'd0;            // enable 以降のサンプル位置
  reg   [31:0]  next_start = 'd0;     // 次の窓の開始位置
  reg   [13:0]  in_win = 'd0;         // 窓内の残りサンプル数（0 = 窓外）
  reg   [7:0]   decim_cnt = 'd0;
  reg   [31:0]  seq = 'd0;
  reg           enable_d = 1'b0;
  reg           win_bad = 1'b0;       // この窓で FFT が受け取れなかった

  // ヘッダ FIFO（小さいのでレジスタ）
  reg   [63:0]  hf_start [0:HDR_DEPTH-1];
  reg   [31:0]  hf_seq [0:HDR_DEPTH-1];
  reg   [$clog2(HDR_DEPTH):0] hf_wr = 'd0, hf_rd = 'd0;
  wire  hf_empty = (hf_wr == hf_rd);
  wire  [$clog2(HDR_DEPTH)-1:0] hf_wr_i = hf_wr[$clog2(HDR_DEPTH)-1:0];
  wire  [$clog2(HDR_DEPTH)-1:0] hf_rd_i = hf_rd[$clog2(HDR_DEPTH)-1:0];
  assign hdr_valid = !hf_empty;
  assign hdr_start = hf_start[hf_rd_i];
  assign hdr_seq = hf_seq[hf_rd_i];

  wire emit_this = (decim_cnt == 8'd0);

  // ---- サンプル FIFO（窓エンジン → FFT、tready を守る）----
  localparam SF_AW = 5;                       // 深さ 32
  reg   [32:0]  sf_mem [0:(1<<SF_AW)-1];      // {last, q, i}
  reg   [SF_AW:0] sf_wr = 'd0, sf_rd = 'd0;
  wire          sf_empty = (sf_wr == sf_rd);
  wire          sf_full = ((sf_wr - sf_rd) == (1 << SF_AW));
  wire  [32:0]  sf_q = sf_mem[sf_rd[SF_AW-1:0]];
  assign s_tvalid = !sf_empty;
  assign s_tdata = sf_q[31:0];
  assign s_tlast = sf_q[32];
  reg           sf_push;
  reg   [32:0]  sf_din;

  always @(posedge clk) begin
    if (rst || !enable) begin
      sf_rd <= 'd0;
    end else if (s_tvalid && s_tready) begin
      sf_rd <= sf_rd + 1'b1;
    end
  end

  always @(posedge clk) begin
    if (rst || !enable) begin
      pos <= 'd0;
      next_start <= {16'd0, offset};
      in_win <= 'd0;
      decim_cnt <= 'd0;
      seq <= 'd0;
      overrun_count <= 'd0;
      hf_wr <= 'd0;
      hf_rd <= 'd0;
      win_bad <= 1'b0;
      sf_wr <= 'd0;
    end else begin
      if (hdr_pop && !hf_empty) hf_rd <= hf_rd + 1'b1;
      sf_push = 1'b0;
      sf_din = {1'b0, adc_q, adc_i};
      if (adc_valid) begin
        pos <= pos + 1'b1;
        if (in_win != 0) begin
          // 窓の途中
          sf_push = 1'b1;
          sf_din[32] = (in_win == 14'd1);
          in_win <= in_win - 1'b1;
          if (in_win == 14'd1) begin
            if (win_bad || sf_full) overrun_count <= overrun_count + 1'b1;
          end
        end else if (pos == next_start) begin
          next_start <= next_start + {16'd0, stride};
          if (emit_this && cfg_done) begin
            // 窓の先頭: ヘッダを積んで最初のサンプルを出す
            sf_push = 1'b1;
            in_win <= N - 1;
            win_bad <= 1'b0;
            hf_start[hf_wr_i] <= sample_count;
            hf_seq[hf_wr_i] <= seq;
            hf_wr <= hf_wr + 1'b1;
            seq <= seq + 1'b1;
          end
          decim_cnt <= (decim_cnt + 1'b1 >= decim) ? 8'd0 : decim_cnt + 1'b1;
        end
      end
      if (sf_push) begin
        if (sf_full) begin
          win_bad <= 1'b1;               // FFT が追いつかず FIFO があふれた（窓不良）
        end else begin
          sf_mem[sf_wr[SF_AW-1:0]] <= sf_din;
          sf_wr <= sf_wr + 1'b1;
        end
      end
    end
  end

endmodule
