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
//   'S'(53)=回读一包状态（stat_req 脉冲）
//   '+'(2B)=音量+1   '-'(2D)=音量-1（8 档，8=原始，0=静音）
//   '>'(3E)=轮播周期+1s  '<'(3C)=轮播周期-1s（1..10s，上电=1s）
// 未知命令静默忽略。
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
    // 状态回读请求（单拍脉冲，供前端触发一次发包）
    output              stat_req,
    // 控制参数
    output reg [3:0]    vol_gain,            // 0..8：8=原始音量，0=静音
    output reg [3:0]    auto_period_s,       // 轮播周期（秒，1..10）
    // 状态回读源（与 top 遥测同源）
    input  [3:0]        state_code,
    input  [7:0]        dbg_fat_state,
    input  [3:0]        flag_a,
    input  [3:0]        flag_b,
    input  [3:0]        dbg_underrun,        // clk 域粘滞位，内部 2FF 同步
    input  [4:0]        img_idx,
    input               img_wav,
    // 状态包内容（8 字节，[7:0]=首字节 A5 … [63:56]=末字节）
    output [63:0]       status_pkt
);
    // ================= 命令语义 =================
    localparam CMD_NEXT = 8'h4E, CMD_AUTO = 8'h41, CMD_PREV = 8'h50,
               CMD_STAT = 8'h53, CMD_VOLUP = 8'h2B, CMD_VOLDN = 8'h2D,
               CMD_PERUP = 8'h3E, CMD_PERDN = 8'h3C;

    reg cmd_next, cmd_auto, cmd_prev, cmd_stat, cmd_vup, cmd_vdn;
    reg cmd_pup, cmd_pdn;

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            cmd_next <= 0; cmd_auto <= 0; cmd_prev <= 0;
            cmd_stat <= 0; cmd_vup <= 0; cmd_vdn <= 0;
            cmd_pup  <= 0; cmd_pdn  <= 0;
        end else begin
            cmd_next <= 1'b0; cmd_auto <= 1'b0; cmd_prev <= 1'b0;
            cmd_stat <= 1'b0; cmd_vup <= 1'b0; cmd_vdn <= 1'b0;
            cmd_pup  <= 1'b0; cmd_pdn <= 1'b0;
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
                    default: ;
                endcase
            end
        end
    end

    assign stat_req = cmd_stat;

    // ================= 控制参数（与命令分离，供各功能模块取用）=================
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            vol_gain      <= 4'd8;         // 音量 8 档：8=原始，0=静音
            auto_period_s <= 4'd1;         // 轮播周期 1..10 秒（上电 1s，与旧行为一致）
        end else begin
            if (cmd_vup)
                vol_gain <= (vol_gain == 4'd8) ? 4'd8 : vol_gain + 1'b1;
            else if (cmd_vdn)
                vol_gain <= (vol_gain == 4'd0) ? 4'd0 : vol_gain - 1'b1;
            if (cmd_pup)
                auto_period_s <= (auto_period_s >= 4'd10) ? 4'd10 : auto_period_s + 1'b1;
            else if (cmd_pdn)
                auto_period_s <= (auto_period_s <= 4'd1) ? 4'd1 : auto_period_s - 1'b1;
        end
    end

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
                         {4'b0, flag_b},
                         {4'b0, flag_a},
                         dbg_fat_state,
                         {4'b0, state_code},
                         8'hA5};
endmodule
