// pack8 の網羅テスト（iverilog -g2012 pack8.v pack8_tb.v && vvp a.out）
// 全 16 bit 入力について、参照モデル（整数演算の round half away from zero + 飽和）と比較する。
// SPDX-License-Identifier: MIT

`timescale 1ns/100ps

module pack8_tb;
  reg  [15:0] din;
  wire [7:0]  dout;
  integer     i, x, ref_val, got, errors;

  pack8 dut (.din(din), .dout(dout));

  function integer ref_pack(input integer v);
    integer a, r;
    begin
      a = (v < 0) ? -v : v;
      r = (a + 8) / 16;
      if (v < 0) r = -r;
      if (r > 127) r = 127;
      if (r < -128) r = -128;
      ref_pack = r;
    end
  endfunction

  initial begin
    errors = 0;
    for (i = 0; i < 65536; i = i + 1) begin
      din = i[15:0];
      #1;
      x = (i >= 32768) ? i - 65536 : i;
      ref_val = ref_pack(x);
      got = (dout >= 128) ? dout - 256 : dout;
      if (got !== ref_val) begin
        errors = errors + 1;
        if (errors < 10) $display("MISMATCH din=%0d got=%0d ref=%0d", x, got, ref_val);
      end
    end
    // 代表値の表示
    foreach_check(0); foreach_check(7); foreach_check(8); foreach_check(-8); foreach_check(-9);
    foreach_check(2047); foreach_check(-2048); foreach_check(2032); foreach_check(2031);
    if (errors == 0) $display("PASS: all 65536 inputs match");
    else $display("FAIL: %0d mismatches", errors);
    $finish;
  end

  task foreach_check(input integer v);
    begin
      din = v[15:0];
      #1;
      $display("  %6d -> %4d", v, (dout >= 128) ? dout - 256 : dout);
    end
  endtask
endmodule
