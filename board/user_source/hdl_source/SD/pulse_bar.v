`timescale 1ns/1ps
// ---------------------------------------------------------------------------
// pulse_bar.v — 音频脉动条（2026-10-03）
//
// 底部横条（全宽、高 40 行）随音乐律动：音频域算音量包络，视频域渲染。
// 方案（2026-09-30 与用户对齐）：底部横条 / 蓝→绿→红渐变 / 快升慢降 /
// 灵敏度 4 档 / 白色峰值刻度线 / 'Q' 开关（开关本体在 ctrl_core）。
//
// 音频域（clk_a，板上 sd_card_clk）：
//   包络跟随 |L|/|R| 最大值（音量调节后的信号 → 音量调低条也会矮，语义自然）
//     灵敏度 = 包络右移量 20-3*sens（sens 0..3 → 20/17/14/11）
//     攻击：amp8 > env 时每样本最多 +16（快弹）；衰减：每 32 样本 -1（慢落，
//     48kHz 下满格 ~170ms）
//   env 8 位 → 格雷码出（跨到视频域 2FF，多位二进制直传会出现过渡混合值）
//
// 视频域（clk_v，video_clk）：行计数 r_cnt（每帧 vs_r 复位、de_r 上升沿 +1，
//   0..719 自上而下）。row_fb = 719-r_cnt 为"距底行数"：
//     bar_hit = de_r && row_fb < 40 && row_fb < fill        （fill = env*40>>8）
//     峰值线  = de_r && row_fb == fill && 0 < fill < 40      （白色）
//   渐变（按距底行数 t=0 底 → 39 顶）：蓝(0,80,255) → 绿(60,220,80) →
//   红(255,50,40)，两段线性插值。
//
// ⚠ 条渲染在调色级（对比度/亮度）**之后**覆盖——条颜色为绝对色，不受调色影响。
// 注入点即 docs 里预留的"图像调节级"。
// ---------------------------------------------------------------------------
module pulse_bar #(
    parameter BAR_H = 64                        // 条高（行）。⚠ 必须 2 的幂：
                                                //   fill=env>>log2(BAR_H)、渐变断点
                                                //   都靠移位实现（避免除法）。2026-10-03
                                                //   用户实测 40 行脉动感不足，加高到 64。
)(
    // ---- 音频域 ----
    input  wire               clk_a,
    input  wire               rst_a,
    input  wire signed [27:0] aud_l,            // 音量调节后的左声道
    input  wire signed [27:0] aud_r,
    input  wire               aud_val,          // 输出样本有效（48kHz，×2 上采样流）
    input  wire [1:0]         sens_gray,        // 灵敏度（格雷码，来自 ctrl_core）
    input  wire               bar_en,           // 开关（同域，来自 ctrl_core）
    // ---- 视频域 ----
    input  wire               clk_v,
    input  wire               rst_v,
    input  wire               de_r,             // 与 vout 管线对齐的有效像素
    input  wire               vs_r,             // 帧同步（高 = 帧起始）
    // ---- 渲染输出（视频域）----
    // ⚠ 组合输出：bar_hit/bar_rgb 必须与 de_r 同拍（vout 管线对齐），打一拍
    //   会让条覆盖整体偏移 1 像素（与 vout_adj 的 de_r 之间无流水级）。
    output wire [23:0]        bar_rgb,
    output wire               bar_hit
);

    // ================= 音频域：包络 =================
    reg [1:0]  sens_s0, sens_s1;                // 格雷码 2FF（其实同域，防御性同步）
    always @(posedge clk_a or posedge rst_a) begin
        if (rst_a) begin sens_s0 <= 2'd0; sens_s1 <= 2'd0; end
        else     begin sens_s0 <= sens_gray; sens_s1 <= sens_s0; end
    end
    // 格雷 → 二进制（2 位：b1=g1, b0=g1^g0；⚠ 不要写成 {g1^g0, g0}——
    // 那会把灰 11 译成 1，灵敏度整体错一档，TB DBG 抓到过）
    wire [1:0] sens_bin = {sens_s1[1], sens_s1[1] ^ sens_s1[0]};
    wire [4:0] amp_shift = 5'd20 - {1'b0, sens_bin, 1'b0} - sens_bin; // 20-3*sens

    wire [27:0] abs_l = aud_l[27] ? (~aud_l + 1'b1) : aud_l;
    wire [27:0] abs_r = aud_r[27] ? (~aud_r + 1'b1) : aud_r;
    wire [27:0] amp_mx = (abs_l > abs_r) ? abs_l : abs_r;

    // 右移后饱和到 8 位
    wire [27:0] amp_s = amp_mx >> amp_shift;
    wire [7:0]  amp8  = (|amp_s[27:8]) ? 8'hFF : amp_s[7:0];

    reg [7:0]  env;
    reg [4:0]  dec_div;                         // 衰减分频：每 32 样本 -1
    always @(posedge clk_a or posedge rst_a) begin
        if (rst_a) begin
            env <= 8'd0; dec_div <= 5'd0;
        end else if (aud_val) begin
            dec_div <= dec_div + 1'b1;
            if (amp8 > env) begin
                // 快攻：一步最多 +16，且不超过 amp8（避免过冲）
                env <= (amp8 > env + 8'd16) ? (env + 8'd16) : amp8;
            end else if (dec_div == 5'd0 && env != 8'd0) begin
                env <= env - 1'b1;              // 慢落
            end
        end
    end

    // 包络跨域：8 位格雷码
    wire [7:0] env_gray = (env >> 1) ^ env;

    // ================= 视频域：渲染 =================
    reg [7:0] env_g0, env_g1;
    always @(posedge clk_v or posedge rst_v) begin
        if (rst_v) begin env_g0 <= 8'd0; env_g1 <= 8'd0; end
        else     begin env_g0 <= env_gray; env_g1 <= env_g0; end
    end
    // 格雷 → 二进制
    wire [7:0] env_v;
    genvar i;
    generate begin : g_gray2bin
        for (i = 0; i < 8; i = i + 1) begin : g_bit
            if (i == 7)      assign env_v[7] = env_g1[7];
            else             assign env_v[i] = env_v[i+1] ^ env_g1[i];
        end
    end endgenerate

    // 开关跨域（音频域 → 视频域，1 位 2FF）
    reg bar_en_v0, bar_en_v1;
    always @(posedge clk_v or posedge rst_v) begin
        if (rst_v) begin bar_en_v0 <= 1'b0; bar_en_v1 <= 1'b0; end
        else     begin bar_en_v0 <= bar_en; bar_en_v1 <= bar_en_v0; end
    end
    wire bar_en_v = bar_en_v1;

    // fill = env*BAR_H/256 = env>>2（BAR_H=64 是 2 的幂，纯移位）；0..63
    wire [7:0]  fill      = bar_en_v ? {2'b0, env_v[7:2]} : 8'd0;

    // 行计数：帧起始复位，**de 下降沿** +1（保证行内全程 r_cnt == 本行行号；
    // 若在上升沿 +1，行首两拍会用上一行行号 → 条顶边出现 2 像素毛边）
    reg [9:0] r_cnt;
    reg       de_d;
    // ⚠ de_d 必须**单独成块**（纯延迟线，无需复位）——曾与 r_cnt 同块，TD 报
    //   HDL-7238 "assignment under multiple clock edges"（异步复位块里混入
    //   不受复位保护的赋值），整个块被丢弃 → r_cnt 恒 0 → 条永不出现。
    always @(posedge clk_v) de_d <= de_r;
    always @(posedge clk_v or posedge rst_v) begin
        if (rst_v)              r_cnt <= 10'd0;
        else if (vs_r)          r_cnt <= 10'd0;
        else if (de_d && !de_r) r_cnt <= (r_cnt >= 10'd719) ? 10'd719 : r_cnt + 1'b1;
    end

    wire [9:0] row_fb = 10'd719 - r_cnt;        // 距底行数（0 = 最底行）
    wire       in_zone = (row_fb < BAR_H);
    wire       in_fill = (row_fb < {2'b0, fill});
    wire       is_peak = (row_fb == {2'b0, fill}) && (fill != 8'd0) && (fill < BAR_H);

    // 渐变色（锚点：t=0 底蓝 (0,80,255) → t=32 中绿 (60,220,80) → t=63 顶红
    // (246,65,49)），随 BAR_H=64 缩放：
    //   段1 t 0..31： r=t*2      g=80+t*4    b=255-t*5
    //   段2 t 32..63：tt=t-32   r=60+tt*6   g=220-tt*5   b=80-tt
    // ⚠ 断点必须随 BAR_H 走——BAR_H 从 40 改 64 时若沿用固定断点 20，
    //   段2 的 tt*9 在 t>39 后溢出回卷（花色）。
    wire [7:0] t6   = row_fb[5:0];              // 0..63
    wire [7:0] tt6  = t6 - 8'd32;
    wire [7:0] g_r1 = t6 * 2'd2;
    wire [7:0] g_g1 = 8'd80 + t6 * 3'd4;
    wire [7:0] g_b1 = 8'd255 - t6 * 3'd5;
    wire [7:0] g_r2 = 8'd60 + tt6 * 3'd6;
    wire [7:0] g_g2 = 8'd220 - tt6 * 3'd5;
    wire [7:0] g_b2 = 8'd80  - tt6;
    wire [23:0] grad = (row_fb < 10'd32) ? {g_r1, g_g1, g_b1}
                                         : {g_r2, g_g2, g_b2};

    assign bar_hit = de_r && in_zone && (in_fill || is_peak);
    assign bar_rgb = is_peak ? 24'hFF_FF_FF : grad;   // 峰值线白色

endmodule
