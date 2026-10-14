// isdbt_eq: 散布パイロット（SP）によるチャネル推定と等化（design-v2 2b-3b、モード 4）
//
// 入力は同期 FFT（isdbt_fe_win → xfft）の出力ビン（12bit I/Q、自然順、ブロック浮動小数点の指数 blk_exp）。
// クロックは ADC クロック l_clk = 2 × サンプルレート ≈ 16.25 MHz。1 シンボル = 18,432 サイクル。
// FFT はリアルタイムモードなのでビンは 2 サイクルに 1 つ（8192 ビン = 16,384 サイクル）しか出ない。
// したがって「受信してから処理」は間に合わず（次の窓が来るまで 2,048 サイクル）、次のように組む:
//
//   パス A（受信、16,384 サイクル）: ビン b を e^{j2π θ_b} で回してシンボル BRAM に書く
//       θ_b = −b·Δ_n/N − δ·s_n/N − φ_afc [turns]（Δ_n: 窓揺れ（isdbt_sync の tim_delta）、δ: 整数 CFO、φ_afc: AFC）
//     同時に（予測した SP 位相 p = 前シンボル + 1 で）SP の H_sp = y·(±1)·3/4 を履歴 BRAM に書き、4 シンボル前の
//     同位相 H4 と Σ H_sp·conj(H4)（AFC）、Σ|H_sp|²、Σ|H4|² を積算する。4 候補の SP エネルギーも積算し、
//     受信末に予測が正しかったか検証する（違えば受信後に SP パス（旧 B1）をやり直し、次の予測を直す）
//   受信末: CPE = arg(Σ|H_sp|² + Σ H_sp·conj(H4))、AFC ω += angle/16、CSI 定数 K = ⌊1872·2^34 / S⌋（逐次除算）
//   パス B2（等化、1 キャリア/サイクル ≈ 5.7k サイクル）: ビン順（キャリア car0 = 2808 − δ から 5616、続いて
//     0 から car0 − 1）に読む。次の窓の書き込みはビン 0 から始まるので、ビン順に読めば常に先回りできる。
//     3 キャリア格子の H は直近 2 シンボル（同位相）の平均、線形補間、y' = y·e^{−jφ_cpe}、D = y'·conj(H)/|H|²
//     → I/Q 8bit（LSB 1/64）、CSI = |H|²/平均 → 8bit。出力順はビン順（ホストが δ でキャリア順に戻す）
//
// 履歴 BRAM はポート A（受信中の書き込みと H4 読み）、ポート B（B2 の格子読み）。受信中のシンボルのスロット
// slot_a と B2 中のシンボルのスロット slot_b は別（B2 は次の窓の受信と重なる）。スロットは 16（使うのは年齢 0〜7。
// 8 だと B2 中に受信する次のシンボルのスロット n+1 = n−7 が年齢 7 の読みと衝突する）。
//
// SPDX-License-Identifier: MIT
// Copyright (c) 2026 k-iseri

