// isdbt_sample_counter: ADC サンプルの 64bit フリーランニングカウンタと overflow 回数
//
// サンプル落ち（USB 帯域不足で DMA が受けきれなかった分）を「何サンプル欠けたか」で定量化する
// ための小さなレジスタブロック。axi_ad9361 コアの未使用アドレス（ワード 0x0C00 = バイト 0x3000、
// cf-ad9361-lpc の devicetree 窓 0x6000 の内側）に置くので、カーネルも dts も変更せずに
// libiio の iio_device_reg_read(dev, 0x80003000 + off) で読める。
//
// ホストは 10 秒ごとに CNT を読み、受信済みサンプル総数との差分の増加分をハード確定ドロップとする。
// overflow 検出そのものはコア既存の UI_STATUS.UI_OVF（RW1C）で足りるので、ここでは回数だけ数える。
//
// レジスタ（32bit、ベースからのバイトオフセット。すべて読み出し専用）:
//   0x00  MAGIC    0x49534442 ("ISDB")。本ファーム識別を兼ねる（純正コアは 0 を返す）
//   0x04  VERSION  1
//   0x08  CNT_LO   サンプルカウンタ下位 32bit。読むと同時に上位 32bit を CNT_HI にラッチする
//   0x0C  CNT_HI   CNT_LO 読み出し時点の上位 32bit（LO → HI の順に読めば 64bit が整合する）
//   0x10  OVF_CNT  adc_dovf の立ち上がり回数（32bit、ラップ）= overflow イベント数
//   0x14  DROP_CNT adc_dovf が 1 だったクロック数（32bit、ラップ）= 捨てられた DMA ビート数。
//                  axi_dmac は受け取れないビートごとに fifo_wr_overflow を 1 クロック立てるので、
//                  これが落ちたサンプル数の実体。1R1T ではビート = 複素 2 サンプル（16bit: 64bit
//                  ワード、8bit: 32bit ワードのどちらも）なので、ホストは ×2 してサンプル数にする
//   0x18  FORMAT   bit[7:0] = pack8 の右シフト量（PACK_SHIFT）。8bit サンプル値 v に対する ADC 12bit
//                  フルスケール換算は v × 2^PACK_SHIFT / 2048。4 = 素直な 12→8bit、3 = +6 dB の
//                  デジタル前置ゲイン（8bit 量子化雑音を 6 dB 下げる。ADC −6 dBFS 以上で飽和）
//
// クロック: カウンタは ADC クロック（l_clk）、レジスタは AXI クロック。128bit を up_xfer_status
//（ADI の ハンドシェイク式 CDC）でまとめて渡すので、読み出し値は数十クロック遅れるが整合している。
//
// SPDX-License-Identifier: MIT
// Copyright (c) 2026 k-iseri

`timescale 1ns/100ps

module isdbt_sample_counter #(
  parameter [13:0] BASE_ADDR = 14'h0C00,   // ワードアドレス（up_axi の 14bit）。16 ワード占有
  parameter [31:0] VERSION = 32'd1,
  parameter [7:0]  PACK_SHIFT = 8'd4       // FORMAT レジスタで申告する pack8 のシフト量
) (
  // ADC クロックドメイン
  input                   d_clk,
  input                   d_rst,
  input                   d_valid,          // 1 サンプルごとに 1 パルス（adc_valid_i0）
  input                   d_ovf,            // adc_dovf

  // プロセッサインターフェース（axi_ad9361 内部バス）
  input                   up_rstn,
  input                   up_clk,
  input                   up_wreq,
  input       [13:0]      up_waddr,
  input       [31:0]      up_wdata,
  output reg              up_wack,
  input                   up_rreq,
  input       [13:0]      up_raddr,
  output reg  [31:0]      up_rdata,
  output reg              up_rack
);

  localparam [31:0] MAGIC = 32'h49534442;

  // ---- ADC ドメイン: カウンタ ----
  reg   [63:0]  d_cnt = 'd0;
  reg   [31:0]  d_ovf_cnt = 'd0;
  reg   [31:0]  d_drop_cnt = 'd0;
  reg           d_ovf_d = 1'b0;

  always @(posedge d_clk) begin
    if (d_rst == 1'b1) begin
      d_cnt <= 'd0;
      d_ovf_cnt <= 'd0;
      d_drop_cnt <= 'd0;
      d_ovf_d <= 1'b0;
    end else begin
      if (d_valid == 1'b1) d_cnt <= d_cnt + 1'b1;
      d_ovf_d <= d_ovf;
      if (d_ovf == 1'b1 && d_ovf_d == 1'b0) d_ovf_cnt <= d_ovf_cnt + 1'b1;
      if (d_ovf == 1'b1) d_drop_cnt <= d_drop_cnt + 1'b1;
    end
  end

  // ---- CDC: 128bit をまとめて up ドメインへ ----
  wire  [127:0] up_status_s;
  wire  [63:0]  up_cnt_s = up_status_s[63:0];
  wire  [31:0]  up_ovf_cnt_s = up_status_s[95:64];
  wire  [31:0]  up_drop_cnt_s = up_status_s[127:96];

  up_xfer_status #(
    .DATA_WIDTH (128)
  ) i_xfer_status (
    .up_rstn (up_rstn),
    .up_clk (up_clk),
    .up_data_status (up_status_s),
    .d_rst (d_rst),
    .d_clk (d_clk),
    .d_data_status ({d_drop_cnt, d_ovf_cnt, d_cnt}));

  // ---- レジスタ読み書き ----
  wire          up_wreq_s = (up_waddr[13:4] == BASE_ADDR[13:4]) ? up_wreq : 1'b0;
  wire          up_rreq_s = (up_raddr[13:4] == BASE_ADDR[13:4]) ? up_rreq : 1'b0;
  reg   [31:0]  up_cnt_hi_latched = 'd0;

  always @(negedge up_rstn or posedge up_clk) begin
    if (up_rstn == 1'b0) begin
      up_wack <= 1'b0;
      up_rack <= 1'b0;
      up_rdata <= 'd0;
      up_cnt_hi_latched <= 'd0;
    end else begin
      up_wack <= up_wreq_s;         // 書き込みは受け付けるが無視する（全レジスタ RO）
      up_rack <= up_rreq_s;
      if (up_rreq_s == 1'b1) begin
        case (up_raddr[3:0])
          4'h0: up_rdata <= MAGIC;
          4'h1: up_rdata <= VERSION;
          4'h2: begin
            up_rdata <= up_cnt_s[31:0];
            up_cnt_hi_latched <= up_cnt_s[63:32];
          end
          4'h3: up_rdata <= up_cnt_hi_latched;
          4'h4: up_rdata <= up_ovf_cnt_s;
          4'h5: up_rdata <= up_drop_cnt_s;
          4'h6: up_rdata <= {24'd0, PACK_SHIFT};
          default: up_rdata <= 32'd0;
        endcase
      end else begin
        up_rdata <= 32'd0;          // 親が OR で束ねるので非選択時は 0
      end
    end
  end

endmodule
