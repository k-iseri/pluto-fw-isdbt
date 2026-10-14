// isdbt_eq: 散布パイロット（SP）によるチャネル推定と等化（design-v2 2b-3b、モード 4）
//
// 入力は同期 FFT（isdbt_fe_win → xfft）の出力ビン（12bit I/Q、自然順、ブロック浮動小数点の指数 blk_exp）。
// 1 シンボルを 3 つのパスで処理する（クロックは ADC クロック ≈ 61.4 MHz、1 シンボル = 69,700 サイクル）:
//
//   パス A（FFT 出力の受信、8192 サイクル）
//     ビン b（符号付き周波数）を e^{j2π θ_b} で回してシンボル BRAM に書く。θ_b = −b·Δ_n/N − δ·s_n/N − φ_afc [turns]
//       Δ_n: 窓開始と滑らかな時間軸の差（isdbt_sync の tim_delta、1/256 サンプル）。整数サンプルで動く窓のずれを
//            位相ランプで消す（帯域端で 1 サンプル = 2.1 rad。消さないとチャネル推定の時間平均が壊れる）
//       δ:   整数 CFO（ビンのずれ、ホストがレジスタで与える）。窓開始 s_n に依存する既知の位相
//       φ_afc: 残留小数 CFO による共通位相（下の AFC で積算）
//     同時に 4 通りの SP 候補位置（キャリア k mod 12 = 3p）のエネルギーを積算し、最大の p を SP 位相とする
//   パス B1（SP パス、~470 サイクル）
//     この位相の SP（k = 3p + 12m）について H_sp = y·(±1)·3/4 を履歴 BRAM（8 シンボル × 512）に書き、
//     4 シンボル前の同位相 H4 と Σ H_sp·conj(H4)（AFC: 4 シンボルの回転）、Σ|H_sp|²、Σ|H4|² を積算。
//     CPE（自シンボルの共通位相）= arg Σ H_sp·conj((H_sp + H4)/2) = arg(Σ|H_sp|² + Σ H_sp·conj(H4))
//     CSI 正規化用: S = Σ|H_sp + H4|² = Σ|H_sp|² + Σ|H4|² + 2 Re Σ H_sp·conj(H4)、平均|Hg|² = S/(4·468)
//   パス B2（等化パス、格子点ごとに 8 サイクル = 3 キャリア）
//     3 キャリア格子 j = k/3 の H を直近 2 シンボル（同位相）の平均で作り、線形補間（1/3, 2/3）で H(k)。
//     y' = y·e^{−jφ_cpe}、D = y'·conj(H)/|H|²（|H|² を正規化して逆数表）→ I/Q 8bit（LSB 1/64、±2.0）、
//     CSI = |H|²/平均 → 8bit（LSB 1/64、0〜4）。3 バイト {I, Q, CSI} を 32bit ワードに詰めて出す
//
// 固定小数点: ビン 12bit → 回転後 13bit、H 13bit、|H|² 26bit、逆数表 1024 × 16bit（1/m − 1、m ∈ [0.5,1)）、
// sin/cos 表 1024 × (16+16)、CSI 定数 K = ⌊1872·2^34 / S⌋ は逐次除算器で 1 シンボルに 1 回
// （CSI8 = ((|H|² >> 8)·K) >> 20 = 64·|H|²·4·468/S）。
// 表は scripts/gen_eq_tables.py が生成する isdbt_eq_tables.vh（sincos_tab、recip_tab、pilot_sign_tab）。
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

  // 制御（レジスタ）
  input  signed [7:0]     int_cfo,         // δ
  input       [7:0]       eq_flags,        // bit0 AFC 有効、bit1 CPE 有効、bit2 SP 位相固定、bit[5:4] 固定 SP 位相

  // FFT 出力
  input       [31:0]      m_tdata,
  input       [23:0]      m_tuser,         // [23:16] blk_exp
  input                   m_tvalid,
  input                   m_tlast,

  // この窓のヘッダ情報（isdbt_fe_win のヘッダ FIFO の先頭。窓の最初のビンでラッチ）
  input       [31:0]      hdr_start,
  input       [31:0]      hdr_delta,       // Δ_n（1/256 サンプル、mod N·256、下位 21bit）

  // 出力ワード列（isdbt_fe_out へ。valid/ready ハンドシェイク、last = フレーム最終ワード）
  output                  o_valid,
  input                   o_ready,
  output      [31:0]      o_data,
  output                  o_last,

  // 状態
  output reg  [1:0]       sp_phase,
  output reg  signed [31:0] afc_omega,     // turns/シンボル
  output      [31:0]      dbg_word         // {state[3:0], sp_phase[1:0], overrun, 1'b0, cpe_phase[11:0], sym_count[11:0]}
);
  `include "isdbt_eq_tables.vh"

  wire enable = (mode == 4'd4);
  wire afc_en = eq_flags[0];
  wire cpe_en = eq_flags[1];

  localparam [3:0] S_IDLE = 4'd0, S_A = 4'd1, S_B1 = 4'd2, S_B1_TAIL = 4'd3, S_AFC_WAIT = 4'd4, S_CPE_ISSUE = 4'd5,
                   S_CPE_WAIT = 4'd6, S_DIV = 4'd7, S_B2 = 4'd8, S_B2_TAIL = 4'd9, S_FLUSH = 4'd10, S_NORM = 4'd11;
  // atan2 入力の正規化: 2 つの 41bit 値を |x|,|y| < 2^14 になるまで同じだけ右シフト（逐次、最大 27 サイクル。バレルシフタより小さい）
  reg   signed [40:0] nx = 'd0, ny = 'd0;
  reg           norm_is_cpe = 1'b0;
  wire          norm_big = (nx > 41'sd16383) || (nx < -41'sd16384) || (ny > 41'sd16383) || (ny < -41'sd16384);

  reg   [3:0]   state = S_IDLE;
  reg   [11:0]  sym_count = 'd0;
  reg   [11:0]  cpe_phase_dbg = 'd0;
  reg           overrun = 1'b0;          // 前のシンボルの処理中に次の窓が来た
  reg   [2:0]   hist_fill = 'd0;         // 有効化後に処理したシンボル数（4 で履歴が揃う）
  assign dbg_word = {state, sp_phase, overrun, 1'b0, cpe_phase_dbg, sym_count};

  // ---- 表 ----
  (* rom_style = "block" *) reg   [31:0]  sincos_rom [0:1023];        // {sin16, cos16}
  (* rom_style = "block" *) reg   [15:0]  recip_rom [0:1023];         // (1/m − 1)·2^16
  (* rom_style = "block" *) reg           pilot_sign_rom [0:8191];    // 1 = パイロット値が負（w_k = 1）
  integer ti;
  initial begin
    for (ti = 0; ti < 1024; ti = ti + 1) begin
      sincos_rom[ti] = sincos_tab(ti);
      recip_rom[ti] = recip_tab(ti);
    end
    for (ti = 0; ti < 8192; ti = ti + 1) pilot_sign_rom[ti] = pilot_sign_tab(ti);
  end

  // ---- シンボル BRAM（8192 × {Q13, I13}）と履歴 BRAM（8 スロット × 512 × {Q13, I13}）----
  // 8K × 26 は 1 配列だと block 指定が infeasible と言われ分散 RAM（LUT 4.6k）になるので 4K × 26 の 2 バンクに分ける
  (* ram_style = "block" *) reg   [25:0]  sym_mem0 [0:N/2-1];
  (* ram_style = "block" *) reg   [25:0]  sym_mem1 [0:N/2-1];
  (* ram_style = "block" *) reg   [25:0]  hist_mem [0:4095];
  reg   [7:0]   hist_exp [0:7];
  integer hi;
  initial begin
    for (hi = 0; hi < 4096; hi = hi + 1) hist_mem[hi] = 26'd0;
    for (hi = 0; hi < N / 2; hi = hi + 1) begin sym_mem0[hi] = 26'd0; sym_mem1[hi] = 26'd0; end
    for (hi = 0; hi < 8; hi = hi + 1) hist_exp[hi] = 8'd0;
  end
  reg   [12:0]  sym_raddr = 'd0;
  reg   [12:0]  sym_waddr = 'd0;
  reg   [25:0]  sym_wdata = 'd0;
  reg           sym_we = 1'b0;
  reg   [25:0]  sym_rd0 = 'd0, sym_rd1 = 'd0;
  reg           sym_rsel = 1'b0;
  always @(posedge clk) begin
    sym_rd0 <= sym_mem0[sym_raddr[11:0]];
    sym_rd1 <= sym_mem1[sym_raddr[11:0]];
    sym_rsel <= sym_raddr[12];
    if (sym_we && !sym_waddr[12]) sym_mem0[sym_waddr[11:0]] <= sym_wdata;
    if (sym_we && sym_waddr[12]) sym_mem1[sym_waddr[11:0]] <= sym_wdata;
  end
  wire  [25:0]  sym_rdata = sym_rsel ? sym_rd1 : sym_rd0;
  reg   [11:0]  hist_raddr = 'd0;
  reg   [25:0]  hist_rdata = 'd0;
  reg   [11:0]  hist_waddr = 'd0;
  reg   [25:0]  hist_wdata = 'd0;
  reg           hist_we = 1'b0;
  always @(posedge clk) begin
    hist_rdata <= hist_mem[hist_raddr];
    if (hist_we) hist_mem[hist_waddr] <= hist_wdata;
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
  // 指数差 d（exp_old − exp_now）で 13bit 値を揃える: 古い値 × 2^d（±3 に制限、飽和）
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
  // 格子点 j の履歴スロット: 位相 p のシンボルから見て、j mod 4 の位相は a = (p − j mod 4) mod 4 シンボル前（と +4）
  function [2:0] grid_slot(input [1:0] p, input [10:0] j, input [2:0] cur, input plus4);
    reg [1:0] a;
    begin
      a = p - j[1:0];
      grid_slot = cur - {1'b0, a} - (plus4 ? 3'd4 : 3'd0);
    end
  endfunction

  // ============================================================
  // パス A: 受信・回転・SP エネルギー
  // ============================================================
  reg   [12:0]  a_bin = 'd0;             // 次に来るビン番号
  reg           a_first = 1'b1;
  reg   [31:0]  a_phase = 'd0;           // 現在のビンの位相（turns）
  reg   [31:0]  a_inc = 'd0;             // ビンごとの増分 = −Δ·2^11
  reg   [7:0]   cur_exp = 'd0;
  reg   signed [31:0] afc_phase = 'd0;   // φ_afc（turns）
  reg   [12:0]  base_bin = 'd0;          // キャリア 0 のビン = (δ − 2808) mod N
  reg   [12:0]  a_car = 'd0;             // ビンに対応するキャリア番号（mod N）
  reg   [3:0]   a_cmod12 = 'd0;
  reg   [31:0]  sp_e0 = 'd0, sp_e1 = 'd0, sp_e2 = 'd0, sp_e3 = 'd0;

  wire signed [13:0] delta_s = {{6{int_cfo[7]}}, int_cfo};
  wire [12:0] base_bin_w = delta_s[12:0] - CENTER[12:0];           // (δ − 2808) mod N
  wire [12:0] car0_w = CENTER[12:0] - delta_s[12:0];               // ビン 0 のキャリア番号 (mod N)
  wire [3:0]  car0_mod12_w = car0_w % 12;
  (* use_dsp = "yes" *) wire signed [27:0] ds_prod = delta_s * $signed({1'b0, hdr_start[12:0]});
  wire [31:0] init_phase = -({19'd0, ds_prod[12:0]} << 19) - afc_phase;   // −(δ·s mod N)/N − φ_afc
  wire [31:0] cur_phase = a_first ? init_phase : a_phase;
  wire [12:0] cur_car = a_first ? car0_w : a_car;
  wire [3:0]  cur_cm = a_first ? car0_mod12_w : a_cmod12;
  wire        cur_is_grid = (cur_car < TOTAL) && (cur_cm == 4'd0 || cur_cm == 4'd3 || cur_cm == 4'd6 || cur_cm == 4'd9);
  wire [1:0]  cur_pidx = (cur_cm == 4'd0) ? 2'd0 : (cur_cm == 4'd3) ? 2'd1 : (cur_cm == 4'd6) ? 2'd2 : 2'd3;

  wire signed [11:0] in_i = m_tdata[11:0];
  wire signed [11:0] in_q = m_tdata[27:16];
  wire [24:0] in_e = in_i * in_i + in_q * in_q;

  // 回転パイプライン: 段 1 表引き、段 2 乗算入力、段 3 積和、段 4 書き込み
  reg   [31:0]  rotA_sc = 'd0;
  reg   signed [11:0] rotA_i1 = 'd0, rotA_q1 = 'd0, rotA_i2 = 'd0, rotA_q2 = 'd0;
  reg   signed [15:0] rotA_c2 = 'd0, rotA_s2 = 'd0;
  reg   signed [28:0] rotA_pi = 'd0, rotA_pq = 'd0;
  reg           rotA_v1 = 1'b0, rotA_v2 = 1'b0, rotA_v3 = 1'b0;
  reg   [12:0]  rotA_bin1 = 'd0, rotA_bin2 = 'd0, rotA_bin3 = 'd0;
  reg           rotA_last1 = 1'b0, rotA_last2 = 1'b0, rotA_last3 = 1'b0;
  reg           a_done = 1'b0;           // 最後のビンが BRAM に入った
  reg   [1:0]   a_sp_best = 2'd0;

  always @(posedge clk) begin
    rotA_v1 <= 1'b0;
    a_done <= 1'b0;
    sym_we <= 1'b0;
    if (rst || !enable) begin
      a_bin <= 'd0;
      a_first <= 1'b1;
      rotA_v2 <= 1'b0; rotA_v3 <= 1'b0;
      sp_e0 <= 'd0; sp_e1 <= 'd0; sp_e2 <= 'd0; sp_e3 <= 'd0;
    end else begin
      if (m_tvalid) begin
        if (a_first) begin
          cur_exp <= m_tuser[23:16];
          base_bin <= base_bin_w;
          a_inc <= -({{11{hdr_delta[20]}}, hdr_delta[20:0]} << 11);
          a_first <= 1'b0;
        end
        rotA_sc <= sincos_rom[cur_phase[31:22]];
        rotA_i1 <= in_i; rotA_q1 <= in_q;
        rotA_bin1 <= a_bin;
        rotA_last1 <= m_tlast;
        rotA_v1 <= 1'b1;
        // 次の位相: b = N/2 で負の周波数に折り返す（−N·inc を足す）
        a_phase <= cur_phase + (a_first ? -({{11{hdr_delta[20]}}, hdr_delta[20:0]} << 11) : a_inc)
                   - ((a_bin == N / 2 - 1) ? (a_inc << 13) : 32'd0);
        // SP エネルギー
        sp_e0 <= (a_first ? 32'd0 : sp_e0) + ((cur_is_grid && cur_pidx == 2'd0) ? {7'd0, in_e} : 32'd0);
        sp_e1 <= (a_first ? 32'd0 : sp_e1) + ((cur_is_grid && cur_pidx == 2'd1) ? {7'd0, in_e} : 32'd0);
        sp_e2 <= (a_first ? 32'd0 : sp_e2) + ((cur_is_grid && cur_pidx == 2'd2) ? {7'd0, in_e} : 32'd0);
        sp_e3 <= (a_first ? 32'd0 : sp_e3) + ((cur_is_grid && cur_pidx == 2'd3) ? {7'd0, in_e} : 32'd0);
        a_car <= cur_car + 1'b1;
        a_cmod12 <= (cur_cm == 4'd11) ? 4'd0 : cur_cm + 1'b1;
        a_bin <= a_bin + 1'b1;
        if (m_tlast) begin
          a_bin <= 'd0;
          a_first <= 1'b1;
        end
      end
      rotA_v2 <= rotA_v1;
      rotA_i2 <= rotA_i1; rotA_q2 <= rotA_q1;
      rotA_c2 <= rotA_sc[15:0]; rotA_s2 <= rotA_sc[31:16];
      rotA_bin2 <= rotA_bin1; rotA_last2 <= rotA_last1;
      rotA_v3 <= rotA_v2;
      rotA_pi <= rotA_i2 * rotA_c2 - rotA_q2 * rotA_s2;
      rotA_pq <= rotA_i2 * rotA_s2 + rotA_q2 * rotA_c2;
      rotA_bin3 <= rotA_bin2; rotA_last3 <= rotA_last2;
      if (rotA_v3) begin
        sym_we <= 1'b1;
        sym_waddr <= rotA_bin3;
        sym_wdata <= {sat13((rotA_pq + 29'sd16384) >>> 15), sat13((rotA_pi + 29'sd16384) >>> 15)};
        if (rotA_last3) begin
          a_done <= 1'b1;
          a_sp_best <= (sp_e0 >= sp_e1 && sp_e0 >= sp_e2 && sp_e0 >= sp_e3) ? 2'd0 :
                       (sp_e1 >= sp_e2 && sp_e1 >= sp_e3) ? 2'd1 :
                       (sp_e2 >= sp_e3) ? 2'd2 : 2'd3;
        end
      end
    end
  end

  // ============================================================
  // パス B1 / B2
  // ============================================================
  reg   [2:0]   slot = 'd0;              // 現在のシンボルの履歴スロット
  wire  [2:0]   slot4 = slot - 3'd4;
  reg   [8:0]   b1_m = 'd0, b1_m_end = 'd0;
  reg   [12:0]  b1_k = 'd0;              // = 3p + 12m
  reg           b1_v1 = 1'b0, b1_v2 = 1'b0, b1_v3 = 1'b0, b1_v4 = 1'b0;
  reg   [8:0]   b1_m1 = 'd0, b1_m2 = 'd0, b1_m3 = 'd0;
  reg   [12:0]  b1_k1 = 'd0, b1_k2 = 'd0;
  reg   [25:0]  b1_y = 'd0, b1_h4raw = 'd0;
  reg           b1_sign = 1'b0;
  reg   signed [12:0] b1_hi = 'd0, b1_hq = 'd0, b1_h4i = 'd0, b1_h4q = 'd0;
  reg   signed [39:0] acc_re = 'd0, acc_im = 'd0;      // Σ H_sp·conj(H4)
  reg   [39:0]  acc_hh = 'd0, acc_h4 = 'd0;            // Σ|H_sp|², Σ|H4|²
  wire signed [8:0] exp_d4 = $signed({1'b0, hist_exp[slot4]}) - $signed({1'b0, cur_exp});
  wire signed [12:0] y_i_b1 = b1_y[12:0];
  wire signed [12:0] y_q_b1 = b1_y[25:13];
  wire signed [14:0] y3_i = y_i_b1 * 3;
  wire signed [14:0] y3_q = y_q_b1 * 3;
  wire signed [12:0] hsp_i = b1_sign ? -(y3_i >>> 2) : (y3_i >>> 2);
  wire signed [12:0] hsp_q = b1_sign ? -(y3_q >>> 2) : (y3_q >>> 2);
  // 注意: 符号なしの acc に符号付きの積を足す式は全体が符号なしになり、負の H が符号なし扱いになる（Verilog の規則）。
  // 積は符号付きの中間 wire で先に計算する
  wire signed [26:0] prod_hh = b1_hi * b1_hi + b1_hq * b1_hq;
  wire signed [26:0] prod_h4 = b1_h4i * b1_h4i + b1_h4q * b1_h4q;
  wire signed [26:0] prod_re = b1_hi * b1_h4i + b1_hq * b1_h4q;
  wire signed [26:0] prod_im = b1_hq * b1_h4i - b1_hi * b1_h4q;
  wire signed [40:0] s_total = $signed({1'b0, acc_hh}) + $signed({1'b0, acc_h4}) + (acc_re <<< 1);
  wire signed [40:0] cpe_re = $signed({1'b0, acc_hh}) + acc_re;

  // CORDIC atan2（AFC と CPE で共用）
  reg               at_valid = 1'b0;
  reg  signed [15:0] at_x = 'd0, at_y = 'd0;
  wire              ph_valid;
  wire  [31:0]      ph_meas;
  isdbt_atan2_seq i_atan2 (.clk(clk), .valid_in(at_valid), .x_in(at_x), .y_in(at_y), .valid_out(ph_valid), .angle_out(ph_meas));
  reg   signed [31:0] cpe_phase = 'd0;   // turns

  // CSI 定数の逐次除算: K = ⌊(1872 << 34) / S⌋
  reg   [45:0]  div_rem = 'd0;
  reg   [44:0]  div_num = 'd0;
  reg   [36:0]  div_den = 'd0;
  reg   [31:0]  div_q = 'd0;
  reg   [6:0]   div_cnt = 'd0;
  reg   [31:0]  csi_k = 'd0;
  wire  [45:0]  div_sh = {div_rem[44:0], div_num[44]};

  // B2（格子 1 点 = 3 サイクル = 3 キャリア、1 キャリア/サイクル。履歴は 2 格子先を先読み）
  //   周期 q: 格子 f = q を読む（ph0 に a、ph1 に b。読み出しは 2 サイクル後）。ph1 で f−1 の平均 Hf を作り、
  //   ph2 で H_cur ← H_next ← Hf。発行する格子は j = q − 3（H_cur = H[j]、H_next = H[j+1]）
  reg   [12:0]  b2_k = 'd0;
  reg   [10:0]  b2_f = 'd0;              // 読み出し中の格子
  reg   [10:0]  b2_q = 'd0;              // 周期番号
  reg   [1:0]   b2_ph = 'd0;
  reg   [12:0]  b2_addr = 'd0;
  wire  [10:0]  b2_fc = (b2_f >= M - 1) ? (M - 1) : b2_f;      // 末尾は M−1 を繰り返す（H_next = H_cur）
  reg   [25:0]  hg_a = 'd0, hg_b = 'd0;
  reg   [2:0]   sl_a = 'd0, sl_b = 'd0, sl_a_p = 'd0, sl_b_p = 'd0;
  wire signed [8:0] exp_d_pa = $signed({1'b0, hist_exp[sl_a_p]}) - $signed({1'b0, cur_exp});
  wire signed [8:0] exp_d_pb = $signed({1'b0, hist_exp[sl_b_p]}) - $signed({1'b0, cur_exp});
  reg   signed [12:0] Hf_i = 'd0, Hf_q = 'd0;                   // 読み終えた格子の平均
  reg   signed [12:0] Hg_j_i = 'd0, Hg_j_q = 'd0, Hg_j1_i = 'd0, Hg_j1_q = 'd0;   // H_cur, H_next
  reg   [7:0]   tail_cnt = 'd0;

  // B2 データパイプライン
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
  reg   [5:0]   e_clz = 'd0, e_clz2 = 'd0, e_clz3 = 'd0, e_clz4 = 'd0, e_clz5 = 'd0, e_clz6 = 'd0;
  reg   [31:0]  e_norm = 'd0;
  reg   [15:0]  inv_f = 'd0;
  reg   signed [26:0] P_i = 'd0, P_q = 'd0, P5_i = 'd0, P5_q = 'd0, P6_i = 'd0, P6_q = 'd0;
  reg   signed [55:0] PI_i = 'd0, PI_q = 'd0;
  reg   [28:0]  inv_s = 'd0;           // inv << (clz − 6)（clz ≥ 6。|H|² < 2^26）
  reg   [43:0]  csi_m = 'd0, csi_m2 = 'd0;
  reg   [7:0]   d8_i = 'd0, d8_q = 'd0, c8 = 'd0;
  reg           out_v = 1'b0;

  // 出力バイトパッカー → 小 FIFO（16 ワード）
  reg   [31:0]  of_mem [0:15];
  reg           of_last [0:15];
  reg           of_we = 1'b0;
  reg   [3:0]   of_waddr = 'd0;        // of_we と同時に確定（of_wr は同じ端で進むので直接使えない）
  reg   [31:0]  of_wdata = 'd0;
  reg           of_wlast = 1'b0;
  reg   [4:0]   of_wr = 'd0, of_rd = 'd0;
  reg   [4:0]   of_wr_vis = 'd0;       // 書き込み完了後に進む（読み側が見るポインタ。of_wr は 1 サイクル先行）
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
    hist_we <= 1'b0;
    at_valid <= 1'b0;
    b1_v1 <= 1'b0;
    of_we <= 1'b0;
    if (rst || !enable) begin
      state <= S_IDLE;
      slot <= 'd0;
      afc_phase <= 'd0;
      afc_omega <= 'd0;
      cpe_phase <= 'd0;
      sp_phase <= 'd0;
      sym_count <= 'd0;
      overrun <= 1'b0;
      hist_fill <= 'd0;
      of_wr <= 'd0; of_rd <= 'd0;
      pk_n <= 'd0;
      b1_v2 <= 1'b0; b1_v3 <= 1'b0; b1_v4 <= 1'b0;
      out_v <= 1'b0;
      for (pi_ = 0; pi_ < 11; pi_ = pi_ + 1) p_v[pi_] <= 1'b0;
    end else begin
      if (o_valid && o_ready) of_rd <= of_rd + 1'b1;
      if (m_tvalid && a_first && state != S_IDLE) overrun <= 1'b1;

      case (state)
        S_IDLE: begin
          if (a_done) begin
            sp_phase <= eq_flags[2] ? eq_flags[5:4] : a_sp_best;
            hist_exp[slot] <= cur_exp;
            b1_m <= 'd0;
            b1_m_end <= ((eq_flags[2] ? eq_flags[5:4] : a_sp_best) == 2'd0) ? 9'd468 : 9'd467;   // 位相 0 は右端 CP (k=5616) も
            b1_k <= {11'd0, (eq_flags[2] ? eq_flags[5:4] : a_sp_best)} * 13'd3;
            acc_re <= 'd0; acc_im <= 'd0; acc_hh <= 'd0; acc_h4 <= 'd0;
            state <= S_B1;
          end
        end
        S_B1: begin
          sym_raddr <= base_bin + b1_k;
          hist_raddr <= {slot4, b1_m};
          b1_m1 <= b1_m; b1_k1 <= b1_k;
          b1_v1 <= 1'b1;
          b1_m <= b1_m + 1'b1;
          b1_k <= b1_k + 13'd12;
          if (b1_m == b1_m_end) begin
            state <= S_B1_TAIL;
            tail_cnt <= 'd0;
          end
        end
        S_B1_TAIL: begin
          tail_cnt <= tail_cnt + 1'b1;
          if (tail_cnt == 8'd6) begin
            if (afc_en && hist_fill == 3'd4) begin
              nx <= {acc_re[39], acc_re}; ny <= {acc_im[39], acc_im};
              norm_is_cpe <= 1'b0;
              state <= S_NORM;
            end else begin
              state <= S_CPE_ISSUE;
            end
          end
        end
        S_AFC_WAIT: begin
          if (ph_valid) begin
            afc_omega <= afc_omega + ($signed(ph_meas) >>> 4);   // 4 シンボルの回転 /4、ゲイン 1/4
            state <= S_CPE_ISSUE;
          end
        end
        S_CPE_ISSUE: begin
          nx <= cpe_re; ny <= {acc_im[39], acc_im};
          norm_is_cpe <= 1'b1;
          state <= S_NORM;
        end
        S_NORM: begin
          if (norm_big) begin
            nx <= nx >>> 1; ny <= ny >>> 1;
          end else begin
            at_valid <= 1'b1;
            at_x <= nx[15:0]; at_y <= ny[15:0];
            state <= norm_is_cpe ? S_CPE_WAIT : S_AFC_WAIT;
          end
        end
        S_CPE_WAIT: begin
          if (ph_valid) begin
            cpe_phase <= (cpe_en && hist_fill == 3'd4) ? $signed(ph_meas) : 32'sd0;
            cpe_phase_dbg <= ph_meas[31:20];
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
            b2_k <= 'd0; b2_f <= 'd0; b2_q <= 'd0; b2_ph <= 'd0;
            b2_addr <= base_bin;
            Hg_j_i <= 'd0; Hg_j_q <= 'd0; Hg_j1_i <= 'd0; Hg_j1_q <= 'd0;
            state <= S_B2;
          end
        end
        // ---- B2: 周期 3 サイクル（上の宣言のコメント参照）----
        S_B2: begin
          case (b2_ph)
            2'd0: begin
              hist_raddr <= {grid_slot(sp_phase, b2_fc, slot, 1'b0), b2_fc[10:2]};
              sl_a <= grid_slot(sp_phase, b2_fc, slot, 1'b0);
              hg_b <= hist_rdata;                       // 前周期 ph1 発行（f−1 の b）
              sl_a_p <= sl_a; sl_b_p <= sl_b;           // f−1 のスロット
            end
            2'd1: begin
              hist_raddr <= {grid_slot(sp_phase, b2_fc, slot, 1'b1), b2_fc[10:2]};
              sl_b <= grid_slot(sp_phase, b2_fc, slot, 1'b1);
              Hf_i <= (align(hg_a[12:0], exp_d_pa) + align(hg_b[12:0], exp_d_pb)) >>> 1;     // f−1 の平均
              Hf_q <= (align(hg_a[25:13], exp_d_pa) + align(hg_b[25:13], exp_d_pb)) >>> 1;
            end
            default: begin
              hg_a <= hist_rdata;                       // この周期 ph0 発行（f の a）
              Hg_j_i <= Hg_j1_i; Hg_j_q <= Hg_j1_q;     // H_cur ← H_next ← Hf
              Hg_j1_i <= Hf_i; Hg_j1_q <= Hf_q;
            end
          endcase
          // 発行: 格子 j = q − 3 のキャリア r = ph
          if (b2_q >= 11'd3 && b2_k < TOTAL) begin
            sym_raddr <= b2_addr;
            p_v[0] <= 1'b1;
            cr <= (b2_ph == 2'd0) ? 17'd0 : (b2_ph == 2'd1) ? 17'd21845 : 17'd43691;
            Hb_i <= Hg_j_i; Hb_q <= Hg_j_q;
            d_i <= Hg_j1_i - Hg_j_i; d_q <= Hg_j1_q - Hg_j_q;
            b2_k <= b2_k + 1'b1;
            b2_addr <= b2_addr + 1'b1;
          end else begin
            p_v[0] <= 1'b0;
          end
          if (b2_ph == 2'd2) begin
            b2_ph <= 'd0;
            b2_f <= b2_f + 1'b1;
            b2_q <= b2_q + 1'b1;
            if (b2_q == M + 2) begin                    // 格子 M−1 を発行し終えた
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
            afc_phase <= afc_phase + afc_omega;
            slot <= slot + 1'b1;
            sym_count <= sym_count + 1'b1;
            if (hist_fill != 3'd4) hist_fill <= hist_fill + 1'b1;
            state <= S_IDLE;
          end
        end
        default: state <= S_IDLE;
      endcase

      // ---- B1 パイプライン: 段 1 アドレス発行（S_B1）→ 段 2 読み出し値 → 段 3 H_sp/H4・履歴書き → 段 4 積算 ----
      b1_v2 <= b1_v1;
      b1_k2 <= b1_k1; b1_m2 <= b1_m1;          // 発行 +1
      if (b1_v2) begin                           // 発行 +2: BRAM の読み出し値が揃う
        b1_y <= sym_rdata;
        b1_sign <= pilot_sign_rom[b1_k2];
        b1_h4raw <= hist_rdata;
        b1_m3 <= b1_m2;
      end
      b1_v3 <= b1_v2;
      if (b1_v3) begin
        hist_we <= 1'b1;
        hist_waddr <= {slot, b1_m3};
        hist_wdata <= {hsp_q, hsp_i};
        b1_h4i <= align(b1_h4raw[12:0], exp_d4);
        b1_h4q <= align(b1_h4raw[25:13], exp_d4);
        b1_hi <= hsp_i; b1_hq <= hsp_q;
      end
      b1_v4 <= b1_v3;
      if (b1_v4) begin
        acc_re <= acc_re + prod_re;
        acc_im <= acc_im + prod_im;
        acc_hh <= acc_hh + {13'd0, prod_hh};
        acc_h4 <= acc_h4 + {13'd0, prod_h4};
      end

      // ---- B2 パイプライン（毎サイクル進む）----
      for (pi_ = 1; pi_ < 11; pi_ = pi_ + 1) p_v[pi_] <= p_v[pi_ - 1];
      // 段 1（発行 +1）: 補間乗算
      di_m <= d_i * $signed({1'b0, cr});
      dq_m <= d_q * $signed({1'b0, cr});
      H2_i <= Hb_i; H2_q <= Hb_q;
      // 段 2（発行 +2）: H 確定、sym_rdata 到着、CPE 表引き
      H_i <= sat13(H2_i + (di_m >>> 16));
      H_q <= sat13(H2_q + (dq_m >>> 16));
      y_i <= sym_rdata[12:0]; y_q <= sym_rdata[25:13];
      rotB_sc <= sincos_rom[cpe_phase[31:22]];
      // 段 3: y' = y·(c − js)、|H|²
      yr_i <= y_i * $signed(rotB_sc[15:0]) + y_q * $signed(rotB_sc[31:16]);
      yr_q <= y_q * $signed(rotB_sc[15:0]) - y_i * $signed(rotB_sc[31:16]);
      E1 <= prod_E;
      H3_i <= H_i; H3_q <= H_q;
      // 段 4: y' 丸め、clz
      yp_i <= sat13((yr_i + 29'sd16384) >>> 15);
      yp_q <= sat13((yr_q + 29'sd16384) >>> 15);
      H4_i <= H3_i; H4_q <= H3_q;
      e_clz <= clz32({5'd0, E1});
      E2 <= E1;
      // 段 5: P = y'·conj(H)、正規化
      P_i <= yp_i * H4_i + yp_q * H4_q;
      P_q <= yp_q * H4_i - yp_i * H4_q;
      e_norm <= {5'd0, E2} << e_clz;
      e_clz2 <= e_clz; E3 <= E2;
      // 段 6: 逆数表
      inv_f <= recip_rom[e_norm[30:21]];
      e_clz3 <= e_clz2; E4 <= E3; P5_i <= P_i; P5_q <= P_q;
      // 段 7: inv を (clz − 6) ビット左へ（最大 2^26 倍 → 29bit）。44bit のバレルシフタより小さい
      inv_s <= {12'd0, 1'b1, inv_f} << ((e_clz3 < 6'd6) ? 6'd0 : (e_clz3 - 6'd6));
      P6_i <= P5_i; P6_q <= P5_q;
      csi_m <= E4[26:8] * csi_k;
      e_clz4 <= e_clz3;
      // 段 8: × inv_s（27bit × 29bit）。D8 = P·inv·2^(clz−42) = PI >> 36
      PI_i <= P6_i * $signed({1'b0, inv_s});
      PI_q <= P6_q * $signed({1'b0, inv_s});
      csi_m2 <= csi_m;
      e_clz5 <= e_clz4;
      // 段 9: 丸め（+1 >> 1）と 8bit 化。|H|² = 0（clz = 32）なら 0
      d8_i <= (e_clz5 == 6'd32) ? 8'd0 : sat8s((PI_i + 56'sd34359738368) >>> 36);
      d8_q <= (e_clz5 == 6'd32) ? 8'd0 : sat8s((PI_q + 56'sd34359738368) >>> 36);
      c8 <= (e_clz5 == 6'd32) ? 8'd0 : sat8u(csi_m2[43:20] > 24'd255 ? 32'd255 : {8'd0, csi_m2[43:20]});
      out_v <= p_v[8];
      // 段 10: パッカー（キャリアごとに 3 バイト、4 キャリアで 3 ワード）
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
