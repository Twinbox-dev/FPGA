`timescale 1ns/1ps
// ---------------------------------------------------------------------------
// ctrl_core.v — 传输无关的控制核心（2026-09-29）
//
// 分层：传输前端（UART / 将来以太网 …）只负责把各自的报文翻译成
// 「一个已校验的命令字节 + 一拍 valid」，喂给本模块；本模块负责命令语义
// （虚拟按键脉冲、控制参数）与状态回读内容（8 字节），不关心命令从哪来。
//
//   串口前端 ─┐
//             ├─► ctrl_core ──► 虚拟按键脉冲 / vol_gain 参数寄存器
//   网口前端 ─┘        └──► status_pkt（8 字节，各前端自行组帧发送）
//
// 命令表（cmd 字节，前端已完成自己的成帧/校验，如 UART 的 [CMD,~CMD]）：
//   'N'(4E)=下一张   'A'(41)=自动轮播开关   'P'(50)=上一张
//   'S'(53)=回读一包状态（status_pkt）
//   '+'(2B)=音量+1   '-'(2D)=音量-1（8 档，8=原始，0=静音）
//   '>'(3E)=轮播周期+1s  '<'(3C)=轮播周期-1s（1..10s，上电=1s）
//   ']'(5D)=亮度+1     '['(5B)=亮度-1（9 档，4=原始 0 偏移，跨时钟域走格雷码）
// 未知命令静默忽略。
//
// 应答（return）：除 'S'（回 status_pkt）外，每条被接受的命令都在**参数生效
// 后**（延迟两拍）自动回一包 ACK，由 tx_req/tx_pkt 交给前端组帧发送：
//   5A | cmd 回显 | vol_gain | auto_period_s | img_idx | img_wav | bri_level | 00
// 'S' 的应答 = status_pkt（A5 开头）。
//
// 时钟：与命令消费方同域（板上为 sd_card_clk）——虚拟按键脉冲直接注入
// sd_card_bmp 去抖，免 CDC。status 输入里的 clk 域粘滞位在本模块内 2FF 同步。
// ---------------------------------------------------------------------------
module ctrl_core #(
    parameter VK_PULSE_CYC = 10_000_000      // 虚拟按键低脉冲 100ms @100MHz
                                             // （实际脉宽 = CYC-1 拍；须明显大于
                                             // sd_card_bmp 的 50ms 去抖窗）
)(
    input               clk,
    input               rst,
    // 来自传输前端：已校验的命令字节（单拍有效）
    input  [7:0]        cmd,
    input               cmd_val,
    // 虚拟按键（低有效，与物理按键线相与）
    output              vk_next_n,
    output              vk_auto_n,
    output              vk_prev_n,
    // 发包请求（单拍）+ 包内容 8 字节：'S' → status_pkt，其余命令 → ACK
    //（参数生效后延迟两拍发出，前端组帧发送）
    output              tx_req,
    output [63:0]       tx_pkt,
    // 控制参数
    output reg [3:0]    vol_gain,            // 0..8：8=原始音量，0=静音
    output reg [3:0]    auto_period_s,       // 轮播周期（秒，1..10）
    output [3:0]        bri_gray,            // 亮度档位（格雷码，跨时钟域用）
    // 状态回读源（与 top 遥测同源）
    input  [3:0]        state_code,
    input  [7:0]        dbg_fat_state,
    input  [3:0]        flag_a,
    input  [3:0]        flag_b,
    input  [3:0]        dbg_underrun,        // clk 域粘滞位，内部 2FF 同步
    input  [4:0]        img_idx,
    input               img_wav,
    input               auto_on             // 自动轮播开关当前状态（sd_card_bmp 遥测）
);
    // ================= 命令语义 =================
    localparam CMD_NEXT = 8'h4E, CMD_AUTO = 8'h41, CMD_PREV = 8'h50,
               CMD_STAT = 8'h53, CMD_VOLUP = 8'h2B, CMD_VOLDN = 8'h2D,
               CMD_PERUP = 8'h3E, CMD_PERDN = 8'h3C,
               CMD_BRIUP = 8'h5D, CMD_BRIDN = 8'h5B;

    reg cmd_next, cmd_auto, cmd_prev, cmd_stat, cmd_vup, cmd_vdn;
    reg cmd_pup, cmd_pdn, cmd_bup, cmd_bdn;

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            cmd_next <= 0; cmd_auto <= 0; cmd_prev <= 0;
            cmd_stat <= 0; cmd_vup <= 0; cmd_vdn <= 0;
            cmd_pup  <= 0; cmd_pdn  <= 0;
            cmd_bup  <= 0; cmd_bdn  <= 0;
        end else begin
            cmd_next <= 1'b0; cmd_auto <= 1'b0; cmd_prev <= 1'b0;
            cmd_stat <= 1'b0; cmd_vup <= 1'b0; cmd_vdn <= 1'b0;
            cmd_pup  <= 1'b0; cmd_pdn <= 1'b0;
            cmd_bup  <= 1'b0; cmd_bdn <= 1'b0;
            if (cmd_val) begin
                case (cmd)
                    CMD_NEXT: cmd_next <= 1'b1;
                    CMD_AUTO: cmd_auto <= 1'b1;
                    CMD_PREV: cmd_prev <= 1'b1;
                    CMD_STAT: cmd_stat <= 1'b1;
                    CMD_VOLUP: cmd_vup <= 1'b1;
                    CMD_VOLDN: cmd_vdn <= 1'b1;
                    CMD_PERUP: cmd_pup <= 1'b1;
                    CMD_PERDN: cmd_pdn <= 1'b1;
                    CMD_BRIUP: cmd_bup <= 1'b1;
                    CMD_BRIDN: cmd_bdn <= 1'b1;
                    default: ;
                endcase
            end
        end
    end

    // ================= 控制参数（与命令分离，供各功能模块取用）=================
    reg [3:0] bri_level;                   // 亮度 9 档：4=原始（0 偏移）
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            vol_gain      <= 4'd8;         // 音量 8 档：8=原始，0=静音
            auto_period_s <= 4'd1;         // 轮播周期 1..10 秒（上电 1s，与旧行为一致）
            bri_level     <= 4'd4;         // 亮度 9 档：4=原始（0 偏移）
        end else begin
            if (cmd_vup)
                vol_gain <= (vol_gain == 4'd8) ? 4'd8 : vol_gain + 1'b1;
            else if (cmd_vdn)
                vol_gain <= (vol_gain == 4'd0) ? 4'd0 : vol_gain - 1'b1;
            if (cmd_pup)
                auto_period_s <= (auto_period_s >= 4'd10) ? 4'd10 : auto_period_s + 1'b1;
            else if (cmd_pdn)
                auto_period_s <= (auto_period_s <= 4'd1) ? 4'd1 : auto_period_s - 1'b1;
            if (cmd_bup)
                bri_level <= (bri_level >= 4'd8) ? 4'd8 : bri_level + 1'b1;
            else if (cmd_bdn)
                bri_level <= (bri_level <= 4'd0) ? 4'd0 : bri_level - 1'b1;
        end
    end

    // 亮度跨时钟域（sd_card_clk → video_clk）：格雷码每次步进只变 1 位，
    // 多位 2FF 同步后恒为合法旧值或新值（二进制多位直传会出现过渡混合值）
    assign bri_gray = (bri_level >> 1) ^ bri_level;

    // ============ 应答（return）：参数生效后延迟两拍回包 ============
    // 命令脉冲在 v1 拍产生、参数在同一沿之后才更新，故延迟到 v2 拍组包——
    // 此时 vol_gain/auto_period_s/bri_level 均已是**新值**
    reg        v1, v2, d1_stat;
    reg [7:0]  echo1, echo2;
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            v1 <= 1'b0; v2 <= 1'b0; d1_stat <= 1'b0;
            echo1 <= 8'd0; echo2 <= 8'd0;
        end else begin
            v1      <= cmd_val;
            echo1   <= cmd_val ? cmd : echo1;
            d1_stat <= cmd_val && (cmd == CMD_STAT);
            v2      <= v1;
            echo2   <= v1 ? echo1 : echo2;
        end
    end
    wire d2_stat = v2 && (echo2 == CMD_STAT);

    // 'S' 的应答内容：A5 | state | fat | flagA | flagB | underrun | img | wav
    wire [63:0] status_pkt;
    assign tx_req = v2;
    // ⚠ 每个字段都必须是**整字节**。曾把 pkt[6] 写成 {3'b0, bri_level}（7 位），
    //   整条拼接到不了 64 位 → 赋值给 tx_pkt[63:0] 时高位补零，**所有字段错位半个
    //   字节**；只因原来 pkt[7] 恒 0 才没暴露（新加的 auto 标志位一比就露馅，
    //   tb_uart T12 抓住）。判据：拼接总位宽必须正好 64。
    assign tx_pkt = d2_stat ? status_pkt :
                    {{7'b0, auto_on},             // pkt[7] 标志位：bit0=自动轮播开关
                     {4'b0, bri_level},           // pkt[6] 亮度档位
                     {7'b0, img_wav},             // pkt[5] 该图配 WAV
                     {3'b0, img_idx},             // pkt[4] 当前图索引
                     {4'b0, auto_period_s},       // pkt[3] 轮播周期（秒）
                     {4'b0, vol_gain},            // pkt[2] 音量档位
                     echo2,                       // pkt[1] 命令回显
                     8'h5A};                      // pkt[0] 类型 = ACK（A5 反序）

    // ================= 虚拟按键：100ms 低脉冲 =================
    // vk_cnt 必须 ≥ VK_PULSE_CYC-1 位宽：曾用 23 位（上限 8.38M），VK 改 10M
    // 后装载值 9,999,999 被截断成 1,609,599（≈16ms），板上永远过不了 50ms 去抖
    reg [31:0] vk_cnt;
    reg        vk_next, vk_auto, vk_prev;
    assign vk_next_n = ~vk_next;
    assign vk_auto_n = ~vk_auto;
    assign vk_prev_n = ~vk_prev;

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            vk_cnt <= 0; vk_next <= 0; vk_auto <= 0; vk_prev <= 0;
        end else begin
            if (vk_cnt != 0) begin
                vk_cnt <= vk_cnt - 1'b1;
                if (vk_cnt == 1) begin
                    vk_next <= 1'b0;
                    vk_auto <= 1'b0;
                    vk_prev <= 1'b0;
                end
            end else if (cmd_next || cmd_auto || cmd_prev) begin
                vk_cnt  <= VK_PULSE_CYC - 1;
                vk_next <= cmd_next;
                vk_auto <= cmd_auto;
                vk_prev <= cmd_prev;
            end
        end
    end

    // ================= 状态包内容（与传输无关）=================
    // 2FF 同步 clk 域的 underrun 粘滞位（准静态，仅消亚稳）
    reg [3:0] und_s0, und_s1;
    always @(posedge clk or posedge rst) begin
        if (rst) begin und_s0 <= 0; und_s1 <= 0; end
        else     begin und_s0 <= dbg_underrun; und_s1 <= und_s0; end
    end

    // 字节序：pkt[0]=A5 落在 status_pkt[7:0]，pkt[7] 落在 [63:56]
    //   pkt = A5 | state | fat | flagA | flagB | underrun | img_idx | wav
    assign status_pkt = {{7'b0, img_wav},
                         {3'b0, img_idx},
                         {4'b0, und_s1},
                         {3'b0, auto_on, flag_b},   // flagB 字节空出的 bit4 = 自动轮播开关
                         {4'b0, flag_a},
                         dbg_fat_state,
                         {4'b0, state_code},
                         8'hA5};
endmodule

// ---------------------------------------------------------------------------
// cmd_arb — 多传输前端的命令仲裁（2026-10-02 从顶层抽出，为了可测）
//
// 顶层原先这段 10 行胶水不在任何仿真范围内，导致"命令晚一拍"的 bug 只能上板
// 发现（按 N 回来的是上一条 A 的 ACK）。抽成本模块后由 tb_cmd_arb 覆盖。
//
// 职责：把「以太网前端的异步握手（pending 电平 + 稳定命令字节）」和「串口前端的
// 同域单拍 valid」汇成 ctrl_core 要的 (cmd_val, cmd_byte)，并把取走确认
// （eth_ack_tog 翻转）回给 eth_front 清 pending。
//
// ⚠ 命令字节必须**组合取用** eth_cmd——它从 pending 置位到被 ack 清除之间是稳定的
//（eth_front 保证），同步器已提供足够余量；若给数据打一拍，那一拍送出的会是
// **上一条**命令，且本拍命令被丢弃（每次按键的效果推迟到下一次按键）。
// ---------------------------------------------------------------------------
module cmd_arb (
    input  wire        clk,             // 与 ctrl_core 同域（板上 sd_card_clk）
    input  wire        eth_pending,     // 以太网：命令就绪（电平，取走前保持）
    input  wire [7:0]  eth_cmd,         // 以太网：命令字节（pending 期间稳定）
    output reg         eth_ack_tog,     // 取走确认（翻转 → eth_front 清 pending）
    input  wire [7:0]  uart_cmd,        // 串口：命令字节（同域、单拍有效）
    input  wire        uart_cmd_val,
    output wire        cmd_val,         // → ctrl_core
    output wire [7:0]  cmd_byte         // → ctrl_core
);
    reg [2:0] pend_sync;
    always @(posedge clk)
        pend_sync <= {pend_sync[1:0], eth_pending};

    wire eth_take = pend_sync[1] & ~pend_sync[2];      // pending 上升沿（同步后）

    always @(posedge clk)
        if (eth_take) eth_ack_tog <= ~eth_ack_tog;

    assign cmd_val  = eth_take | uart_cmd_val;
    assign cmd_byte = eth_take ? eth_cmd : uart_cmd;   // 组合取用，勿打拍！
endmodule