`timescale 1ns/100ps

module isdbt_eq #(
  parameter N = 8192,
  parameter TOTAL = 5617,
  parameter CENTER = 2808,
  parameter M = 1873               // 格子点数 (TOTAL-1)/3 + 1
) (
  input                   clk,
  input                   rst,
  input       [3:0]       mode,            // 4 のとき動作

  input  signed [7:0]     int_cfo,         // δ
  input       [7:0]       eq_flags,        // bit0 AFC 有効、bit1 CPE 有効、bit2 SP 位相固定、bit3 予測外れでも受信中 SP を使う、
                                           // bit[5:4] 固定 SP 位相、bit[7:6] デバッグ: EQ_OMEGA に 1 = {e0,e1}、2 = {e2,e3}（[25:10]）、3 = 検出/予測

  input       [31:0]      m_tdata,
  input       [23:0]      m_tuser,         // [23:16] blk_exp
  input                   m_tvalid,
  input                   m_tlast,

  input       [31:0]      hdr_start,
  input       [31:0]      hdr_delta,       // Δ_n（1/256 サンプル、mod N·256、下位 21bit）

  output                  o_valid,
  input                   o_ready,
  output      [31:0]      o_data,
  output                  o_last,

  output reg  [1:0]       sp_phase,
  output      signed [31:0] afc_omega,     // turns/シンボル（eq_flags[7:6] ≠ 0 ならデバッグ値）
  output      [31:0]      dbg_word         // {state[3:0], sp_phase[1:0], sp_known, pending[0], overrun_cnt[7:0], cpe[7:0], sym_count[7:0]}
);
  `include "isdbt_eq_tables.vh"

  wire enable = (mode == 4'd4);
  wire afc_en = eq_flags[0];
  wire cpe_en = eq_flags[1];

  localparam [3:0] S_IDLE = 4'd0, S_B1_TAIL = 4'd3, S_AFC_WAIT = 4'd4, S_CPE_ISSUE = 4'd5,
                   S_CPE_WAIT = 4'd6, S_DIV = 4'd7, S_B2 = 4'd8, S_B2_TAIL = 4'd9, S_FLUSH = 4'd10, S_NORM = 4'd11;
  reg   [3:0]   state = S_IDLE;
  reg   [7:0]   sym_count = 'd0;
  reg   [7:0]   cpe_dbg = 'd0;
  reg   [7:0]   overrun_cnt = 'd0;        // 前のシンボルの処理が終わる前に次の窓の受信が終わった回数
  reg   [1:0]   pending = 'd0;            // 受信済みで処理待ちの窓
  reg   signed [31:0] afc_omega_r = 'd0;
  reg   [1:0]   dbg_best = 'd0, dbg_pred = 'd0;
  reg   [7:0]   dbg_mismatch = 'd0;
  reg           sp_known = 1'b0;
  assign dbg_word = {state, sp_phase, sp_known, pending[0], overrun_cnt, cpe_dbg, sym_count};

  // ---- 表 ----
  (* rom_style = "block" *) reg   [31:0]  sincos_rom [0:1023];
  (* rom_style = "block" *) reg   [15:0]  recip_rom [0:1023];
  (* rom_style = "block" *) reg           pilot_sign_rom [0:8191];
  integer ti;
  initial begin
    for (ti = 0; ti < 1024; ti = ti + 1) begin
      sincos_rom[ti] = sincos_tab(ti);
      recip_rom[ti] = recip_tab(ti);
    end
    for (ti = 0; ti < 8192; ti = ti + 1) pilot_sign_rom[ti] = pilot_sign_tab(ti);
  end

  // ---- シンボル BRAM（4K × 26 の 2 バンク）: ポート A 書き（受信）、ポート B 読み（B2 / 旧 B1）----
  (* ram_style = "block" *) reg   [25:0]  sym_mem0 [0:N/2-1];
  (* ram_style = "block" *) reg   [25:0]  sym_mem1 [0:N/2-1];
  integer hi;
  initial for (hi = 0; hi < N / 2; hi = hi + 1) begin sym_mem0[hi] = 26'd0; sym_mem1[hi] = 26'd0; end
  reg   [12:0]  sym_raddr = 'd0;
  reg   [25:0]  sym_rd0 = 'd0, sym_rd1 = 'd0;
  reg           sym_rsel = 1'b0;
  reg   [12:0]  sym_waddr = 'd0;
  reg   [25:0]  sym_wdata = 'd0;
  reg           sym_we = 1'b0;
  always @(posedge clk) begin
    sym_rd0 <= sym_mem0[sym_raddr[11:0]];
    sym_rd1 <= sym_mem1[sym_raddr[11:0]];
    sym_rsel <= sym_raddr[12];
    if (sym_we && !sym_waddr[12]) sym_mem0[sym_waddr[11:0]] <= sym_wdata;
    if (sym_we && sym_waddr[12]) sym_mem1[sym_waddr[11:0]] <= sym_wdata;
  end
  wire  [25:0]  sym_rdata = sym_rsel ? sym_rd1 : sym_rd0;

  // ---- 履歴 BRAM（16 スロット × 512 × 26）: ポート A 読み書き（受信中 / 旧 B1 の書き）、ポート B 読み（B2 / 旧 B1）----
  (* ram_style = "block" *) reg   [25:0]  hist_mem [0:8191];
  initial for (hi = 0; hi < 8192; hi = hi + 1) hist_mem[hi] = 26'd0;
  reg   [7:0]   hist_exp [0:15];
  initial for (hi = 0; hi < 16; hi = hi + 1) hist_exp[hi] = 8'd0;
  reg   [12:0]  hist_addr_a = 'd0;
  reg   [25:0]  hist_wdata = 'd0;
  reg           hist_we = 1'b0;
  reg   [25:0]  hist_rdata_a = 'd0;
  reg   [12:0]  hist_raddr = 'd0;          // ポート B
  reg   [25:0]  hist_rdata = 'd0;
  always @(posedge clk) begin
    if (hist_we) hist_mem[hist_addr_a] <= hist_wdata;
    else hist_rdata_a <= hist_mem[hist_addr_a];
    hist_rdata <= hist_mem[hist_raddr];
  end

  // ---- 共通関数 ----
  function signed [12:0] sat13(input signed [31:0] v);
    sat13 = (v > 4095) ? 13'sd4095 : (v < -4096) ? -13'sd4096 : v[12:0];
  endfunction
  function [7:0] sat8s(input signed [55:0] v);
    sat8s = (v > 127) ? 8'd127 : (v < -128) ? 8'h80 : v[7:0];
  endfunction
  function [7:0] sat8u(input [31:0] v);
    sat8u = (v > 255) ? 8'd255 : v[7:0];
  endfunction
  function signed [12:0] align(input signed [12:0] v, input signed [8:0] d);
    reg signed [31:0] t;
    begin
      t = v;
      if (d >= 3) t = t <<< 3;
      else if (d == 2) t = t <<< 2;
      else if (d == 1) t = t <<< 1;
      else if (d == -1) t = t >>> 1;
      else if (d == -2) t = t >>> 2;
      else if (d <= -3) t = t >>> 3;
      align = sat13(t);
    end
  endfunction
  function [5:0] clz32(input [31:0] v);
    integer i;
    begin
      clz32 = 6'd32;
      for (i = 31; i >= 0; i = i - 1)
        if (v[i] && clz32 == 6'd32) clz32 = 6'd31 - i;
    end
  endfunction
  function [3:0] grid_slot(input [1:0] p, input [10:0] j, input [3:0] cur, input plus4);
    reg [1:0] a;
    begin
      a = p - j[1:0];
      grid_slot = cur - {2'b0, a} - (plus4 ? 4'd4 : 4'd0);
    end
  endfunction

  // ============================================================
  // 処理中シンボルの属性（受信完了時に確定）
  // ============================================================
  reg   [3:0]   slot_b = 'd0;            // 処理中のシンボルのスロット
  reg   [7:0]   exp_b = 'd0;
  reg   [1:0]   sp_b = 'd0;
  reg   [12:0]  base_b = 'd0;
  // ============================================================
  // パス A: 受信・回転・SP エネルギー・受信中 SP パス
  // ============================================================
  reg   [3:0]   slot_a = 'd0;            // 受信中のシンボルのスロット
  reg   [1:0]   sp_pred = 'd0;           // 次のシンボルの SP 位相（予測。前シンボルの検出 +1）
  reg   [1:0]   sp_use = 'd0;            // 受信中のシンボルに使う位相（sp_pred + 飛んだシンボル数）
  reg   [31:0]  prev_start = 'd0;        // 前の窓の開始（飛んだシンボル数の判定用）
  reg   [12:0]  a_bin = 'd0;
  reg           a_first = 1'b1;
  reg   [31:0]  a_phase = 'd0;
  reg   [31:0]  a_inc = 'd0;
  reg   [7:0]   exp_a = 'd0;
  reg   signed [31:0] afc_phase = 'd0;
  reg   [12:0]  base_bin = 'd0;
  reg   [12:0]  a_car = 'd0;
  reg   [3:0]   a_cmod12 = 'd0;
  reg   [8:0]   a_m = 'd0;               // 予測位相の SP 番号
  reg   [31:0]  sp_e0 = 'd0, sp_e1 = 'd0, sp_e2 = 'd0, sp_e3 = 'd0;

  wire signed [13:0] delta_s = {{6{int_cfo[7]}}, int_cfo};
  wire [12:0] base_bin_w = delta_s[12:0] - CENTER[12:0];
  wire [12:0] car0_w = CENTER[12:0] - delta_s[12:0];
  wire [3:0]  car0_mod12_w = car0_w % 12;
  wire [8:0]  car0_div12_w = car0_w / 12;           // 受信はキャリア car0 から始まるので m = ⌊k/12⌋ をここから数える
  (* use_dsp = "yes" *) wire signed [27:0] ds_prod = delta_s * $signed({1'b0, hdr_start[12:0]});
  wire [31:0] init_phase = -({19'd0, ds_prod[12:0]} << 19) - afc_phase;
  wire [31:0] cur_phase = a_first ? init_phase : a_phase;
  wire [12:0] cur_car = a_first ? car0_w : a_car;
  wire [3:0]  cur_cm = a_first ? car0_mod12_w : a_cmod12;
  wire        cur_is_grid = (cur_car < TOTAL) && (cur_cm == 4'd0 || cur_cm == 4'd3 || cur_cm == 4'd6 || cur_cm == 4'd9);
  wire [1:0]  cur_pidx = (cur_cm == 4'd0) ? 2'd0 : (cur_cm == 4'd3) ? 2'd1 : (cur_cm == 4'd6) ? 2'd2 : 2'd3;
  // 窓開始の差から飛んだシンボル数（0〜3）。同期が窓を欠かしたときも位相の予測と履歴の年齢を合わせる
  // タイミング: hdr_start（他モジュールの FIFO 読み出しマルチプレクサ経由）からの長い組合せ経路を切るため、
  // 飛んだシンボル数と「次に使う位相・スロット」は毎サイクル登録しておき、a_first ではレジスタ値を使う
  wire [31:0] start_diff = hdr_start - prev_start;
  reg   [1:0]   n_skip_r = 'd0;
  reg   [1:0]   sp_next = 'd0;
  reg   [3:0]   slot_next = 'd0;
  always @(posedge clk) begin
    n_skip_r <= (start_diff < 32'd13824) ? 2'd0 : (start_diff < 32'd23040) ? 2'd1 : (start_diff < 32'd32256) ? 2'd2 : 2'd3;
    sp_next <= sp_pred + n_skip_r;
    slot_next <= slot_a + {2'b0, n_skip_r};
  end
  wire [1:0]  sp_use_w = a_first ? sp_next : sp_use;
  wire        cur_is_sp = cur_is_grid && (cur_pidx == sp_use_w) && sp_known;   // 予測位相の SP（受信中 SP パスの対象）
  wire [8:0]  cur_m = a_first ? car0_div12_w : a_m;    // = ⌊cur_car/12⌋（SP の履歴添字 m = (k − 3p)/12 = ⌊k/12⌋）

  wire signed [11:0] in_i = m_tdata[11:0];
  wire signed [11:0] in_q = m_tdata[27:16];
  wire [24:0] in_e = in_i * in_i + in_q * in_q;      // SP エネルギーは >> 6 で積算（実波のフルスケール近いビンで 32bit が溢れた）

  reg   [31:0]  rotA_sc = 'd0;
  reg   signed [11:0] rotA_i1 = 'd0, rotA_q1 = 'd0, rotA_i2 = 'd0, rotA_q2 = 'd0;
  reg   signed [15:0] rotA_c2 = 'd0, rotA_s2 = 'd0;
  reg   signed [28:0] rotA_pi = 'd0, rotA_pq = 'd0;
  reg           rotA_v1 = 1'b0, rotA_v2 = 1'b0, rotA_v3 = 1'b0;
  reg   [12:0]  rotA_bin1 = 'd0, rotA_bin2 = 'd0, rotA_bin3 = 'd0;
  reg           rotA_last1 = 1'b0, rotA_last2 = 1'b0, rotA_last3 = 1'b0;
  reg           sp1 = 1'b0, sp2 = 1'b0, sp3 = 1'b0, sp4 = 1'b0, sp5 = 1'b0;
  reg   [12:0]  car1 = 'd0;
  reg   [8:0]   m1 = 'd0, m2 = 'd0, m3 = 'd0;
  reg           sgn2 = 1'b0, sgn3 = 1'b0;
  reg   signed [12:0] hsp3_i = 'd0, hsp3_q = 'd0, hsp4_i = 'd0, hsp4_q = 'd0;
  reg   signed [12:0] h4_i = 'd0, h4_q = 'd0;
  wire  [3:0]   slot_a4 = slot_a - 4'd4;          // 最初の SP の読みは a_first の次のサイクル以降（slot_a は更新済み）
  wire signed [8:0] exp_d4 = $signed({1'b0, hist_exp[slot_a4]}) - $signed({1'b0, exp_a});
  reg   signed [39:0] acc_re = 'd0, acc_im = 'd0;
  reg   [39:0]  acc_hh = 'd0, acc_h4 = 'd0;
  wire signed [26:0] prod_hh = hsp4_i * hsp4_i + hsp4_q * hsp4_q;
  wire signed [26:0] prod_h4 = h4_i * h4_i + h4_q * h4_q;
  wire signed [26:0] prod_re = hsp4_i * h4_i + hsp4_q * h4_q;
  wire signed [26:0] prod_im = hsp4_q * h4_i - hsp4_i * h4_q;
  reg           a_done = 1'b0;
  reg   [3:0]   done_slot = 'd0;        // 受信し終えたシンボルのスロット（a_done と同時に確定）
  reg   [1:0]   a_sp_best = 2'd0;
  reg           a_known = 1'b0;          // このシンボルは受信中 SP パスを実行した

  assign afc_omega = (eq_flags[7:6] == 2'd1) ? {sp_e0[25:10], sp_e1[25:10]} :
                     (eq_flags[7:6] == 2'd2) ? {sp_e2[25:10], sp_e3[25:10]} :
                     (eq_flags[7:6] == 2'd3) ? {dbg_best, dbg_pred, sp_pred, sp_known, a_known, 16'd0, dbg_mismatch} : afc_omega_r;
  wire signed [12:0] y3_i = sat13((rotA_pi + 29'sd16384) >>> 15);
  wire signed [12:0] y3_q = sat13((rotA_pq + 29'sd16384) >>> 15);
  wire signed [14:0] y3_i3 = y3_i * 3;
  wire signed [14:0] y3_q3 = y3_q * 3;
  wire signed [12:0] hsp3_i_w = sgn3 ? -(y3_i3 >>> 2) : (y3_i3 >>> 2);
  wire signed [12:0] hsp3_q_w = sgn3 ? -(y3_q3 >>> 2) : (y3_q3 >>> 2);

  always @(posedge clk) begin
    rotA_v1 <= 1'b0;
    a_done <= 1'b0;
    sym_we <= 1'b0;
    hist_we <= 1'b0;
    if (rst || !enable) begin
      a_bin <= 'd0;
      a_first <= 1'b1;
      rotA_v2 <= 1'b0; rotA_v3 <= 1'b0;
      sp1 <= 1'b0; sp2 <= 1'b0; sp3 <= 1'b0; sp4 <= 1'b0; sp5 <= 1'b0;
      sp_e0 <= 'd0; sp_e1 <= 'd0; sp_e2 <= 'd0; sp_e3 <= 'd0;
      acc_re <= 'd0; acc_im <= 'd0; acc_hh <= 'd0; acc_h4 <= 'd0;
      slot_a <= 'd0;
      a_known <= 1'b0;
    end else begin
      if (m_tvalid) begin
        if (a_first) begin
          exp_a <= m_tuser[23:16];
          base_bin <= base_bin_w;
          a_inc <= -({{11{hdr_delta[20]}}, hdr_delta[20:0]} << 11);
          a_first <= 1'b0;
          a_known <= sp_known;
          sp_use <= sp_use_w;
          slot_a <= slot_next;                          // 飛んだシンボルのスロットは古いまま飛ばす
          prev_start <= hdr_start;
          hist_exp[slot_next] <= m_tuser[23:16];
          acc_re <= 'd0; acc_im <= 'd0; acc_hh <= 'd0; acc_h4 <= 'd0;
        end
        rotA_sc <= sincos_rom[cur_phase[31:22]];
        rotA_i1 <= in_i; rotA_q1 <= in_q;
        rotA_bin1 <= a_bin;
        rotA_last1 <= m_tlast;
        rotA_v1 <= 1'b1;
        sp1 <= cur_is_sp;
        car1 <= cur_car;
        m1 <= cur_m;
        // キャリア 8191 → 0 の折り返し（ビン順なのでキャリア 5616 の後は 5617..8191 の空きを経て 0 に戻る）で mod 12 と m を 0 に
        a_m <= (cur_car == 13'd8191) ? 9'd0 : ((cur_cm == 4'd11) ? cur_m + 1'b1 : cur_m);
        a_phase <= cur_phase + (a_first ? -({{11{hdr_delta[20]}}, hdr_delta[20:0]} << 11) : a_inc)
                   - ((a_bin == N / 2 - 1) ? (a_inc << 13) : 32'd0);
        sp_e0 <= (a_first ? 32'd0 : sp_e0) + ((cur_is_grid && cur_pidx == 2'd0) ? {13'd0, in_e[24:6]} : 32'd0);
        sp_e1 <= (a_first ? 32'd0 : sp_e1) + ((cur_is_grid && cur_pidx == 2'd1) ? {13'd0, in_e[24:6]} : 32'd0);
        sp_e2 <= (a_first ? 32'd0 : sp_e2) + ((cur_is_grid && cur_pidx == 2'd2) ? {13'd0, in_e[24:6]} : 32'd0);
        sp_e3 <= (a_first ? 32'd0 : sp_e3) + ((cur_is_grid && cur_pidx == 2'd3) ? {13'd0, in_e[24:6]} : 32'd0);
        a_car <= cur_car + 1'b1;
        a_cmod12 <= (cur_car == 13'd8191) ? 4'd0 : ((cur_cm == 4'd11) ? 4'd0 : cur_cm + 1'b1);
        a_bin <= a_bin + 1'b1;
        if (m_tlast) begin
          a_bin <= 'd0;
          a_first <= 1'b1;
        end
      end else begin
        sp1 <= 1'b0;
      end
      // 段 2: 表の値、パイロット符号、H4 の読み出し発行（ポート A）
      rotA_v2 <= rotA_v1;
      rotA_i2 <= rotA_i1; rotA_q2 <= rotA_q1;
      rotA_c2 <= rotA_sc[15:0]; rotA_s2 <= rotA_sc[31:16];
      rotA_bin2 <= rotA_bin1; rotA_last2 <= rotA_last1;
      sp2 <= sp1 && rotA_v1;
      sgn2 <= pilot_sign_rom[car1];
      m2 <= m1;
      if (sp1 && rotA_v1) hist_addr_a <= {slot_a4, m1};
      // 段 3: 積和、シンボル書き込み、H_sp 書き込み（ポート A）
      rotA_v3 <= rotA_v2;
      rotA_pi <= rotA_i2 * rotA_c2 - rotA_q2 * rotA_s2;
      rotA_pq <= rotA_i2 * rotA_s2 + rotA_q2 * rotA_c2;
      rotA_bin3 <= rotA_bin2; rotA_last3 <= rotA_last2;
      sp3 <= sp2; sgn3 <= sgn2; m3 <= m2;
      if (rotA_v3) begin
        sym_we <= 1'b1;
        sym_waddr <= rotA_bin3;
        sym_wdata <= {y3_q, y3_i};
        if (rotA_last3) begin
          a_done <= 1'b1;
          a_sp_best <= (sp_e0 >= sp_e1 && sp_e0 >= sp_e2 && sp_e0 >= sp_e3) ? 2'd0 :
                       (sp_e1 >= sp_e2 && sp_e1 >= sp_e3) ? 2'd1 :
                       (sp_e2 >= sp_e3) ? 2'd2 : 2'd3;
          slot_a <= slot_a + 1'b1;
          done_slot <= slot_a;
        end
      end
      sp4 <= sp3;
      if (sp3) begin
        hist_we <= 1'b1;
        hist_addr_a <= {slot_a, m3};               // a_first の次のサイクル以降なので slot_a は更新済み
        hist_wdata <= {hsp3_q_w, hsp3_i_w};
        hsp3_i <= hsp3_i_w;
        hsp3_q <= hsp3_q_w;
      end
      // 段 4: H4（段 2 で発行 → 段 3 の端で読み出し → ここで有効）
      sp5 <= sp4;
      if (sp4) begin
        h4_i <= align(hist_rdata_a[12:0], exp_d4);
        h4_q <= align(hist_rdata_a[25:13], exp_d4);
        hsp4_i <= hsp3_i; hsp4_q <= hsp3_q;
      end
      // 段 5: 積算
      if (sp5) begin
        acc_re <= acc_re + prod_re;
        acc_im <= acc_im + prod_im;
        acc_hh <= acc_hh + {13'd0, prod_hh};
        acc_h4 <= acc_h4 + {13'd0, prod_h4};
      end
    end
  end

  // ============================================================
  // 受信後の処理と B2
  // ============================================================
  reg   signed [39:0] bacc_re = 'd0, bacc_im = 'd0;
  reg   [39:0]  bacc_hh = 'd0, bacc_h4 = 'd0;
  wire signed [40:0] s_total = $signed({1'b0, bacc_hh}) + $signed({1'b0, bacc_h4}) + (bacc_re <<< 1);
  wire signed [40:0] cpe_re = $signed({1'b0, bacc_hh}) + bacc_re;

  reg               at_valid = 1'b0;
  reg  signed [15:0] at_x = 'd0, at_y = 'd0;
  wire              ph_valid;
  wire  [31:0]      ph_meas;
  isdbt_atan2_seq i_atan2 (.clk(clk), .valid_in(at_valid), .x_in(at_x), .y_in(at_y), .valid_out(ph_valid), .angle_out(ph_meas));
  reg   signed [31:0] cpe_phase = 'd0;
  reg   signed [40:0] nx = 'd0, ny = 'd0;
  reg           norm_is_cpe = 1'b0;
  wire          norm_big = (nx > 41'sd16383) || (nx < -41'sd16384) || (ny > 41'sd16383) || (ny < -41'sd16384);
  reg   [2:0]   hist_fill = 'd0;
  wire          afc_run = afc_en && (hist_fill == 3'd4);

  reg   [45:0]  div_rem = 'd0;
  reg   [44:0]  div_num = 'd0;
  reg   [36:0]  div_den = 'd0;
  reg   [31:0]  div_q = 'd0;
  reg   [6:0]   div_cnt = 'd0;
  reg   [31:0]  csi_k = 'd0;
  wire  [45:0]  div_sh = {div_rem[44:0], div_num[44]};

  // B2（ビン順: キャリア car0 → 5616 → 0 → car0−1。格子 1 点 = 3 サイクル、履歴は 2 格子先読み）
  reg   [12:0]  b2_k = 'd0;
  reg   [12:0]  b2_n = 'd0;
  reg   [10:0]  b2_f = 'd0;
  reg   [10:0]  b2_q = 'd0;
  reg   [1:0]   b2_ph = 'd0;
  reg   [1:0]   b2_r0 = 'd0;
  reg           b2_hold = 1'b0;          // 格子 1872（k=5616）を発行した周期の残りは発行しない
  reg   [12:0]  b2_addr = 'd0;
  reg   [25:0]  hg_a = 'd0, hg_b = 'd0;
  reg   [3:0]   sl_a = 'd0, sl_b = 'd0, sl_a_p = 'd0, sl_b_p = 'd0;
  wire signed [8:0] exp_d_pa = $signed({1'b0, hist_exp[sl_a_p]}) - $signed({1'b0, exp_b});
  wire signed [8:0] exp_d_pb = $signed({1'b0, hist_exp[sl_b_p]}) - $signed({1'b0, exp_b});
  reg   signed [12:0] Hf_i = 'd0, Hf_q = 'd0;
  reg   signed [12:0] Hg_j_i = 'd0, Hg_j_q = 'd0, Hg_j1_i = 'd0, Hg_j1_q = 'd0;
  reg   [7:0]   tail_cnt = 'd0;
  wire  [10:0]  b2_f_next = (b2_f == M - 1) ? 11'd0 : b2_f + 1'b1;
  wire  [12:0]  car0_b = CENTER[12:0] - delta_s[12:0];

  reg           p_v [0:10];
  integer pi_;
  initial for (pi_ = 0; pi_ < 11; pi_ = pi_ + 1) p_v[pi_] = 1'b0;
  reg   signed [13:0] d_i = 'd0, d_q = 'd0;
  reg   [16:0]  cr = 'd0;
  reg   signed [12:0] Hb_i = 'd0, Hb_q = 'd0;
  reg   signed [31:0] di_m = 'd0, dq_m = 'd0;
  reg   signed [12:0] H2_i = 'd0, H2_q = 'd0, H_i = 'd0, H_q = 'd0, H3_i = 'd0, H3_q = 'd0, H4_i = 'd0, H4_q = 'd0;
  reg   signed [12:0] y_i = 'd0, y_q = 'd0, yp_i = 'd0, yp_q = 'd0;
  reg   [31:0]  rotB_sc = 'd0;
  reg   signed [28:0] yr_i = 'd0, yr_q = 'd0;
  reg   [26:0]  E1 = 'd0, E2 = 'd0, E3 = 'd0, E4 = 'd0;
  wire signed [26:0] prod_E_s = H_i * H_i + H_q * H_q;
  wire  [26:0]  prod_E = prod_E_s[26:0];
  reg   [5:0]   e_clz = 'd0, e_clz2 = 'd0, e_clz3 = 'd0, e_clz4 = 'd0, e_clz5 = 'd0;
  reg   [31:0]  e_norm = 'd0;
  reg   [15:0]  inv_f = 'd0;
  reg   signed [26:0] P_i = 'd0, P_q = 'd0, P5_i = 'd0, P5_q = 'd0, P6_i = 'd0, P6_q = 'd0;
  reg   signed [55:0] PI_i = 'd0, PI_q = 'd0;
  reg   [28:0]  inv_s = 'd0;
  reg   [43:0]  csi_m = 'd0, csi_m2 = 'd0;
  reg   [7:0]   d8_i = 'd0, d8_q = 'd0, c8 = 'd0;
  reg           out_v = 1'b0;

  reg   [31:0]  of_mem [0:15];
  reg           of_last [0:15];
  reg           of_we = 1'b0;
  reg   [3:0]   of_waddr = 'd0;
  reg   [31:0]  of_wdata = 'd0;
  reg           of_wlast = 1'b0;
  reg   [4:0]   of_wr = 'd0, of_rd = 'd0, of_wr_vis = 'd0;
  wire          of_empty = (of_wr_vis == of_rd);
  wire          of_full = ((of_wr - of_rd) >= 5'd15);
  reg   [23:0]  pk_bytes = 'd0;
  reg   [1:0]   pk_n = 'd0;
  always @(posedge clk) begin
    if (of_we) begin of_mem[of_waddr] <= of_wdata; of_last[of_waddr] <= of_wlast; end
    of_wr_vis <= (rst || !enable) ? 5'd0 : (of_we ? of_wr_vis + 1'b1 : of_wr_vis);
  end
  assign o_valid = !of_empty;
  assign o_data = of_mem[of_rd[3:0]];
  assign o_last = of_last[of_rd[3:0]];

  always @(posedge clk) begin
    at_valid <= 1'b0;
    of_we <= 1'b0;
    if (rst || !enable) begin
      state <= S_IDLE;
      afc_phase <= 'd0;
      afc_omega_r <= 'd0;
      dbg_mismatch <= 'd0;
      cpe_phase <= 'd0;
      sp_phase <= 'd0;
      sp_pred <= 'd0;
      sp_known <= 1'b0;
      sym_count <= 'd0;
      overrun_cnt <= 'd0;
      pending <= 'd0;
      hist_fill <= 'd0;
      of_wr <= 'd0; of_rd <= 'd0;
      pk_n <= 'd0;
      out_v <= 1'b0;
      for (pi_ = 0; pi_ < 11; pi_ = pi_ + 1) p_v[pi_] <= 1'b0;
    end else begin
      if (o_valid && o_ready) of_rd <= of_rd + 1'b1;
      // 受信完了: 次の受信のための位相予測を更新し、処理待ちに積む（IDLE で同時に取り込むなら増やさない）
      if (a_done) begin
        sp_pred <= eq_flags[2] ? eq_flags[5:4] + 1'b1 : a_sp_best + 1'b1;
        sp_known <= (eq_flags[2] || eq_flags[3]) ? 1'b1 : (a_known ? (a_sp_best == sp_use) : 1'b1);
        dbg_best <= a_sp_best; dbg_pred <= sp_use;
        if (a_known && a_sp_best != sp_use) dbg_mismatch <= dbg_mismatch + 1'b1;
        if (state != S_IDLE) begin
          overrun_cnt <= overrun_cnt + 1'b1;
          pending <= (pending == 2'd3) ? 2'd3 : pending + 1'b1;
        end
      end

      case (state)
        S_IDLE: begin
          if (pending != 2'd0 || a_done) begin
            if (!a_done) pending <= pending - 1'b1;
            slot_b <= done_slot;                         // a_done と同じ端で slot_a は進んでいる（done_slot は進む前の値）
            exp_b <= hist_exp[done_slot];
            base_b <= base_bin;
            sp_b <= eq_flags[2] ? eq_flags[5:4] : a_sp_best;
            sp_phase <= eq_flags[2] ? eq_flags[5:4] : a_sp_best;
            bacc_re <= acc_re; bacc_im <= acc_im; bacc_hh <= acc_hh; bacc_h4 <= acc_h4;
            if (!a_known || (!eq_flags[2] && !eq_flags[3] && a_sp_best != sp_use)) begin
              // 受信中 SP パスが無効（位相未知、または予測外れ）: 積算を空にして CSI = 0（消失）で出す。
              // 履歴のこのシンボルのスロットは古いままになるが、立ち上がり／同期外れ時だけ
              bacc_re <= 'd0; bacc_im <= 'd0; bacc_hh <= 'd0; bacc_h4 <= 'd0;
            end
            state <= S_B1_TAIL;
            tail_cnt <= 'd0;
          end
        end
        S_B1_TAIL: begin
          tail_cnt <= tail_cnt + 1'b1;
          if (tail_cnt == 8'd6) begin
            if (afc_run) begin
              nx <= {bacc_re[39], bacc_re}; ny <= {bacc_im[39], bacc_im};
              norm_is_cpe <= 1'b0;
              state <= S_NORM;
            end else begin
              afc_phase <= afc_phase + afc_omega_r;
              state <= S_CPE_ISSUE;
            end
          end
        end
        S_AFC_WAIT: begin
          if (ph_valid) begin
            afc_omega_r <= afc_omega_r + ($signed(ph_meas) >>> 4);
            afc_phase <= afc_phase + afc_omega_r + ($signed(ph_meas) >>> 4);   // 次の受信（2,048 サイクル後）までに進める
            state <= S_CPE_ISSUE;
          end
        end
        S_CPE_ISSUE: begin
          nx <= cpe_re; ny <= {bacc_im[39], bacc_im};
          norm_is_cpe <= 1'b1;
          state <= S_NORM;
        end
        S_NORM: begin
          if (norm_big) begin
            nx <= nx >>> 1; ny <= ny >>> 1;
          end else if (nx == 41'sd0 && ny == 41'sd0) begin
            // 積算が空（履歴なし）: 角度 0 扱い。CORDIC の atan2(0,0) は不定値を返す
            if (norm_is_cpe) begin
              cpe_phase <= 32'sd0;
              cpe_dbg <= 'd0;
              div_num <= 45'd1872 << 34;
              div_den <= (s_total[40] || s_total[39:37] != 3'd0) ? 37'h1FFFFFFFFF : s_total[36:0];
              div_rem <= 'd0; div_q <= 'd0; div_cnt <= 'd0;
              state <= S_DIV;
            end else begin
              afc_phase <= afc_phase + afc_omega_r;
              state <= S_CPE_ISSUE;
            end
          end else begin
            at_valid <= 1'b1;
            at_x <= nx[15:0]; at_y <= ny[15:0];
            state <= norm_is_cpe ? S_CPE_WAIT : S_AFC_WAIT;
          end
        end
        S_CPE_WAIT: begin
          if (ph_valid) begin
            cpe_phase <= (cpe_en && hist_fill == 3'd4) ? $signed(ph_meas) : 32'sd0;
            cpe_dbg <= ph_meas[31:24];
            div_num <= 45'd1872 << 34;
            div_den <= (s_total[40] || s_total[39:37] != 3'd0) ? 37'h1FFFFFFFFF : s_total[36:0];
            div_rem <= 'd0;
            div_q <= 'd0;
            div_cnt <= 'd0;
            state <= S_DIV;
          end
        end
        S_DIV: begin
          if (div_cnt < 7'd45) begin
            if (div_sh >= {9'd0, div_den}) begin
              div_rem <= div_sh - {9'd0, div_den};
              div_q <= {div_q[30:0], 1'b1};
            end else begin
              div_rem <= div_sh;
              div_q <= {div_q[30:0], 1'b0};
            end
            div_num <= {div_num[43:0], 1'b0};
            div_cnt <= div_cnt + 1'b1;
          end else begin
            csi_k <= (div_den == 'd0) ? 32'd0 : div_q;
            b2_k <= car0_b;
            b2_n <= 'd0;
            b2_f <= car0_b / 3;
            b2_r0 <= car0_b % 3;
            b2_q <= 'd0; b2_ph <= 'd0; b2_hold <= 1'b0;
            b2_addr <= 'd0;                              // car0 はビン 0
            Hg_j_i <= 'd0; Hg_j_q <= 'd0; Hg_j1_i <= 'd0; Hg_j1_q <= 'd0;
            state <= S_B2;
          end
        end
        S_B2: begin
          case (b2_ph)
            2'd0: begin
              hist_raddr <= {grid_slot(sp_b, b2_f, slot_b, 1'b0), b2_f[10:2]};
              sl_a <= grid_slot(sp_b, b2_f, slot_b, 1'b0);
              hg_b <= hist_rdata;
              sl_a_p <= sl_a; sl_b_p <= sl_b;
            end
            2'd1: begin
              hist_raddr <= {grid_slot(sp_b, b2_f, slot_b, 1'b1), b2_f[10:2]};
              sl_b <= grid_slot(sp_b, b2_f, slot_b, 1'b1);
              Hf_i <= (align(hg_a[12:0], exp_d_pa) + align(hg_b[12:0], exp_d_pb)) >>> 1;
              Hf_q <= (align(hg_a[25:13], exp_d_pa) + align(hg_b[25:13], exp_d_pb)) >>> 1;
            end
            default: begin
              hg_a <= hist_rdata;
              Hg_j_i <= Hg_j1_i; Hg_j_q <= Hg_j1_q;
              Hg_j1_i <= Hf_i; Hg_j1_q <= Hf_q;
            end
          endcase
          if (b2_q >= 11'd3 && b2_n < TOTAL && !(b2_q == 11'd3 && b2_ph < b2_r0) && !b2_hold) begin
            sym_raddr <= b2_addr;
            p_v[0] <= 1'b1;
            cr <= (b2_ph == 2'd0) ? 17'd0 : (b2_ph == 2'd1) ? 17'd21845 : 17'd43691;
            Hb_i <= Hg_j_i; Hb_q <= Hg_j_q;
            d_i <= Hg_j1_i - Hg_j_i; d_q <= Hg_j1_q - Hg_j_q;
            b2_n <= b2_n + 1'b1;
            if (b2_k == TOTAL - 1) begin
              b2_k <= 'd0;
              b2_addr <= base_b;
              b2_hold <= 1'b1;
            end else begin
              b2_k <= b2_k + 1'b1;
              b2_addr <= b2_addr + 1'b1;
            end
          end else begin
            p_v[0] <= 1'b0;
          end
          if (b2_ph == 2'd2) begin
            b2_ph <= 'd0;
            b2_hold <= 1'b0;
            b2_f <= b2_f_next;
            b2_q <= b2_q + 1'b1;
            if (b2_n >= TOTAL) begin
              state <= S_B2_TAIL;
              tail_cnt <= 'd0;
            end
          end else begin
            b2_ph <= b2_ph + 1'b1;
          end
        end
        S_B2_TAIL: begin
          p_v[0] <= 1'b0;
          tail_cnt <= tail_cnt + 1'b1;
          if (tail_cnt == 8'd16) state <= S_FLUSH;
        end
        S_FLUSH: begin
          if (!of_full) begin
            of_we <= 1'b1; of_waddr <= of_wr[3:0];
            of_wdata <= (pk_n == 2'd0) ? 32'd0 : (pk_n == 2'd1) ? {24'd0, pk_bytes[7:0]} :
                        (pk_n == 2'd2) ? {16'd0, pk_bytes[15:0]} : {8'd0, pk_bytes[23:0]};
            of_wlast <= 1'b1;
            of_wr <= of_wr + 1'b1;
            pk_n <= 'd0;
            sym_count <= sym_count + 1'b1;
            if (hist_fill != 3'd4) hist_fill <= hist_fill + 1'b1;
            state <= S_IDLE;
          end
        end
        default: state <= S_IDLE;
      endcase

      // ---- B2 パイプライン ----
      for (pi_ = 1; pi_ < 11; pi_ = pi_ + 1) p_v[pi_] <= p_v[pi_ - 1];
      di_m <= d_i * $signed({1'b0, cr});
      dq_m <= d_q * $signed({1'b0, cr});
      H2_i <= Hb_i; H2_q <= Hb_q;
      H_i <= sat13(H2_i + (di_m >>> 16));
      H_q <= sat13(H2_q + (dq_m >>> 16));
      y_i <= sym_rdata[12:0]; y_q <= sym_rdata[25:13];
      rotB_sc <= sincos_rom[cpe_phase[31:22]];
      yr_i <= y_i * $signed(rotB_sc[15:0]) + y_q * $signed(rotB_sc[31:16]);
      yr_q <= y_q * $signed(rotB_sc[15:0]) - y_i * $signed(rotB_sc[31:16]);
      E1 <= prod_E;
      H3_i <= H_i; H3_q <= H_q;
      yp_i <= sat13((yr_i + 29'sd16384) >>> 15);
      yp_q <= sat13((yr_q + 29'sd16384) >>> 15);
      H4_i <= H3_i; H4_q <= H3_q;
      e_clz <= clz32({5'd0, E1});
      E2 <= E1;
      P_i <= yp_i * H4_i + yp_q * H4_q;
      P_q <= yp_q * H4_i - yp_i * H4_q;
      e_norm <= {5'd0, E2} << e_clz;
      e_clz2 <= e_clz; E3 <= E2;
      inv_f <= recip_rom[e_norm[30:21]];
      e_clz3 <= e_clz2; E4 <= E3; P5_i <= P_i; P5_q <= P_q;
      inv_s <= {12'd0, 1'b1, inv_f} << ((e_clz3 < 6'd6) ? 6'd0 : (e_clz3 - 6'd6));
      P6_i <= P5_i; P6_q <= P5_q;
      csi_m <= E4[26:8] * csi_k;
      e_clz4 <= e_clz3;
      PI_i <= P6_i * $signed({1'b0, inv_s});
      PI_q <= P6_q * $signed({1'b0, inv_s});
      csi_m2 <= csi_m;
      e_clz5 <= e_clz4;
      d8_i <= (e_clz5 == 6'd32) ? 8'd0 : sat8s((PI_i + 56'sd34359738368) >>> 36);
      d8_q <= (e_clz5 == 6'd32) ? 8'd0 : sat8s((PI_q + 56'sd34359738368) >>> 36);
      c8 <= (e_clz5 == 6'd32) ? 8'd0 : sat8u(csi_m2[43:20] > 24'd255 ? 32'd255 : {8'd0, csi_m2[43:20]});
      out_v <= p_v[8];
      if (out_v) begin
        case (pk_n)
          2'd0: begin pk_bytes <= {c8, d8_q, d8_i}; pk_n <= 2'd3; end
          2'd3: begin
            if (!of_full) begin
              of_we <= 1'b1; of_waddr <= of_wr[3:0]; of_wdata <= {d8_i, pk_bytes}; of_wlast <= 1'b0;
              of_wr <= of_wr + 1'b1;
            end
            pk_bytes[15:0] <= {c8, d8_q}; pk_n <= 2'd2;
          end
          2'd2: begin
            if (!of_full) begin
              of_we <= 1'b1; of_waddr <= of_wr[3:0]; of_wdata <= {d8_q, d8_i, pk_bytes[15:0]}; of_wlast <= 1'b0;
              of_wr <= of_wr + 1'b1;
            end
            pk_bytes[7:0] <= c8; pk_n <= 2'd1;
          end
          2'd1: begin
            if (!of_full) begin
              of_we <= 1'b1; of_waddr <= of_wr[3:0]; of_wdata <= {c8, d8_q, d8_i, pk_bytes[7:0]}; of_wlast <= 1'b0;
              of_wr <= of_wr + 1'b1;
            end
            pk_n <= 2'd0;
          end
        endcase
      end
    end
  end

endmodule
