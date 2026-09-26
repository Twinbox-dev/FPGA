// vsrc/audio_path.v — 音频双缓冲乒乓（3a）
//
// 与图像的双帧缓冲同理：装载中的新音频与正在播放的旧音频不能共用同一块缓冲，
// 否则要么切走旧音、要么没法在提交前把新音装好。故两路 FIFO 乒乓：
//
//   卡 ─► wav_reader ─(PCM)─► audio_path ─(48kHz)─► o_*
//                                ├ FIFO[prim_sel]  装载中（写）
//                                └ FIFO[aud_sel]   播放中（读）
//
// 角色：prim_sel=正在装载新音频的 FIFO；aud_sel=正在播放的 FIFO。
//   - 读（i_rd_en）永远从 aud_sel —— 旧音频播到切换瞬间，无静音
//   - 提交（i_commit）：aud_sel ⇐ prim_sel（新音从 sample 0 起播），
//     prim_sel ⇐ 旧 aud_sel，并把它清空（下一张图的装载缓冲）
//   - 写目标（wr_sel）分三段：
//       未提交过（!i_play_en）          → 写 prim（首图音频灌入）
//       提交过且正在装载下一张配对音（i_load_aud）→ 写 prim（新音装载）
//       提交过且无装载（续播期）        → 写 aud —— 同一张 WAV 边播边补，
//         否则播放 FIFO 只有装载期的 ~2k 样本（≈40ms），长尾 WAV 必下溢
//   - 无配对图提交（i_silence）：两个 FIFO 同拍清空 → 静音
//     （否则 prim 里残留上一张的音频尾，提交后会被误播）
//
// 复位角色：aud_sel=0（先空播静音），prim_sel=1（首图音频灌 FIFO1）。
module audio_path (
    input  wire        clk,
    input  wire        rst_n,

    // ---- 写侧（wav_reader PCM 流）----
    input  wire        i_sval,
    input  wire signed [15:0] i_left,
    input  wire signed [15:0] i_right,

    // ---- 控制 ----
    input  wire        i_commit,         // 提交：翻转角色 + 清空旧播放 FIFO
    input  wire        i_silence,        // 本次提交无配对音：两 FIFO 同清（静音）
    input  wire        i_play_en,        // 已提交过（audio_enable）
    input  wire        i_load_aud,       // 正在装载下一张图的配对音频
    input  wire        i_rd_en,          // 48kHz 节拍

    // ---- 读侧（播放输出）----
    output reg  signed [15:0] o_left,
    output reg  signed [15:0] o_right,
    output reg         o_sval,
    output reg         o_underrun,

    // ---- 状态 ----
    output wire [11:0] o_prim_fill,      // 装载 FIFO 填充（提交就绪判断用）
    output wire [11:0] o_wr_fill         // 当前写入目标填充（上游节流判断用）
);

    reg        aud_sel;                  // 播放的 FIFO（复位 0）
    reg        prim_sel;                 // 装载的 FIFO（复位 1）

    // 写目标：未播过 / 正在装载新音 → prim；续播期 → aud（边播边补）
    wire wr_prim = !i_play_en || i_load_aud;
    wire wr_sel  = wr_prim ? prim_sel : aud_sel;

    wire [11:0] fill0, fill1;
    wire [11:0] prim_fill = prim_sel ? fill1 : fill0;
    wire [11:0] wr_fill   = wr_sel   ? fill1 : fill0;
    assign o_prim_fill = prim_fill;
    assign o_wr_fill   = wr_fill;

    wire        s0, s1, u0, u1;
    wire signed [15:0] l0, l1, r0, r1;

    audio_fifo u_fifo0 (
        .clk        (clk),
        .rst_n      (rst_n),
        .i_sval     (i_sval && !wr_sel),
        .i_left     (i_left),
        .i_right    (i_right),
        .i_flush    (i_commit && (!aud_sel || i_silence)),
        .i_rd_en    (i_rd_en && !aud_sel),
        .o_left     (l0),
        .o_right    (r0),
        .o_sval     (s0),
        .o_underrun (u0),
        .o_fill     (fill0)
    );

    audio_fifo u_fifo1 (
        .clk        (clk),
        .rst_n      (rst_n),
        .i_sval     (i_sval && wr_sel),
        .i_left     (i_left),
        .i_right    (i_right),
        .i_flush    (i_commit && (aud_sel || i_silence)),
        .i_rd_en    (i_rd_en && aud_sel),
        .o_left     (l1),
        .o_right    (r1),
        .o_sval     (s1),
        .o_underrun (u1),
        .o_fill     (fill1)
    );

    // 播放输出 mux
    always @(*) begin
        if (aud_sel) begin
            o_left = l1; o_right = r1; o_sval = s1; o_underrun = u1;
        end
        else begin
            o_left = l0; o_right = r0; o_sval = s0; o_underrun = u0;
        end
    end

    // 提交：翻转角色
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            aud_sel  <= 1'b0;
            prim_sel <= 1'b1;
        end
        else if (i_commit) begin
            aud_sel  <= prim_sel;
            prim_sel <= ~prim_sel;
        end
    end

endmodule
