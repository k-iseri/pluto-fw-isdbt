// isdbt_fe_win + isdbt_fe_out のフレーミング検証（xsim）。FFT IP の代わりに「入力をそのまま遅延して返す」
// 振る舞いモデルを挟み、DMA 出力のヘッダ・連番・サンプルカウンタ・ビン数・間引きを確認する。
//   xvlog -sv isdbt_fe_win.v isdbt_fe_out.v isdbt_fe_tb.v && xelab isdbt_fe_tb -s tb && xsim tb -R
// SPDX-License-Identifier: MIT

`timescale 1ns/100ps

module isdbt_fe_tb;
  localparam N = 64;                 // 短い窓でテスト
  reg clk = 0; always #5 clk = ~clk;
  reg rst = 1;
  reg enable = 0;
  reg [15:0] stride = 16'd80, offset = 16'd10;
  reg [7:0] decim = 8'd2;
  reg [63:0] sample_count = 64'd1000;
  reg adc_valid = 0;
  reg [15:0] adc_i = 0, adc_q = 0;

  wire [7:0] cfg_tdata; wire cfg_tvalid; reg cfg_tready = 0;
  wire [31:0] s_tdata; wire s_tvalid, s_tlast; wire s_tready = 1'b1;
  wire hdr_pop; wire [63:0] hdr_start; wire [31:0] hdr_seq; wire hdr_valid;
  wire [15:0] overrun;

  isdbt_fe_win #(.N(N)) win (
    .clk(clk), .rst(rst), .mode({3'd0, enable}), .stride(stride), .offset(offset), .decim(decim),
    .sample_count(sample_count), .adc_valid(adc_valid), .adc_i(adc_i), .adc_q(adc_q),
    .start_valid(1'b0), .start_pos(32'd0),
    .cfg_tdata(cfg_tdata), .cfg_tvalid(cfg_tvalid), .cfg_tready(cfg_tready),
    .s_tdata(s_tdata), .s_tvalid(s_tvalid), .s_tlast(s_tlast), .s_tready(s_tready),
    .hdr_pop(hdr_pop), .hdr_start(hdr_start), .hdr_seq(hdr_seq), .hdr_valid(hdr_valid),
    .overrun_count(overrun));

  // FFT の振る舞いモデル: 100 サイクル遅延で入力をそのまま返す。blk_exp = 5
  reg [31:0] dly_d [0:127]; reg dly_v [0:127]; reg dly_l [0:127];
  integer di;
  initial for (di = 0; di < 128; di = di + 1) begin dly_v[di] = 0; dly_l[di] = 0; dly_d[di] = 0; end
  reg [6:0] wp = 0;
  wire [6:0] rp = wp - 7'd100;
  wire [31:0] m_tdata = dly_d[rp]; wire m_tvalid = dly_v[rp]; wire m_tlast = dly_l[rp];
  wire [23:0] m_tuser = {3'd0, 5'd5, 16'd0};
  always @(posedge clk) begin
    dly_d[wp] <= s_tdata; dly_v[wp] <= s_tvalid; dly_l[wp] <= s_tlast; wp <= wp + 1'b1;
  end

  wire dma_en; wire [31:0] dma_data; wire [15:0] fovf; wire [31:0] frames;
  isdbt_fe_out #(.N(N), .FIFO_DEPTH(512)) outp (
    .clk(clk), .rst(rst), .mode({3'd0, enable}),
    .m_tdata(m_tdata), .m_tuser(m_tuser), .m_tvalid(m_tvalid), .m_tlast(m_tlast),
    .hdr_start(hdr_start), .hdr_seq(hdr_seq), .hdr_valid(hdr_valid), .hdr_pop(hdr_pop),
    .info_a(32'd0), .info_b(32'd0),
    .dma_wr_en(dma_en), .dma_wr_data(dma_data), .fifo_overflow_count(fovf), .frames_out(frames));

  // DMA 出力を集めてチェック
  reg [31:0] got [0:4095]; integer ng = 0;
  always @(posedge clk) if (dma_en) begin got[ng] <= dma_data; ng <= ng + 1; end

  integer t, errors = 0, k, w, base;
  initial begin
    #20 rst = 0;
    #20 cfg_tready = 1;
    #20 enable = 1;
    // サンプル列: i = pos, q = -pos。4 サイクルに 1 サンプル
    for (t = 0; t < 600; t = t + 1) begin
      @(posedge clk); adc_valid <= 1; adc_i <= t; adc_q <= -t; sample_count <= 64'd1000 + t;
      @(posedge clk); adc_valid <= 0;
      @(posedge clk); @(posedge clk);
    end
    repeat (300) @(posedge clk);
    // 期待: 窓開始 10, 90, 170, 250, 330, 410, 490 のうち decim=2 で 10, 170, 330, 490 → 4 窓（最後は 600 未満で完結: 490+64=554 OK）
    $display("frames_out=%0d words=%0d overrun=%0d fifo_ovf=%0d", frames, ng, overrun, fovf);
    if (frames !== 4) begin errors = errors + 1; $display("FAIL frames"); end
    for (w = 0; w < 4; w = w + 1) begin
      base = w * (8 + N);
      if (got[base] !== 32'h49534254) begin errors = errors + 1; $display("FAIL magic w%0d", w); end
      if (got[base + 1][23:16] !== 8'd5) begin errors = errors + 1; $display("FAIL exp w%0d: %h", w, got[base + 1]); end
      if (got[base + 2] !== (1000 + 10 + w * 160)) begin errors = errors + 1; $display("FAIL start w%0d: %0d", w, got[base + 2]); end
      if (got[base + 4] !== w) begin errors = errors + 1; $display("FAIL seq w%0d", w); end
      if (got[base + 5] !== N) begin errors = errors + 1; $display("FAIL N w%0d", w); end
      for (k = 0; k < N; k = k + 1) begin
        if (got[base + 8 + k] !== {16'(-(10 + w * 160 + k)), 16'(10 + w * 160 + k)}) begin
          errors = errors + 1;
          if (errors < 6) $display("FAIL data w%0d k%0d: %h", w, k, got[base + 8 + k]);
        end
      end
    end
    if (errors == 0) $display("PASS"); else $display("FAIL: %0d errors", errors);
    $finish;
  end
endmodule
