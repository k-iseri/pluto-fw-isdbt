// isdbt_eq の検証: モデル（isdbt-sdr tools/fe_eq_model.py --vectors）のビンを流し、出力の D/CSI を期待値と比べる。
//   eq_in.txt : 窓ごとに "H <start hex8> <delta hex8> <exp hex2>" の行 + 8192 行 "iiii qqqq"（12bit 2 の補数、16 進）
//   eq_ref.txt: 窓ごとに 5617 行 "ii qq cc"（8bit、16 進）
//   xvlog -sv -i . isdbt_cordic.v isdbt_eq.v isdbt_eq_tb.v && xelab isdbt_eq_tb -s tb && xsim tb -R
// 出力 eq_out.txt に復元した D/CSI を書き、Python（scripts/check_eq_sim.py）で許容差を判定する。
// SPDX-License-Identifier: MIT

`timescale 1ns/100ps

module isdbt_eq_tb;
  parameter N = 8192;
  parameter TOTAL = 5617;
  parameter GAP = 2048;             // 窓と窓の間のサイクル数（実機: l_clk = 2×fs で窓間隔 18,432、受信 16,384）
  parameter BIN_CYCLES = 2;         // 1 ビンあたりのサイクル（実機の FFT はサンプル速度 = 2 サイクルに 1 ビン）
  parameter INT_CFO = 9;
  reg clk = 0; always #8 clk = ~clk;
  reg rst = 1;
  reg [3:0] mode = 4'd0;
  reg [31:0] m_tdata = 0; reg [23:0] m_tuser = 0; reg m_tvalid = 0, m_tlast = 0;
  reg [31:0] hdr_start = 0, hdr_delta = 0;
  wire o_valid, o_last; wire [31:0] o_data; reg o_ready = 1;
  wire [1:0] sp_phase; wire signed [31:0] afc_omega; wire [31:0] dbg;

  isdbt_eq #(.N(N), .TOTAL(TOTAL)) dut (
    .clk(clk), .rst(rst), .mode(mode), .int_cfo(INT_CFO[7:0]), .eq_flags(8'h03),
    .m_tdata(m_tdata), .m_tuser(m_tuser), .m_tvalid(m_tvalid), .m_tlast(m_tlast),
    .hdr_start(hdr_start), .hdr_delta(hdr_delta),
    .o_valid(o_valid), .o_ready(o_ready), .o_data(o_data), .o_last(o_last),
    .sp_phase(sp_phase), .afc_omega(afc_omega), .dbg_word(dbg));

  integer fin, fout, flog, r, nsym = 0, nwords = 0;
  reg [7:0] hc; reg [31:0] hs, hd; reg [7:0] hx; reg [15:0] a, b;
  integer i;
  // 出力ワードを並べて 3 バイト単位に復元
  reg [7:0] bytes [0:3*TOTAL+3];
  integer nb = 0, k, kk;
  always @(posedge clk) begin
    if (o_valid && o_ready) begin
      nwords = nwords + 1;
      bytes[nb] = o_data[7:0]; bytes[nb+1] = o_data[15:8]; bytes[nb+2] = o_data[23:16]; bytes[nb+3] = o_data[31:24];
      nb = nb + 4;
      if (o_last) begin
        $fwrite(fout, "S %0d words %0d sp %0d omega %0d cpe %0d\n", nsym, nwords, sp_phase, afc_omega, dut.cpe_phase);
        for (k = 0; k < TOTAL; k = k + 1) begin
          kk = (k - (2808 - INT_CFO) + TOTAL) % TOTAL;     // キャリア k は出力位置 kk（ビン順）
          $fwrite(fout, "%02x %02x %02x\n", bytes[3*kk], bytes[3*kk+1], bytes[3*kk+2]);
        end
        nb = 0; nwords = 0; nsym = nsym + 1;
      end
    end
  end

  always @(posedge clk) if (dut.state == 4'd5 && nsym < 12)
    $display("sym %0d: slot %0d acc_re %0d acc_im %0d acc_hh %0d acc_h4 %0d sp %0d", nsym, dut.slot_b, dut.bacc_re, dut.bacc_im, dut.bacc_hh, dut.bacc_h4, dut.sp_phase);

  reg [3:0] st_d = 0; integer ntrans = 0;
  always @(posedge clk) begin
    st_d <= dut.state;
    if (dut.state != st_d && ntrans < 60) begin ntrans = ntrans + 1; $display("t=%0t state %0d -> %0d of_wr %0d of_rd %0d o_valid %0d nwords %0d", $time, st_d, dut.state, dut.of_wr, dut.of_rd, o_valid, nwords); end
    if (dut.state == 4'd8 && st_d == 4'd7 && nsym < 12) $display("sym %0d: csi_k %0d div_den %0d s_total %0d", nsym, dut.csi_k, dut.div_den, dut.s_total);
    if (dut.state == 4'd8 && dut.p_v[8] && dut.b2_k == 13'd2000 && nsym < 12) $display("   k~2000: E4 %0d csi_m2 %0d c8 %0d e_clz5 %0d", dut.E4, dut.csi_m2, dut.c8, dut.e_clz5);
  end

  // 自己一致検査: シンボル処理の終わり（FLUSH → IDLE）に、履歴スロット slot_b の H_sp が
  // sym_mem の SP 値 × 符号 × 3/4 と一致するか（受信中 SP パスの添字・符号の検証）
  integer sc_m, sc_k, sc_bin, sc_bad, sc_hits, sc_n = 0;
  reg signed [12:0] sc_yi, sc_yq, sc_ei, sc_eq, sc_hi, sc_hq;
  reg [25:0] sc_y, sc_h;
  always @(posedge clk) if (dut.sp3) sc_hits = sc_hits + 1;
  always @(posedge clk) begin
    if (dut.state == 4'd10 && st_d != 4'd10) begin
      sc_bad = 0;
      for (sc_m = 0; sc_m < 468; sc_m = sc_m + 1) begin
        sc_k = 3 * dut.sp_b + 12 * sc_m;
        sc_bin = (dut.base_b + sc_k) & 13'h1FFF;
        sc_y = sc_bin[12] ? dut.sym_mem1[sc_bin[11:0]] : dut.sym_mem0[sc_bin[11:0]];
        sc_yi = sc_y[12:0]; sc_yq = sc_y[25:13];
        sc_ei = dut.pilot_sign_rom[sc_k] ? -((sc_yi * 3) >>> 2) : ((sc_yi * 3) >>> 2);
        sc_eq = dut.pilot_sign_rom[sc_k] ? -((sc_yq * 3) >>> 2) : ((sc_yq * 3) >>> 2);
        sc_h = dut.hist_mem[{dut.slot_b, sc_m[8:0]}];
        sc_hi = sc_h[12:0]; sc_hq = sc_h[25:13];
        if (sc_hi != sc_ei || sc_hq != sc_eq) begin
          sc_bad = sc_bad + 1;
          if (sc_bad <= 3 && sc_n < 6) $display("   sym %0d m %0d k %0d: hist %0d %0d expected %0d %0d", sc_n, sc_m, sc_k, sc_hi, sc_hq, sc_ei, sc_eq);
        end
      end
      if (sc_n < 24) $display("selfcheck sym %0d: slot_b %0d sp_b %0d sp_known %0d bad %0d / 468, sp3 hits so far %0d, cpe %0d omega %0d", sc_n, dut.slot_b, dut.sp_b, dut.sp_known, sc_bad, sc_hits, dut.cpe_phase, dut.afc_omega);
      sc_n = sc_n + 1;
    end
  end

  initial begin
    sc_hits = 0;
    fin = $fopen("eq_in.txt", "r");
    fout = $fopen("eq_out.txt", "w");
    #100 rst = 0;
    #100 mode = 4'd4;
    repeat (10) @(posedge clk);
    r = $fscanf(fin, "H %h %h %h\n", hs, hd, hx);
    while (r == 3) begin
      hdr_start = hs; hdr_delta = hd;
      for (i = 0; i < N; i = i + 1) begin
        r = $fscanf(fin, "%h %h\n", a, b);
        @(posedge clk);
        m_tvalid <= 1; m_tdata <= {4'd0, b[11:0], 4'd0, a[11:0]}; m_tuser <= {hx, 16'd0}; m_tlast <= (i == N - 1);
        if (BIN_CYCLES > 1) begin @(posedge clk); m_tvalid <= 0; m_tlast <= 0; repeat (BIN_CYCLES - 2) @(posedge clk); end
      end
      @(posedge clk); m_tvalid <= 0; m_tlast <= 0;
      repeat (GAP) @(posedge clk);
      r = $fscanf(fin, "H %h %h %h\n", hs, hd, hx);
    end
    repeat (40000) @(posedge clk);
    $display("done: %0d symbols output, overrun %0d, nwords %0d nb %0d", nsym, dbg[25], nwords, nb);
    $fclose(fin); $fclose(fout);
    $finish;
  end
endmodule
