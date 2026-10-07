module video_delay
#(
	parameter DATA_WIDTH = 24,                      // Video data one clock data width
	parameter MIX_PIPELINE = 0                      // Registered mixed word before unpacking
)
(
	input                       video_clk,          // Video pixel clock
	input                       rst,
	output                      read_en,            // Read data enable (FIFO pop)
	input [31:0]                read_data,          // 读 FIFO 数据（RGB565，2 像素/字）
	input                      hs,                 // horizontal synchronization
	input                      vs,                 // vertical synchronization
	input                      de,                 // video valid

	output                      hs_r,                 // horizontal synchronization
	output                      vs_r,                 // vertical synchronization
	output                      de_r,                 // video valid
	output                      de_word,              // timing at FIFO word fetch stage
	output                      vs_word,
	output[DATA_WIDTH - 1:0]    vout_data           // video data

);
// ---------------------------------------------------------------------------
// RGB565 读侧解包 + 2:1 串行化（720p 升级，2026-09-27；同日修像素对齐 bug）
// ---------------------------------------------------------------------------
// 帧缓冲 1 字 = 2 像素（word = {pix1[15:0], pix0[15:0]}，pix = {R5,G6,B5}，
// 低半字 = 偶数下标像素，见 sd_card_bmp 打包器）。显示仍按像素率节拍，
// FIFO 按字率弹出（每 2 个活动拍弹 1 次），带宽减半。
//
// 逐拍对齐（活动行内偏移 o = 0..1279，每行 640 字；c = de_d[18] 窗口内拍号）：
//   p  在 de_d[18] 活动拍翻转，行首复位 0 → p(c) = c mod 2
//   re = de_d[18] & ~p → 偶数拍弹第 c/2 字，dout 在 c+1 拍有效并保持
//   显示偏移 o 的 vout_r 在捕获拍 c = o+1 采样：pd(c) = o mod 2，
//   read_data(c) = word ⌊o/2⌋ →
//     o 偶（pd=0）→ lo(word o/2) = 偶数像素 2k
//     o 奇（pd=1）→ hi(word o/2) = 奇数像素 2k+1
//   ⚠ 两个分支不能对调：对调 = 相邻像素左右互换，平滑区看不出、边缘出现
//     1px 重影，肉眼看是"异常锐利"——2026-09-27 上板实测踩坑（仿真盲区，
//     视频读通道不在 boardtest 内；独立自检见 boardtest vsrc/tb_vdelay.v）。
// de/hs/vs 流水深度不变（de_r = de_d[20]），首像素恰落首个 de_r 活动拍。
// 565→888 位复制：R8={r5,r5[4:2]}，G8={g6,g6[5:4]}，B8={b5,b5[4:2]}。
// 跨行：行间 d18 无效拍把 p 复位 0，每行独立对齐；行尾 dout 保持供末像素捕获。
// ---------------------------------------------------------------------------
reg [21:0] hs_d;
reg [21:0] vs_d;
reg [21:0] de_d;
reg[DATA_WIDTH - 1:0]  vout_data_r;

wire       d18 = de_d[18];
reg        p, pd, pd_mix;

assign read_en = d18 & ~p;
assign hs_r = hs_d[20 + MIX_PIPELINE];
assign vs_r = vs_d[20 + MIX_PIPELINE];
assign de_r = de_d[20 + MIX_PIPELINE];
assign vout_data = vout_data_r;
assign de_word = de_d[18];
assign vs_word = vs_d[18];
wire display_hi = MIX_PIPELINE ? pd_mix : pd;

wire [4:0] lo_r = read_data[15:11];
wire [5:0] lo_g = read_data[10:5];
wire [4:0] lo_b = read_data[4:0];
wire [4:0] hi_r = read_data[31:27];
wire [5:0] hi_g = read_data[26:21];
wire [4:0] hi_b = read_data[20:16];

always @(posedge video_clk or posedge rst) begin
	if (rst == 1'b1)
		vout_data_r <= {DATA_WIDTH{1'b0}};
	else if (display_hi)                // 显示奇偏移：奇数像素（高半字）
		vout_data_r <= {hi_r, hi_r[4:2], hi_g, hi_g[5:4], hi_b, hi_b[4:2]};
	else                                // 显示偶偏移：偶数像素（低半字）
		vout_data_r <= {lo_r, lo_r[4:2], lo_g, lo_g[5:4], lo_b, lo_b[4:2]};
end
always @(posedge video_clk or posedge rst) begin
	if (rst) begin
		hs_d <= 22'b0;
		vs_d <= 22'b0;
		de_d <= 22'b0;
		p    <= 1'b0;
		pd   <= 1'b0;
		pd_mix <= 1'b0;
	end
	else begin
		hs_d <= {hs_d[20:0], hs};
		vs_d <= {vs_d[20:0], vs};
		de_d <= {de_d[20:0], de};
		p    <= d18 ? ~p : 1'b0;
		pd   <= p;
		pd_mix <= pd;
	end
end
endmodule
