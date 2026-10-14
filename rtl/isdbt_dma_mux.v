// isdbt_dma_mux: ADC DMA（axi_dmac fifo_wr）の入力を、モード 0 = cpack（raw I/Q）、
// それ以外 = isdbt_fe_out（前段出力）で切り替える。DMA からの overflow は両方へ返す。
//
// SPDX-License-Identifier: MIT
// Copyright (c) 2026 k-iseri

`timescale 1ns/100ps

module isdbt_dma_mux (
  input       [3:0]   mode,
  // cpack 側
  input               a_wr_en,
  input       [31:0]  a_wr_data,
  input               a_sync,
  output              a_overflow,
  // 前段側
  input               b_wr_en,
  input       [31:0]  b_wr_data,
  output              b_overflow,
  // DMA 側
  output              fifo_wr_en,
  output      [31:0]  fifo_wr_din,
  output              fifo_wr_sync,
  input               fifo_wr_overflow
);

  wire sel_b = (mode != 4'd0);
  assign fifo_wr_en = sel_b ? b_wr_en : a_wr_en;
  assign fifo_wr_din = sel_b ? b_wr_data : a_wr_data;
  assign fifo_wr_sync = sel_b ? 1'b1 : a_sync;
  assign a_overflow = fifo_wr_overflow;
  assign b_overflow = fifo_wr_overflow;

endmodule
