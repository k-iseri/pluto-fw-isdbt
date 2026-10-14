// isdbt_sync: OFDM シンボル同期（捕捉・追従）と小数キャリア周波数オフセット（CFO）の推定・NCO
//
// 入力は isdbt_gi_corr の出力（c[n]、|c[n]|²、サンプル番号 idx）。シンボル長 T = N + Ng。
//   捕捉: enable 後 T サンプルの中で |c|² 最大の位置 n_max を探し、次のピーク予測 pred = n_max + T
//   追従: pred ± W の範囲で最大を探し、pred ← pred + T + (誤差 >> ALPHA)。見つけたピーク n_peak はシンボル末尾
//         （s + T − 1）なので、次のシンボルの有効部分は n_peak + 1 + Ng。FFT 窓は margin だけ早く開く
//         （GI の中。プリエコー耐性。ホストの参照実装と同じ）→ start_pos = n_peak + 1 + Ng − margin
//   CFO : ピークでの c の位相 φ（turns、2^32 = 1 回転）= ε（ビン間隔単位の小数 CFO）。IIR で平均し、
//         逆回転の 1 サンプルあたり位相増分 inc = −ε / N = −(φ >>> 13)（N = 8192）。NCO は生サンプルごとに加算
//   ロック: 追従窓内の最大 |c|² が移動平均の 1/4 未満の回が MISS_MAX 連続したら捕捉へ戻る
//   無音・雑音対策: 捕捉・追従とも「ピーク > シンボル内平均 × 9」（和 >> 10、T/1024 = 9）を要求する。
//         入力が無音のときに追従へ入って avg_peak = 0 で固まる（信号が来ても復帰しない）のを防ぐ
//   追従の探索開始は pred − W ちょうどではなく [pred − W, pred + W) に入っていれば開始し、
//         pred + W を過ぎていれば（捕捉のピークが窓の先頭 W 以内だった等）pred を 1 シンボル進める。
//         == −W 一致だけだと通り過ぎたときに永久に探索が始まらない
//
// SPDX-License-Identifier: MIT
// Copyright (c) 2026 k-iseri

