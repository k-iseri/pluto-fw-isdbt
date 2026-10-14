// isdbt_regs: pluto-fw-isdbt のレジスタブロック（axi_ad9361 コア内 バイト 0x3000、16 ワード）
//
// v1 の isdbt_sample_counter（0x00〜0x18 は互換）に、前段オフロード（design-v2 2b）の制御を足したもの。
// すべて libiio の iio_device_reg_read/write(dev, 0x80003000 + off) で触れる（カーネル・dts 変更なし）。
//
// オフセット  名前        R/W  内容
//   0x00    MAGIC        R   0x49534442 ("ISDB")。純正コアは 0xDEADDEAD を返す
//   0x04    VERSION      R   2
//   0x08    CNT_LO       R   ADC サンプルカウンタ下位（読むと上位を CNT_HI にラッチ）
//   0x0C    CNT_HI       R   同上位（CNT_LO 読み出し時点）
//   0x10    OVF_CNT      R   adc_dovf 立ち上がり回数
//   0x14    DROP_CNT     R   adc_dovf が 1 だったクロック数 = 捨てた DMA ビート数
//   0x18    FORMAT       R   bit[7:0] = pack8 のシフト量
//   0x1C    CAPS         R   能力ビット: bit0 8bit I/Q、bit1 サンプルカウンタ、bit2 FFT テスト出力、
//                            bit3 等化済みキャリア出力（未実装）、bit4 TS 出力（未実装）
//   0x20    MODE         RW  DMA に流すもの: 0 = raw I/Q（pack8/cpack、既定）、1 = FFT テスト（窓ごとに 8192 ビン）
//   0x24    WIN_STRIDE   RW  窓の開始間隔 [サンプル]（既定 9216 = Mode 3 GI 1/8 のシンボル長）
//   0x28    WIN_OFFSET   RW  最初の窓の開始位置 [サンプル]（MODE を 0→1 にした時点から）
//   0x2C    WIN_DECIM    RW  窓の間引き（n 窓に 1 つ出力。既定 1）。FFT テスト出力は 1 窓 32,800 B なので
//                            公称レートでは 4 以上にしないと USB 2.0 を超える
//   0x30    FE_STATUS    R   bit[15:0] 窓取りこぼし回数（FFT が受け付けなかった）、bit[31:16] 出力 FIFO あふれ回数
//   0x34    FE_FRAMES    R   出力した窓の数
//
// クロック: カウンタと前段制御は ADC クロック（d_clk = l_clk）、レジスタは AXI クロック。
// up → d は up_xfer_cntrl、d → up は up_xfer_status（ADI のハンドシェイク CDC）。
//
// SPDX-License-Identifier: MIT
// Copyright (c) 2026 k-iseri

`timescale 1ns/100ps

module isdbt_regs #(
  parameter [13:0] BASE_ADDR = 14'h0C00,
  parameter [31:0] VERSION = 32'd2,
  parameter [7:0]  PACK_SHIFT = 8'd4,
  parameter [31:0] CAPS = 32'h00000007
) (
  // ADC クロックドメイン
  input                   d_clk,
  input                   d_rst,
  input                   d_valid,
  input                   d_ovf,
  output      [63:0]      d_sample_count,
  output      [3:0]       d_mode,
  output      [15:0]      d_win_stride,
  output      [15:0]      d_win_offset,
  output      [7:0]       d_win_decim,
  input       [31:0]      d_fe_status,
  input       [31:0]      d_fe_frames,

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
  assign d_sample_count = d_cnt;

  // ---- d → up: 192bit ----
  wire  [191:0] up_status_s;
  wire  [63:0]  up_cnt_s = up_status_s[63:0];
  wire  [31:0]  up_ovf_cnt_s = up_status_s[95:64];
  wire  [31:0]  up_drop_cnt_s = up_status_s[127:96];
  wire  [31:0]  up_fe_status_s = up_status_s[159:128];
  wire  [31:0]  up_fe_frames_s = up_status_s[191:160];

  up_xfer_status #(
    .DATA_WIDTH (192)
  ) i_xfer_status (
    .up_rstn (up_rstn),
    .up_clk (up_clk),
    .up_data_status (up_status_s),
    .d_rst (d_rst),
    .d_clk (d_clk),
    .d_data_status ({d_fe_frames, d_fe_status, d_drop_cnt, d_ovf_cnt, d_cnt}));

  // ---- up → d: 制御 44bit ----
  reg   [3:0]   up_mode = 4'd0;
  reg   [15:0]  up_win_stride = 16'd9216;
  reg   [15:0]  up_win_offset = 16'd0;
  reg   [7:0]   up_win_decim = 8'd1;

  up_xfer_cntrl #(
    .DATA_WIDTH (44)
  ) i_xfer_cntrl (
    .up_rstn (up_rstn),
    .up_clk (up_clk),
    .up_data_cntrl ({up_win_decim, up_win_offset, up_win_stride, up_mode}),
    .up_xfer_done (),
    .d_rst (d_rst),
    .d_clk (d_clk),
    .d_data_cntrl ({d_win_decim, d_win_offset, d_win_stride, d_mode}));

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
      up_mode <= 4'd0;
      up_win_stride <= 16'd9216;
      up_win_offset <= 16'd0;
      up_win_decim <= 8'd1;
    end else begin
      up_wack <= up_wreq_s;
      up_rack <= up_rreq_s;
      if (up_wreq_s == 1'b1) begin
        case (up_waddr[3:0])
          4'h8: up_mode <= up_wdata[3:0];
          4'h9: up_win_stride <= up_wdata[15:0];
          4'hA: up_win_offset <= up_wdata[15:0];
          4'hB: up_win_decim <= (up_wdata[7:0] == 8'd0) ? 8'd1 : up_wdata[7:0];
          default: ;
        endcase
      end
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
          4'h7: up_rdata <= CAPS;
          4'h8: up_rdata <= {28'd0, up_mode};
          4'h9: up_rdata <= {16'd0, up_win_stride};
          4'hA: up_rdata <= {16'd0, up_win_offset};
          4'hB: up_rdata <= {24'd0, up_win_decim};
          4'hC: up_rdata <= up_fe_status_s;
          4'hD: up_rdata <= up_fe_frames_s;
          default: up_rdata <= 32'd0;
        endcase
      end else begin
        up_rdata <= 32'd0;
      end
    end
  end

endmodule
