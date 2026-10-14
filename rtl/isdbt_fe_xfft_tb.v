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
  reg aresetn = 0;
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

  isdbt_fe_win #(.N(N)) win (
    .clk(clk), .rst(rst), .enable(enable), .stride(stride), .offset(offset), .decim(decim),
    .sample_count(sample_count), .adc_valid(adc_valid), .adc_i(adc_i), .adc_q(adc_q),
    .cfg_tdata(cfg_tdata), .cfg_tvalid(cfg_tvalid), .cfg_tready(cfg_tready),
    .s_tdata(s_tdata), .s_tvalid(s_tvalid), .s_tlast(s_tlast), .s_tready(s_tready),
    .hdr_pop(hdr_pop), .hdr_start(hdr_start), .hdr_seq(hdr_seq), .hdr_valid(hdr_valid),
    .overrun_count(overrun));

  xfft_8192 fft (
    .aclk(clk), .aresetn(aresetn),
    .s_axis_config_tdata(cfg_tdata), .s_axis_config_tvalid(cfg_tvalid), .s_axis_config_tready(cfg_tready),
    .s_axis_data_tdata(s_tdata), .s_axis_data_tvalid(s_tvalid), .s_axis_data_tready(s_tready), .s_axis_data_tlast(s_tlast),
    .m_axis_data_tdata(m_tdata), .m_axis_data_tuser(m_tuser), .m_axis_data_tvalid(m_tvalid), .m_axis_data_tlast(m_tlast),
    .event_frame_started(ev_fs), .event_tlast_unexpected(ev_tlu), .event_tlast_missing(ev_tlm),
    .event_data_in_channel_halt(ev_halt));

  wire dma_en; wire [31:0] dma_data; wire [15:0] fovf; wire [31:0] frames;
  isdbt_fe_out #(.N(N), .FIFO_DEPTH(16384)) outp (
    .clk(clk), .rst(rst), .enable(enable), .mode(4'd1),
    .m_tdata(m_tdata), .m_tuser(m_tuser), .m_tvalid(m_tvalid), .m_tlast(m_tlast),
    .hdr_start(hdr_start), .hdr_seq(hdr_seq), .hdr_valid(hdr_valid), .hdr_pop(hdr_pop),
    .dma_wr_en(dma_en), .dma_wr_data(dma_data), .fifo_overflow_count(fovf), .frames_out(frames));

  // 入力列: LFSR 風の 12bit 値。t ごとの値をファイルへ
  integer fin, fout, t, n_tr_low = 0, n_ev = 0;
  reg [31:0] lfsr = 32'h1234567;
  function [15:0] sgn12(input [31:0] v); sgn12 = {{4{v[11]}}, v[11:0]}; endfunction

  always @(posedge clk) begin
    if (s_tvalid && !s_tready) n_tr_low <= n_tr_low + 1;
    if (ev_tlu || ev_tlm || ev_halt) n_ev <= n_ev + 1;
    if (dma_en) $fwrite(fout, "%08x\n", dma_data);
  end

  initial begin
    fin = $fopen("fe_in.txt", "w");
    fout = $fopen("fe_out.txt", "w");
    #100 rst = 0; aresetn = 1;
    #100 enable = 1;
    for (t = 0; t < 3 * STRIDE; t = t + 1) begin
      @(posedge clk);
      lfsr <= {lfsr[30:0], lfsr[31] ^ lfsr[21] ^ lfsr[1] ^ lfsr[0]};
      adc_valid <= 1;
      adc_i <= sgn12(lfsr);
      adc_q <= sgn12(lfsr >> 12);
      sample_count <= sample_count + 1;
      $fwrite(fin, "%0d %0d\n", $signed(sgn12(lfsr)), $signed(sgn12(lfsr >> 12)));
    end
    adc_valid <= 0;
    repeat (20000) @(posedge clk);
    $display("frames=%0d overrun=%0d tready_low_cycles=%0d events=%0d fifo_ovf=%0d", frames, overrun, n_tr_low, n_ev, fovf);
    $fclose(fin); $fclose(fout);
    $finish;
  end
endmodule
