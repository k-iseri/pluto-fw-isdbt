// isdbt_fe_out: FFT 出力フレームにヘッダを付けて DMA（axi_dmac の fifo_wr インターフェース）へ流す
//
// FFT IP（pipelined streaming、real-time = バックプレッシャ不可）の出力 {Q,I} 32bit を、窓ごとに
// 8 ワードのヘッダ + N ワードのビンとして出力 FIFO（BRAM、深さ FIFO_DEPTH ワード）に書き、FIFO から
// DMA へ 1 ワード/クロックで読み出す。ヘッダの挿入で書き込みが 8 サイクル遅れるので入力側に小さな
// スキッドバッファを置く（窓の間には stride - N サイクルの空きがある）。
//
// 出力フォーマット（32bit リトルエンディアンのワード列、1 窓 = 8 + N ワード）:
//   w0  0x49534254 ("ISBT")
//   w1  {fmt[7:0], blk_exp[7:0], flags[7:0], mode[7:0]}   flags: bit0 = FIFO あふれで途中が欠けた
//       fmt: 0 = ビンは {Q16, I16} 1 ワード、1 = 8bit（12bit を丸めて 8bit、{Q8_1, I8_1, Q8_0, I8_0} = 2 ビン/ワード、N/2 ワード）
//   w2  窓開始サンプルカウンタ下位 32bit
//   w3  同上位 32bit
//   w4  窓の連番
//   w5  N
//   w6  0
//   w7  0
//   w8.. ビン k=0..N-1 の {Q[31:16], I[15:0]}（自然順）
//
// SPDX-License-Identifier: MIT
// Copyright (c) 2026 k-iseri

