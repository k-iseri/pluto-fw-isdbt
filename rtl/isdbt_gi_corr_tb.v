// isdbt_gi_corr の小規模ユニットテスト（N=8, Ng=4）。内部信号を表示して Python の手計算と比べる。
// SPDX-License-Identifier: MIT
`timescale 1ns/100ps
module isdbt_gi_corr_tb;
  reg clk = 0; always #5 clk = ~clk;
  reg rst = 1, valid = 0;
  reg signed [7:0] i = 0, q = 0;
  reg [31:0] idx = 0;
  wire v; wire signed [27:0] cre, cim; wire [31:0] mag2, oidx;
  isdbt_gi_corr #(.N(8), .NG(4)) dut (.clk(clk), .rst(rst), .valid_in(valid), .i_in(i), .q_in(q), .idx_in(idx),
    .valid_out(v), .c_re(cre), .c_im(cim), .mag2(mag2), .idx_out(oidx));
  integer t;
  // 入力: i = (t*7) mod 11 - 5, q = (t*3) mod 7 - 3
  always @(posedge clk) begin
    if (dut.v1) $display("v1 t=%0d i_d1=%0d q_d1=%0d in_d=%0d qn_d=%0d", t, dut.i_d1, dut.q_d1, dut.in_d, dut.qn_d);
    if (dut.v2) $display("v2 p_re=%0d p_im=%0d", dut.p_re, dut.p_im);
    if (v) $display("out idx=%0d c=(%0d,%0d) mag2=%0d", oidx, cre, cim, mag2);
  end
  initial begin
    #20 rst = 0;
    for (t = 0; t < 30; t = t + 1) begin
      @(posedge clk);
      valid <= 1; i <= (t * 7) % 11 - 5; q <= (t * 3) % 7 - 3; idx <= t;
    end
    @(posedge clk); valid <= 0;
    repeat (10) @(posedge clk);
    $finish;
  end
endmodule
