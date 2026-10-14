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
  parameter GAP = 60000;            // 窓と窓の間のサイクル数（実機は ~61,500）
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
  integer nb = 0, k;
  always @(posedge clk) begin
    if (o_valid && o_ready) begin
      nwords = nwords + 1;
      bytes[nb] = o_data[7:0]; bytes[nb+1] = o_data[15:8]; bytes[nb+2] = o_data[23:16]; bytes[nb+3] = o_data[31:24];
      nb = nb + 4;
      if (o_last) begin
        $fwrite(fout, "S %0d words %0d sp %0d omega %0d cpe %0d\n", nsym, nwords, sp_phase, afc_omega, dut.cpe_phase);
        for (k = 0; k < TOTAL; k = k + 1) $fwrite(fout, "%02x %02x %02x\n", bytes[3*k], bytes[3*k+1], bytes[3*k+2]);
        nb = 0; nwords = 0; nsym = nsym + 1;
      end
    end
  end

  always @(posedge clk) if (dut.state == 4'd5 && nsym < 12)
    $display("sym %0d: slot %0d acc_re %0d acc_im %0d acc_hh %0d acc_h4 %0d sp %0d", nsym, dut.slot, dut.acc_re, dut.acc_im, dut.acc_hh, dut.acc_h4, dut.sp_phase);

  reg [3:0] st_d = 0;
  always @(posedge clk) begin
    st_d <= dut.state;
    if (dut.state == 4'd8 && st_d == 4'd7 && nsym < 12) $display("sym %0d: csi_k %0d div_den %0d s_total %0d", nsym, dut.csi_k, dut.div_den, dut.s_total);
    if (dut.state == 4'd8 && dut.p_v[8] && dut.b2_k == 13'd2000 && nsym < 12) $display("   k~2000: E4 %0d csi_m2 %0d c8 %0d e_clz5 %0d", dut.E4, dut.csi_m2, dut.c8, dut.e_clz5);
  end

  initial begin
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
      end
      @(posedge clk); m_tvalid <= 0; m_tlast <= 0;
      repeat (GAP) @(posedge clk);
      r = $fscanf(fin, "H %h %h %h\n", hs, hd, hx);
    end
    repeat (40000) @(posedge clk);
    $display("done: %0d symbols output, overrun %0d", nsym, dbg[25]);
    $fclose(fin); $fclose(fout);
    $finish;
  end
endmodule
