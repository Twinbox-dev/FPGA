// vsrc/vga_ctrl.v — VGA 640x480@60 时序发生器 + 帧存储取像素
//
// 上游：mem_sim 读口（板级 frame_read_write 的 read_* 口）
// 下游：VGA 引脚 —— 仿真给 nvboard 看图 / TB 捕帧比对
// 板级：时序参数与握手照用，输出形态改为喂 HDMI 核的 AXIS 输入；跑在 25MHz 像素域
// 全局视图见 docs/architecture.md
//
// 时序参数与 E5/8_vga 相同（像素时钟 25.175MHz 标称）。
//
// 本模块跑在**像素域**：仿真里由顶层给 1/4 时钟使能 i_ce（clk 视作 100MHz
// mem_clk，像素 25MHz，比例与板级 PLL 一致），板级则直接挂 25MHz 像素时钟、
// i_ce 恒 1。这个比例不能省 —— 存储侧的补水窗口全靠它（详见 mem_sim.v 头注释）。
//
// ---------------------------------------------------------------------------
// 读时序（对齐例程 video_timing_data.v + video_delay.v）
// ---------------------------------------------------------------------------
// 例程的做法：
//   - read_req 在**场同步下降沿**拉高，保持到 read_req_ack；存储侧借此清空
//     读 FIFO 并从帧首地址重新取数
//   - 随后的场消隐（本时序为 35 行 ≈ 28000 拍）用来预填 FIFO，有效行开始时
//     FIFO 已满，不会下溢
//   - 有效像素期逐拍 read_en 弹一个字，read_data **下一拍**才有效
//     （例程 FIFO dout 是寄存输出）
//   - 例程用 video_delay 把 hs/vs/de 打 21 拍来吸收这个延迟；这里只需 2 拍，
//     因为仿真是单时钟、没有例程那些跨域与 IP 内部流水
//
// 本模块的流水对齐（总延迟 2 拍，三路信号同步偏移，相互关系不变）：
//   拍 n   : de_raw=1 → read_en=1，存储侧弹出像素
//   拍 n+1 : read_data = 该像素；de_d0=1
//   拍 n+2 : vga_rgb / vga_blank_n / vga_hsync / vga_vsync 一并给出
module vga_ctrl (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        i_ce,          // 像素时钟使能（板级恒 1）

    // ---- 帧存储读口（mem_sim / frame_read_write）----
    output reg         o_read_req,
    input  wire        i_read_req_ack,
    output wire        o_read_en,
    input  wire [31:0] i_read_data,   // {R,G,B,8'b0}，同例程 write_data 打包方式

    // ---- VGA 输出（nvboard / 板级视频通路）----
    output reg         vga_hsync,     // 低有效
    output reg         vga_vsync,     // 低有效
    output reg         vga_blank_n,
    output reg  [7:0]  vga_r,
    output reg  [7:0]  vga_g,
    output reg  [7:0]  vga_b
);

    // 640x480@60：行 800（同步96/后沿48/有效640/前沿16），
    //             场 525（同步2/后沿33/有效480/前沿10）
    localparam [9:0] H_SYNC_END = 10'd96;
    localparam [9:0] H_ACT_BEG  = 10'd144;
    localparam [9:0] H_ACT_END  = 10'd784;
    localparam [9:0] H_TOTAL    = 10'd800;
    localparam [9:0] V_SYNC_END = 10'd2;
    localparam [9:0] V_ACT_BEG  = 10'd35;
    localparam [9:0] V_ACT_END  = 10'd515;
    localparam [9:0] V_TOTAL    = 10'd525;

    reg [9:0] x_cnt;    // 1..800
    reg [9:0] y_cnt;    // 1..525

    wire h_active = (x_cnt > H_ACT_BEG) && (x_cnt <= H_ACT_END);
    wire v_active = (y_cnt > V_ACT_BEG) && (y_cnt <= V_ACT_END);

    wire de_raw = h_active && v_active;
    wire hs_raw = (x_cnt > H_SYNC_END);
    wire vs_raw = (y_cnt > V_SYNC_END);

    // 有效像素期每个像素节拍取一个字
    assign o_read_en = de_raw && i_ce;

    // 像素字低字节是 {R,G,B,8'b0} 的填充位（例程 write_data 的打包方式），不参与显示
    wire _unused_pad = &{1'b0, i_read_data[7:0], 1'b0};

    // 流水第一级（配合输出寄存共 2 拍，抵消存储读延迟）
    reg de_d0, hs_d0, vs_d0;
    // 场同步下降沿检测（用于发帧读请求）
    reg vs_raw_d;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            x_cnt       <= 10'd1;
            y_cnt       <= 10'd1;
            de_d0       <= 1'b0;
            hs_d0       <= 1'b1;
            vs_d0       <= 1'b1;
            vs_raw_d    <= 1'b1;
            o_read_req  <= 1'b0;
            vga_hsync   <= 1'b1;
            vga_vsync   <= 1'b1;
            vga_blank_n <= 1'b0;
            vga_r       <= 8'h00;
            vga_g       <= 8'h00;
            vga_b       <= 8'h00;
        end
        else if (i_ce) begin
            // ---- 计数器推进（只在像素节拍上走）----
            if (x_cnt == H_TOTAL) begin
                x_cnt <= 10'd1;
                y_cnt <= (y_cnt == V_TOTAL) ? 10'd1 : (y_cnt + 10'd1);
            end
            else begin
                x_cnt <= x_cnt + 10'd1;
            end

            // ---- 帧读请求：场同步下降沿发起，保持到 ack ----
            vs_raw_d <= vs_raw;
            if (vs_raw_d && !vs_raw) begin
                o_read_req <= 1'b1;
            end
            else if (i_read_req_ack) begin
                o_read_req <= 1'b0;
            end

            // ---- 流水第一级 ----
            de_d0 <= de_raw;
            hs_d0 <= hs_raw;
            vs_d0 <= vs_raw;

            // ---- 输出寄存（第二级）：此刻 i_read_data 正是 de_d0 对应的像素 ----
            vga_hsync   <= hs_d0;
            vga_vsync   <= vs_d0;
            vga_blank_n <= de_d0;
            if (de_d0) begin
                vga_r <= i_read_data[31:24];
                vga_g <= i_read_data[23:16];
                vga_b <= i_read_data[15:8];
            end
            else begin
                vga_r <= 8'h00;
                vga_g <= 8'h00;
                vga_b <= 8'h00;
            end
        end
    end

endmodule
