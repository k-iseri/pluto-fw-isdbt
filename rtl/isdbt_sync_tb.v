// 同期ブロックの検証: pack8 → gi_corr → sync、rotate → fe_win（sync_mode）→ 振る舞い FFT モデル → fe_out。
// スティミュラス sync_stim.txt（12bit I/Q、scripts/make_sync_stimulus.py）を 1 サンプル 1 クロックで流し、
// 窓開始イベント・ロック・CFO 増分・DMA ヘッダをファイルに書く（Python 側で真値と照合）。
//   xvlog -sv pack8.v isdbt_cordic.v isdbt_gi_corr.v isdbt_sync.v isdbt_fe_win.v isdbt_fe_out.v isdbt_sync_tb.v
//   xelab isdbt_sync_tb -s tb && xsim tb -R
// SPDX-License-Identifier: MIT

`timescale 1ns/100ps

module isdbt_sync_tb;
  localparam N = 8192, NG = 1024, T = 9216;
  parameter MODE = 2;              // 2 = 16bit ビン、3 = 8bit ビン
  reg clk = 0; always #5 clk = ~clk;
  reg rst = 1, enable = 0;
  reg adc_valid = 0;
  reg signed [15:0] adc_i = 0, adc_q = 0;
  reg [63:0] sample_count = 0;

  // 8bit 入力（pack8、シフト 3）
  wire [7:0] i8, q8;
  pack8 #(.SHIFT(3)) p8i (.din(adc_i), .dout(i8));
  pack8 #(.SHIFT(3)) p8q (.din(adc_q), .dout(q8));

  wire c_valid; wire signed [27:0] c_re, c_im; wire [31:0] c_mag2, c_idx;
  isdbt_gi_corr #(.N(N), .NG(NG)) corr (
    .clk(clk), .rst(rst), .valid_in(adc_valid), .i_in(i8), .q_in(q8), .idx_in(sample_count[31:0]),
    .valid_out(c_valid), .c_re(c_re), .c_im(c_im), .mag2(c_mag2), .idx_out(c_idx));

  wire [31:0] nco_phase; wire start_valid; wire [31:0] start_pos; wire locked;
  wire signed [31:0] cfo_inc; wire [31:0] peak_mag2; wire [15:0] lock_losses; wire [31:0] status_word;
  isdbt_sync #(.N(N), .NG(NG), .T(T)) sync (
    .clk(clk), .rst(rst), .mode((enable ? MODE[3:0] : 4'd0)), .margin(16'd128),
    .c_valid(c_valid), .c_re(c_re), .c_im(c_im), .c_mag2(c_mag2), .c_idx(c_idx),
    .raw_valid(adc_valid), .nco_phase(nco_phase),
    .start_valid(start_valid), .start_pos(start_pos),
    .locked(locked), .cfo_inc(cfo_inc), .peak_mag2(peak_mag2), .lock_losses(lock_losses), .status_word(status_word));

  wire r_valid; wire signed [15:0] r_i, r_q; wire [31:0] r_idx;
  isdbt_rotate rot (
    .clk(clk), .mode((enable ? MODE[3:0] : 4'd0)), .valid_in(adc_valid), .x_in(adc_i), .y_in(adc_q), .phase_in(nco_phase), .idx_in(sample_count[31:0]),
    .valid_out(r_valid), .x_out(r_i), .y_out(r_q), .idx_out(r_idx));

  wire [7:0] cfg_tdata; wire cfg_tvalid; reg cfg_tready = 1;
  wire [31:0] s_tdata; wire s_tvalid, s_tlast; wire s_tready = 1'b1;
  wire hdr_pop; wire [63:0] hdr_start; wire [31:0] hdr_seq; wire hdr_valid; wire [15:0] overrun;
  isdbt_fe_win #(.N(N)) win (
    .clk(clk), .rst(rst), .mode((enable ? MODE[3:0] : 4'd0)), .stride(16'd0), .offset(16'd0), .decim(8'd1),
    .sample_count({32'd0, r_idx}), .adc_valid(r_valid), .adc_i(r_i), .adc_q(r_q),
    .start_valid(start_valid), .start_pos(start_pos),
    .cfg_tdata(cfg_tdata), .cfg_tvalid(cfg_tvalid), .cfg_tready(cfg_tready),
    .s_tdata(s_tdata), .s_tvalid(s_tvalid), .s_tlast(s_tlast), .s_tready(s_tready),
    .hdr_pop(hdr_pop), .hdr_start(hdr_start), .hdr_seq(hdr_seq), .hdr_valid(hdr_valid),
    .overrun_count(overrun));

  // FFT 振る舞いモデル（恒等、遅延 100）
  reg [31:0] dly_d [0:127]; reg dly_v [0:127]; reg dly_l [0:127];
  integer di; initial for (di = 0; di < 128; di = di + 1) begin dly_v[di] = 0; dly_l[di] = 0; dly_d[di] = 0; end
  reg [6:0] wp = 0; wire [6:0] rp = wp - 7'd100;
  wire [31:0] m_tdata = dly_d[rp]; wire m_tvalid = dly_v[rp]; wire m_tlast = dly_l[rp];
  always @(posedge clk) begin dly_d[wp] <= s_tdata; dly_v[wp] <= s_tvalid; dly_l[wp] <= s_tlast; wp <= wp + 1'b1; end

  wire dma_en; wire [31:0] dma_data; wire [15:0] fovf; wire [31:0] frames;
  isdbt_fe_out #(.N(N), .FIFO_DEPTH(16384)) outp (
    .clk(clk), .rst(rst), .mode((enable ? MODE[3:0] : 4'd0)),
    .m_tdata(m_tdata), .m_tuser(24'd0), .m_tvalid(m_tvalid), .m_tlast(m_tlast),
    .hdr_start(hdr_start), .hdr_seq(hdr_seq), .hdr_valid(hdr_valid), .hdr_pop(hdr_pop),
    .info_a(cfo_inc), .info_b(status_word),
    .dma_wr_en(dma_en), .dma_wr_data(dma_data), .fifo_overflow_count(fovf), .frames_out(frames));

  integer fin, fev, fout, fcorr, r, ns = 0;
  reg [15:0] a, b;        // 16 進（16bit 2 の補数）で読む。xsim の "%d %d" は両方負の行で失敗する
  always @(posedge clk) begin
    if (start_valid) $fwrite(fev, "start %0d locked %0d cfo_inc %0d peak %0d at %0d\n", start_pos, locked, cfo_inc, peak_mag2, sample_count);
    if (dma_en) $fwrite(fout, "%08x\n", dma_data);
    if (c_valid) $fwrite(fcorr, "%0d %0d %0d %0d\n", c_idx, c_re, c_im, c_mag2);
    if (sync.meas_fire) $display("meas at c_idx=%0d: pred=%0d max_idx=%0d max_mag=%0d avg_peak=%0d miss=%0d", c_idx, sync.pred, sync.max_idx, sync.max_mag, sync.avg_peak, sync.miss);
    if (sync.in_search && c_valid && sync.d_pred == -32) $display("search start at c_idx=%0d pred=%0d", c_idx, sync.pred);
  end

  initial begin
    fin = $fopen("sync_stim.txt", "r");
    fev = $fopen("sync_events.txt", "w");
    fout = $fopen("sync_out.txt", "w");
    fcorr = $fopen("sync_corr.txt", "w");
    #50 rst = 0;
    #50 enable = 1;
    r = $fscanf(fin, "%h %h", a, b);
    while (r == 2) begin
      @(posedge clk);
      adc_valid <= 1; adc_i <= a; adc_q <= b; sample_count <= ns; ns = ns + 1;
      r = $fscanf(fin, "%h %h", a, b);
    end
    $display("read stopped: r=%0d after %0d samples, last a=%0d b=%0d", r, ns, a, b);
    @(posedge clk); adc_valid <= 0;
    repeat (30000) @(posedge clk);
    $display("samples=%0d frames=%0d overrun=%0d lock_losses=%0d locked=%0d cfo_inc=%0d", ns, frames, overrun, lock_losses, locked, cfo_inc);
    $fclose(fin); $fclose(fev); $fclose(fout); $fclose(fcorr);
    $finish;
  end
endmodule
