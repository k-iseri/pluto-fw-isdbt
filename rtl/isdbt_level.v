// ADC レベル計: pack8 後の 8bit I/Q（ホストが raw モードで受けるのと同じ値）の I² + Q² を 65536 サンプル積算し、
// 積算し終わるたびに level へ出す（≈ 8 ms ごと）。最大 2 × 127² × 65536 < 2^32 なので 32bit に収まる。
// ホストはモード 3/4（前段動作中で raw I/Q が来ない）でもこれを読んでソフト AGC を回す:
//   dBFS = 10 log10( level / 65536 × (2^PACK_SHIFT / 2048)² )   （raw モードの level_dbfs と同じ定義）
// レジスタ 0x54 ADC_LEVEL（isdbt_regs、VERSION 4、CAPS bit4）。
// SPDX-License-Identifier: MIT
// Copyright (c) 2026 k-iseri

`timescale 1ns/100ps

module isdbt_level (
  input                   clk,
  input                   rst,
  input                   valid,
  input       [7:0]       i_in,
  input       [7:0]       q_in,
  output reg  [31:0]      level
);

  // pack8 の丸め・飽和論理と二乗が一続きだと rx_clk（16.27 ns）に収まらない（−0.88 ns）ので、入力をまず受ける
  reg signed [7:0] si = 'd0, sq = 'd0;
  reg           v_r = 1'b0;
  (* use_dsp = "yes" *) reg [15:0] p = 'd0;   // i² + q² ≤ 32258
  reg           p_valid = 1'b0;
  reg   [15:0]  cnt = 'd0;
  reg   [31:0]  acc = 'd0;

  always @(posedge clk) begin
    if (rst) begin
      si <= 'd0;
      sq <= 'd0;
      v_r <= 1'b0;
      p <= 'd0;
      p_valid <= 1'b0;
      cnt <= 'd0;
      acc <= 'd0;
      level <= 'd0;
    end else begin
      si <= i_in;
      sq <= q_in;
      v_r <= valid;
      p <= si * si + sq * sq;
      p_valid <= v_r;
      if (p_valid) begin
        if (cnt == 16'hFFFF) begin
          level <= acc + {16'd0, p};
          acc <= 'd0;
          cnt <= 'd0;
        end else begin
          acc <= acc + {16'd0, p};
          cnt <= cnt + 1'b1;
        end
      end
    end
  end

endmodule