`timescale 1ns/100ps

module isdbt_fe_out #(
  parameter N = 8192,
  parameter FIFO_DEPTH = 16384,        // 2 窓分
  parameter EXP_LSB = 16,              // m_tuser の blk_exp の位置（XK_INDEX 13bit → 16bit 境界の次）
  parameter FFT_W = 12                 // FFT のデータ幅。16 未満なら各成分を 16bit に符号拡張して出す
) (
  input                   clk,
  input                   rst,
  input       [3:0]       mode,            // 0 = 停止

  // FFT 出力
  input       [31:0]      m_tdata,
  input       [23:0]      m_tuser,
  input                   m_tvalid,
  input                   m_tlast,

  // ヘッダ FIFO（isdbt_fe_win）
  input       [63:0]      hdr_start,
  input       [31:0]      hdr_seq,
  input                   hdr_valid,
  output reg              hdr_pop,
  // ヘッダ w6 / w7 に入れる付加情報（窓の先頭でラッチ。同期モードでは CFO 増分とロック状態）
  input       [31:0]      info_a,
  input       [31:0]      info_b,

  // DMA へ
  output reg              dma_wr_en,
  output reg  [31:0]      dma_wr_data,
  output reg  [15:0]      fifo_overflow_count,
  output reg  [31:0]      frames_out
);

  wire enable = (mode != 4'd0);
  wire pack8 = (mode == 4'd3);        // ビンを 8bit × 2 で出す（モード 3）
  // 12bit（FFT_W）→ 8bit: 丸めて飽和
  function [7:0] to8;
    input signed [15:0] v;
    reg signed [15:0] r;
    begin
      r = (v + (1 << (FFT_W - 9))) >>> (FFT_W - 8);
      to8 = (r > 127) ? 8'd127 : (r < -128) ? 8'h80 : r[7:0];
    end
  endfunction

  // ---- 入力スキッド FIFO（分散 RAM、深さ 32）----
  reg   [32:0]  sk_mem [0:31];          // {last, data}
  reg   [5:0]   sk_wr = 'd0, sk_rd = 'd0;
  wire          sk_empty = (sk_wr == sk_rd);
  wire  [32:0]  sk_q = sk_mem[sk_rd[4:0]];
  reg   [7:0]   blk_exp_q = 'd0;
  reg           frame_first = 1'b1;     // 次に来る m_tvalid は窓の先頭
  reg   [7:0]   exp_fifo [0:3];
  reg   [2:0]   exp_wr = 'd0, exp_rd = 'd0;

  // FFT 出力の各成分を 16bit に符号拡張（IP の上位パディングは当てにしない）
  wire signed [15:0] m_i = $signed(m_tdata[FFT_W-1:0]);
  wire signed [15:0] m_q = $signed(m_tdata[16+FFT_W-1:16]);
  wire [31:0] m_tdata_sx = {m_q, m_i};

  always @(posedge clk) begin
    if (rst) begin
      sk_wr <= 'd0;
      frame_first <= 1'b1;
      exp_wr <= 'd0;
    end else if (m_tvalid) begin
      sk_mem[sk_wr[4:0]] <= {m_tlast, m_tdata_sx};
      sk_wr <= sk_wr + 1'b1;
      if (frame_first) begin
        exp_fifo[exp_wr[1:0]] <= m_tuser[EXP_LSB +: 8];
        exp_wr <= exp_wr + 1'b1;
      end
      frame_first <= m_tlast;
    end
  end

  // ---- 出力 FIFO（BRAM）----
  localparam AW = $clog2(FIFO_DEPTH);
  reg   [31:0]  fifo_mem [0:FIFO_DEPTH-1];
  reg   [AW:0]  f_wr = 'd0, f_rd = 'd0;
  wire  [AW:0]  f_count = f_wr - f_rd;
  wire          f_full = f_count[AW];
  wire          f_empty = (f_wr == f_rd);
  reg   [31:0]  f_q = 'd0;

  // ---- 書き込み側ステートマシン ----
  reg   [3:0]   hdr_idx = 'd0;          // 0..7 ヘッダ送出中、8 = データ
  reg           in_frame = 1'b0;
  reg           dropped = 1'b0;
  reg   [63:0]  cur_start = 'd0;
  reg   [31:0]  cur_seq = 'd0;
  reg   [7:0]   cur_exp = 'd0;
  reg   [31:0]  cur_a = 'd0, cur_b = 'd0;
  reg   [31:0]  hdr_word;

  always @(*) begin
    case (hdr_idx)
      4'd0: hdr_word = 32'h49534254;
      4'd1: hdr_word = {7'd0, pack8, cur_exp, 7'd0, dropped, 4'd0, mode};
      4'd2: hdr_word = cur_start[31:0];
      4'd3: hdr_word = cur_start[63:32];
      4'd4: hdr_word = cur_seq;
      4'd5: hdr_word = N;
      4'd6: hdr_word = cur_a;
      4'd7: hdr_word = cur_b;
      default: hdr_word = 32'd0;
    endcase
  end

  wire  sk_last = sk_q[32];
  reg   [15:0]  pk_lo = 'd0;          // 8bit パッキングの前半ビン
  reg           pk_half = 1'b0;
  wire  [15:0]  pk_cur = {to8(sk_q[31:16]), to8(sk_q[15:0])};
  always @(posedge clk) begin
    hdr_pop <= 1'b0;
    if (rst || !enable) begin
      f_wr <= 'd0;
      hdr_idx <= 'd0;
      in_frame <= 1'b0;
      dropped <= 1'b0;
      sk_rd <= 'd0;
      exp_rd <= 'd0;
      fifo_overflow_count <= 'd0;
      frames_out <= 'd0;
    end else if (!in_frame) begin
      // 窓の先頭データが来ていて、ヘッダ情報と blk_exp が揃っていればヘッダ送出を始める
      if (!sk_empty && hdr_valid && (exp_wr != exp_rd)) begin
        cur_start <= hdr_start;
        cur_seq <= hdr_seq;
        cur_a <= info_a;
        cur_b <= info_b;
        cur_exp <= exp_fifo[exp_rd[1:0]];
        exp_rd <= exp_rd + 1'b1;
        hdr_pop <= 1'b1;
        in_frame <= 1'b1;
        hdr_idx <= 'd0;
        dropped <= 1'b0;
      end
    end else if (hdr_idx != 4'd8) begin
      if (!f_full) begin
        fifo_mem[f_wr[AW-1:0]] <= hdr_word;
        f_wr <= f_wr + 1'b1;
      end else begin
        dropped <= 1'b1;
      end
      hdr_idx <= hdr_idx + 1'b1;
    end else if (!sk_empty) begin
      if (pack8 && !pk_half && !sk_last) begin
        pk_lo <= pk_cur;                // 前半ビンを保持
        pk_half <= 1'b1;
      end else begin
        if (!f_full) begin
          fifo_mem[f_wr[AW-1:0]] <= pack8 ? (pk_half ? {pk_cur, pk_lo} : {16'd0, pk_cur}) : sk_q[31:0];
          f_wr <= f_wr + 1'b1;
        end else begin
          dropped <= 1'b1;
        end
        pk_half <= 1'b0;
      end
      sk_rd <= sk_rd + 1'b1;
      if (sk_last) begin
        in_frame <= 1'b0;
        pk_half <= 1'b0;
        frames_out <= frames_out + 1'b1;
        if (dropped) fifo_overflow_count <= fifo_overflow_count + 1'b1;
      end
    end
  end

  // ---- 読み出し側 → DMA（1 ワード/クロック）----
  always @(posedge clk) begin
    if (rst || !enable) begin
      f_rd <= 'd0;
      dma_wr_en <= 1'b0;
    end else begin
      dma_wr_en <= 1'b0;
      if (!f_empty) begin
        dma_wr_data <= fifo_mem[f_rd[AW-1:0]];
        dma_wr_en <= 1'b1;
        f_rd <= f_rd + 1'b1;
      end
    end
  end

endmodule