`timescale 1ns/100ps

module isdbt_sync #(
  parameter N = 8192,
  parameter NG = 1024,
  parameter T = 9216,
  parameter W = 64,              // 追従の探索半幅（相関ピークは雑音で ±30 サンプル程度揺れる）
  parameter ALPHA = 4,           // 予測更新ゲイン 2^-ALPHA（揺れを 1/4 に平均、クロック偏差 ±20ppm の遅れは数サンプル）
  parameter MISS_MAX = 8
) (
  input                   clk,
  input                   rst,
  input       [3:0]       mode,            // 2 のとき動作
  input       [15:0]      margin,          // FFT 窓を早く開く量 [サンプル]

  // 相関器から（valid ごとに 1 サンプル）
  input                   c_valid,
  input  signed [27:0]    c_re,
  input  signed [27:0]    c_im,
  input       [31:0]      c_mag2,
  input       [31:0]      c_idx,

  // 生サンプル（NCO の進み用）
  input                   raw_valid,
  output reg  [31:0]      nco_phase,       // 逆回転の位相（turns）。生サンプルと同期

  // 窓エンジンへ
  output reg              start_valid,
  output reg  [31:0]      start_pos,

  // 状態
  output reg              locked,
  output reg  signed [31:0] cfo_inc,       // 1 サンプルあたりの位相増分（turns）
  output reg  [31:0]      peak_mag2,
  output reg  [15:0]      lock_losses,
  output      [31:0]      status_word,     // ヘッダ w7 用: {lock_losses[14:0], locked, peak_mag2[31:16]}
  output      [31:0]      dbg_word,        // レジスタ SYNC_STATUS: {state[1:0], in_search, locked, miss[3:0], acq_fail[7:0], lock_losses[15:0]}
  output      [31:0]      dbg_peak         // レジスタ SYNC_PEAK: {avg_peak[31:16], peak_mag2[31:16]}
);
  wire enable = (mode == 4'd2) || (mode == 4'd3);
  assign status_word = {lock_losses[14:0], locked, peak_mag2[31:16]};

  localparam S_ACQ = 2'd0, S_TRACK = 2'd1;
  reg   [1:0]   state = S_ACQ;
  reg   [31:0]  cnt = 'd0;              // 捕捉中の経過サンプル数
  reg   [31:0]  max_mag = 'd0;
  reg   [31:0]  max_idx = 'd0;
  reg   signed [27:0] max_re = 'd0, max_im = 'd0;
  reg   [31:0]  pred = 'd0;
  reg           in_search = 1'b0;
  reg   [31:0]  avg_peak = 'd0;
  reg   [3:0]   miss = 'd0;
  reg           meas_fire = 1'b0;       // この周期の計測確定
  reg   [45:0]  sum_mag = 'd0;          // 計測区間（≈ T サンプル）の mag2 の和（ピーク/平均比の判定用）
  reg   [45:0]  meas_sum = 'd0;         // 計測確定時に使う和
  reg   [7:0]   acq_fail = 'd0;         // 捕捉でピーク/平均比が足りず捕捉をやり直した回数
  wire          acq_par_ok = (max_mag > sum_mag[45:10]);   // ピーク > 平均 × 9
  wire          trk_par_ok = (max_mag > meas_sum[45:10]);
  assign dbg_word = {state, in_search, locked, miss, acq_fail, lock_losses};
  assign dbg_peak = {avg_peak[31:16], peak_mag2[31:16]};

  wire signed [31:0] d_pred = c_idx - pred;   // 予測ピークからの相対位置
  // 注意: Verilog では符号なしが混ざった式は全体が符号なしになり >>> も論理シフトになる。
  // 符号付きの中間 wire で先に計算してから加える
  wire signed [31:0] pred_err = $signed(max_idx - pred);
  wire signed [31:0] pred_corr = pred_err >>> ALPHA;
  wire signed [32:0] avg_diff = $signed({1'b0, max_mag}) - $signed({1'b0, avg_peak});
  wire signed [32:0] avg_corr = avg_diff >>> 3;

  // ---- CFO: ピークの位相 ----
  reg               at_valid = 1'b0;
  reg  signed [15:0] at_x = 'd0, at_y = 'd0;
  wire              ph_valid;
  wire  [31:0]      ph_meas;
  isdbt_atan2 i_atan2 (
    .clk (clk), .valid_in (at_valid), .x_in (at_x), .y_in (at_y),
    .valid_out (ph_valid), .angle_out (ph_meas));
  reg   signed [31:0] cfo_acc = 'd0;
  reg               cfo_init = 1'b0;

  always @(posedge clk) begin
    start_valid <= 1'b0;
    at_valid <= 1'b0;
    meas_fire <= 1'b0;
    if (rst || !enable) begin
      state <= S_ACQ;
      cnt <= 'd0;
      max_mag <= 'd0;
      in_search <= 1'b0;
      locked <= 1'b0;
      miss <= 'd0;
      avg_peak <= 'd0;
      lock_losses <= 'd0;
      sum_mag <= 'd0;
      meas_sum <= 'd0;
      acq_fail <= 'd0;
      cfo_acc <= 'd0;
      cfo_init <= 1'b0;
      cfo_inc <= 'd0;
      nco_phase <= 'd0;
      peak_mag2 <= 'd0;
    end else begin
      if (raw_valid) nco_phase <= nco_phase + cfo_inc;
      if (c_valid) begin
        case (state)
          S_ACQ: begin
            if (c_mag2 > max_mag || cnt == 0) begin
              max_mag <= c_mag2; max_idx <= c_idx; max_re <= c_re; max_im <= c_im;
            end
            sum_mag <= (cnt == 0) ? {14'd0, c_mag2} : sum_mag + c_mag2;
            cnt <= cnt + 1'b1;
            if (cnt == T - 1) begin
              cnt <= 'd0;
              if (acq_par_ok) begin
                pred <= max_idx + T;
                avg_peak <= max_mag;
                state <= S_TRACK;
                in_search <= 1'b0;
                miss <= 'd0;
                sum_mag <= 'd0;
                // 最初のシンボル: このピークから次の窓を出しておく（追従が始まる前に 1 窓分）
                start_valid <= 1'b1;
                start_pos <= max_idx + 1 + NG - margin;
                at_valid <= 1'b1;
                at_x <= max_re >>> 12;
                at_y <= max_im >>> 12;
              end else begin
                acq_fail <= acq_fail + 1'b1;      // 無音・雑音: 捕捉をやり直す
              end
            end
          end
          S_TRACK: begin
            sum_mag <= sum_mag + c_mag2;
            if (!in_search) begin
              if (d_pred >= -W && d_pred < W) begin
                in_search <= 1'b1;
                max_mag <= c_mag2; max_idx <= c_idx; max_re <= c_re; max_im <= c_im;
              end else if (d_pred >= W) begin
                pred <= pred + T;                 // 探索窓を丸ごと逃した: 次のシンボルへ
              end
            end else begin
              if (c_mag2 > max_mag) begin
                max_mag <= c_mag2; max_idx <= c_idx; max_re <= c_re; max_im <= c_im;
              end
              if (d_pred == W) begin
                in_search <= 1'b0;
                meas_fire <= 1'b1;
                meas_sum <= sum_mag;
                sum_mag <= {14'd0, c_mag2};
              end
            end
          end
        endcase
      end
      // 計測確定（探索窓の末尾の次のクロック: max_* が最終値）
      if (meas_fire) begin
        peak_mag2 <= max_mag;
        if (max_mag >= (avg_peak >> 2) && trk_par_ok) begin
          miss <= 'd0;
          locked <= 1'b1;
          avg_peak <= avg_peak + avg_corr[31:0];
          pred <= pred + T + pred_corr;
          start_valid <= 1'b1;
          // 窓開始は生のピーク位置ではなく平均化した推定（pred + 誤差の 2^-ALPHA）から出す
          start_pos <= pred + pred_corr + 1 + NG - margin;
          at_valid <= 1'b1;
          at_x <= max_re >>> 12;
          at_y <= max_im >>> 12;
        end else begin
          pred <= pred + T;
          if (miss == MISS_MAX - 1) begin
            state <= S_ACQ;
            cnt <= 'd0;
            locked <= 1'b0;
            lock_losses <= lock_losses + 1'b1;
            cfo_init <= 1'b0;
          end else begin
            miss <= miss + 1'b1;
          end
        end
      end
      if (ph_valid) begin
        if (!cfo_init) begin
          cfo_acc <= ph_meas;
          cfo_init <= 1'b1;
        end else begin
          cfo_acc <= cfo_acc + (($signed(ph_meas) - cfo_acc) >>> 3);
        end
      end
      cfo_inc <= -(cfo_acc >>> 13);
    end
  end
endmodule
