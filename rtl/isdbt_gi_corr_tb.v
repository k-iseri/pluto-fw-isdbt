// isdbt_gi_corr の小規模ユニットテスト（N=8, Ng=4）。自己検査:
//   1. リセット解除後に 40 サンプル流し、warm-up 後の出力 c が「直近 Ng 個の x·conj(x_N) の和」と一致すること
//   2. 遅延線に内容が残った状態でリセットし直し（実機のコアリセットと同じ）、再 warm-up 後も一致すること
//      （以前は warm < N の間の「古い遅延線との積」まで足していて、引き算が取り除かないので一定のオフセットが
//        一生残った。BRAM 初期値 0 の初回だけでは見えない。2026-10-15）
// SPDX-License-Identifier: MIT
`timescale 1ns/100ps
module isdbt_gi_corr_tb;
  localparam N = 8, NG = 4;
  reg clk = 0; always #5 clk = ~clk;
  reg rst = 1, valid = 0;
  reg signed [7:0] i = 0, q = 0;
  reg [31:0] idx = 0;
  wire v; wire signed [27:0] cre, cim; wire [31:0] mag2, oidx;
  isdbt_gi_corr #(.N(N), .NG(NG)) dut (.clk(clk), .rst(rst), .valid_in(valid), .i_in(i), .q_in(q), .idx_in(idx),
    .valid_out(v), .c_re(cre), .c_im(cim), .mag2(mag2), .idx_out(oidx));
  // 入力履歴（参照計算用）: xi[t], xq[t]
  integer xi [0:255], xq [0:255];
  integer t, k, ref_re, ref_im, errors, checked;
  reg [31:0] pass_start = 0;
  // 参照: c[n] = Σ_{m=n−NG+1}^{n} x[m]·conj(x[m−N])（m−N がこのパスの開始より前なら 0 扱い）
  task check_out;
    input integer n_out;
    input integer start;
    begin
      ref_re = 0; ref_im = 0;
      for (k = n_out - NG + 1; k <= n_out; k = k + 1) begin
        if (k - N >= start) begin
          ref_re = ref_re + xi[k] * xi[k - N] + xq[k] * xq[k - N];
          ref_im = ref_im + xq[k] * xi[k - N] - xi[k] * xq[k - N];
        end
      end
      checked = checked + 1;
      if (cre !== ref_re || cim !== ref_im) begin
        errors = errors + 1;
        $display("MISMATCH idx=%0d c=(%0d,%0d) ref=(%0d,%0d)", n_out, cre, cim, ref_re, ref_im);
      end
    end
  endtask
  always @(posedge clk) if (v) check_out(oidx, pass_start);
  task run_pass;
    input integer start;
    input integer count;
    begin
      pass_start = start;
      for (t = start; t < start + count; t = t + 1) begin
        @(posedge clk);
        valid <= 1; i <= (t * 7) % 11 - 5; q <= (t * 3) % 7 - 3; idx <= t;
        xi[t] = (t * 7) % 11 - 5; xq[t] = (t * 3) % 7 - 3;
      end
      @(posedge clk); valid <= 0;
      repeat (8) @(posedge clk);
    end
  endtask
  initial begin
    errors = 0; checked = 0;
    #20 rst = 0;
    run_pass(0, 40);                       // 1. 初回（遅延線は 0）
    // 2. 遅延線に内容を残したままリセット → 再 warm-up。参照は新しい start 以降だけを有効とみなす
    @(posedge clk); rst <= 1;
    repeat (3) @(posedge clk); rst <= 0;
    run_pass(100, 40);
    $display("checked %0d outputs, %0d mismatches: %s", checked, errors, errors == 0 ? "PASS" : "FAIL");
    $finish;
  end
endmodule
