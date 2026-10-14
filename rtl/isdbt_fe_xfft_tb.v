// isdbt_fe_win + 実物の Xilinx FFT IP（xfft_8192）+ isdbt_fe_out を xsim で回し、
// 入力窓と FFT 出力をファイルに書く（Python 側で ifft して照合する）。
//   scripts/sim_fe_xfft.tcl から起動
// SPDX-License-Identifier: MIT

`timescale 1ns/1ps

module isdbt_fe_xfft_tb;
  localparam N = 8192;
  localparam STRIDE = 9216;
  reg clk = 0; always #5 clk = ~clk;
  reg rst = 1;
  wire fft_aresetn;
  reg enable = 0;
  reg [15:0] stride = STRIDE, offset = 16'd100;
  reg [7:0] decim = 8'd1;
  reg [63:0] sample_count = 64'd0;
  reg adc_valid = 0;
  reg [15:0] adc_i = 0, adc_q = 0;

  wire [7:0] cfg_tdata; wire cfg_tvalid, cfg_tready;
  wire [31:0] s_tdata; wire s_tvalid, s_tlast, s_tready;
  wire hdr_pop; wire [63:0] hdr_start; wire [31:0] hdr_seq; wire hdr_valid;
  wire [15:0] overrun;
  wire [31:0] m_tdata; wire [23:0] m_tuser; wire m_tvalid, m_tlast;
  wire ev_fs, ev_tlu, ev_tlm, ev_halt;

  // 実機と同じく CORDIC 回転器（位相 0）を通す（スケール・遅延・飽和の検証）
  wire r_valid; wire signed [15:0] r_i, r_q; wire [31:0] r_idx;
  isdbt_rotate rot (
    .clk(clk), .mode({3'd0, enable}), .valid_in(adc_valid), .x_in(adc_i), .y_in(adc_q), .phase_in(32'd0), .idx_in(sample_count[31:0]),
    .valid_out(r_valid), .x_out(r_i), .y_out(r_q), .idx_out(r_idx));

  isdbt_fe_win #(.N(N)) win (
    .clk(clk), .rst(rst), .mode({3'd0, enable}), .stride(stride), .offset(offset), .decim(decim),
    .sample_count({32'd0, r_idx}), .adc_valid(r_valid), .adc_i(r_i), .adc_q(r_q),
    .start_valid(1'b0), .start_pos(32'd0),
    .cfg_tdata(cfg_tdata), .cfg_tvalid(cfg_tvalid), .cfg_tready(cfg_tready), .fft_aresetn(fft_aresetn),
    .s_tdata(s_tdata), .s_tvalid(s_tvalid), .s_tlast(s_tlast), .s_tready(s_tready),
    .hdr_pop(hdr_pop), .hdr_start(hdr_start), .hdr_seq(hdr_seq), .hdr_valid(hdr_valid),
    .overrun_count(overrun));

  xfft_8192 fft (
    .aclk(clk), .aresetn(fft_aresetn),
    .s_axis_config_tdata(cfg_tdata), .s_axis_config_tvalid(cfg_tvalid), .s_axis_config_tready(cfg_tready),
    .s_axis_data_tdata(s_tdata), .s_axis_data_tvalid(s_tvalid), .s_axis_data_tready(s_tready), .s_axis_data_tlast(s_tlast),
    .m_axis_data_tdata(m_tdata), .m_axis_data_tuser(m_tuser), .m_axis_data_tvalid(m_tvalid), .m_axis_data_tlast(m_tlast),
    .event_frame_started(ev_fs), .event_tlast_unexpected(ev_tlu), .event_tlast_missing(ev_tlm),
    .event_data_in_channel_halt(ev_halt));

  wire dma_en; wire [31:0] dma_data; wire [15:0] fovf; wire [31:0] frames;
  isdbt_fe_out #(.N(N), .FIFO_DEPTH(16384)) outp (
    .clk(clk), .rst(rst), .mode({3'd0, enable}),
    .m_tdata(m_tdata), .m_tuser(m_tuser), .m_tvalid(m_tvalid), .m_tlast(m_tlast),
    .hdr_start(hdr_start), .hdr_seq(hdr_seq), .hdr_valid(hdr_valid), .hdr_pop(hdr_pop),
    .info_a(32'd0), .info_b(32'd0),
    .dma_wr_en(dma_en), .dma_wr_data(dma_data), .fifo_overflow_count(fovf), .frames_out(frames));

  // 入力列: LFSR 風の 12bit 値。t ごとの値をファイルへ
  integer fin, fout, t, n_tr_low = 0, n_ev = 0;
  reg [31:0] lfsr = 32'h1234567;
  function [15:0] sgn12(input [31:0] v); sgn12 = {{4{v[11]}}, v[11:0]}; endfunction

  // DMA 語列のフレーム長検査: magic から次の magic までが 8 + N 語であること
  integer wc = 0, bad_len = 0, n_magic = 0;
  always @(posedge clk) begin
    if (s_tvalid && !s_tready) n_tr_low <= n_tr_low + 1;
    if (ev_tlu || ev_tlm || ev_halt) n_ev <= n_ev + 1;
    if (dma_en) begin
      $fwrite(fout, "%08x\n", dma_data);
      if (dma_data == 32'h49534254) begin
        if (n_magic != 0 && wc != 8 + N) begin
          bad_len = bad_len + 1;
          $display("frame %0d: length %0d words (expected %0d)", n_magic, wc, 8 + N);
        end
        n_magic = n_magic + 1;
        wc = 1;
      end else begin
        wc = wc + 1;
      end
    end
  end

  task feed(input integer n);
    integer k;
    begin
      for (k = 0; k < n; k = k + 1) begin
        @(posedge clk);
        lfsr <= {lfsr[30:0], lfsr[31] ^ lfsr[21] ^ lfsr[1] ^ lfsr[0]};
        adc_valid <= 1;
        adc_i <= sgn12(lfsr);
        adc_q <= sgn12(lfsr >> 12);
        sample_count <= sample_count + 1;
        $fwrite(fin, "%0d %0d\n", $signed(sgn12(lfsr)), $signed(sgn12(lfsr >> 12)));
      end
    end
  endtask

  initial begin
    fin = $fopen("fe_in.txt", "w");
    fout = $fopen("fe_out.txt", "w");
    #100 rst = 0;
    #100 enable = 1;
    feed(3 * STRIDE);
    adc_valid <= 0;
    repeat (20000) @(posedge clk);
    $display("phase 1: frames=%0d overrun=%0d tready_low_cycles=%0d events=%0d fifo_ovf=%0d", frames, overrun, n_tr_low, n_ev, fovf);
    // 窓の途中で止めて（モード 0）再開: xfft のリセットで出力フレームが窓境界に揃い直すこと
    feed(STRIDE / 2);                 // 4 番目の窓の途中（xfft に未完のフレームが入っている）
    @(posedge clk); enable <= 0;
    feed(2000);                       // 停止中もサンプルは流れ続ける
    @(posedge clk); enable <= 1;
    feed(3 * STRIDE);
    adc_valid <= 0;
    repeat (20000) @(posedge clk);
    $display("phase 2: frames=%0d magic=%0d bad_len=%0d events=%0d fifo_ovf=%0d", frames, n_magic, bad_len, n_ev, fovf);
    if (n_magic != 6 || bad_len != 0) $display("FAIL: expected 6 well-formed frames");
    else $display("PASS: framing realigned after mode 0");
    $fclose(fin); $fclose(fout);
    $finish;
  end
endmodule
