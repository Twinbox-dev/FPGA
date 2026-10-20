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
//   '.'(2E)=对比度+1   ','(2C)=对比度-1（7 档，2=原始 k=1.0，同样走格雷码）
//   'Q'(51)=音频脉动条开关（默认关）
//   '''(27)=脉动灵敏度+1  ';'(3B)=灵敏度-1（4 档 0..3，上电=1；走格雷码；
//          2026-10-03 用户实测后要求交换：; 减小、' 增大）
// 未知命令静默忽略。
//
// 应答（return）：除 'S'（回 status_pkt）外，每条被接受的命令都在**参数生效
// 后**（延迟两拍）自动回一包 ACK，由 tx_req/tx_pkt 交给前端组帧发送：
//   5A | cmd 回显 | vol_gain | auto_period_s | img_idx | img_wav | bri_level | flags
// flags：bit0 = 自动轮播开关，bit[3:1] = 对比度档位，bit4 = 脉动条开关，
//        bit[6:5] = 脉动灵敏度档位，bit7 保留
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
    input               set_valid,
    input  [7:0]        set_op,
    input  [7:0]        set_value,
    input               touch_next,
    input               touch_prev,
    input               subtitle_consume,
    input               subtitle_ack_pulse,
    input               subtitle_ack_ok,
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
    output [3:0]        brightness_value,
    output [3:0]        contrast_value,
    output [1:0]        sensitivity_value,
    output reg [3:0]    auto_period_s,       // 轮播周期（秒，1..10）
    output reg [1:0]    transition_mode,     // 0=直接切，1=交叉溶解，2=柔边替换
    output reg [1:0]    osd_mode,            // 0=off, 1=3s after adjustment, 2=always
    output [3:0]        vol_gray,
    output [3:0]        bri_gray,            // 亮度档位（格雷码，跨时钟域用）
    output [3:0]        ct_gray,             // 对比度档位（格雷码，跨时钟域用）
    output              bar_en,              // 音频脉动条开关
    output [1:0]        bar_sens_gray,       // 脉动灵敏度 0..3（格雷码，跨时钟域用）
    // 播放列表转储（'L' 调试命令）：sd_card_bmp 的转储 FSM 逐包送来
    input  [63:0]       pl_pkt,
    input               pl_pkt_val,
    output reg          pl_dump_start,
    output reg          rdump_start,       // 'D' 显存读回启动脉冲（sd_card_bmp）
    // 状态回读源（与 top 遥测同源）
    input  [3:0]        state_code,
    input  [7:0]        dbg_fat_state,
    input  [3:0]        flag_a,
    input  [3:0]        flag_b,
    input  [3:0]        dbg_underrun,        // clk 域粘滞位，内部 2FF 同步
    input  [4:0]        img_idx,
    input               img_wav,
    input  [7:0]        ld_diag,            // 装载诊断：{0,result[1:0],ld[2:0],busy,img_wav}
    input               auto_on             // 自动轮播开关当前状态（sd_card_bmp 遥测）
);
    // ================= 命令语义 =================
    localparam CMD_NEXT = 8'h4E, CMD_AUTO = 8'h41, CMD_PREV = 8'h50,
               CMD_STAT = 8'h53, CMD_VOLUP = 8'h2B, CMD_VOLDN = 8'h2D,
               CMD_PERUP = 8'h3E, CMD_PERDN = 8'h3C,
               CMD_BRIUP = 8'h5D, CMD_BRIDN = 8'h5B,
               CMD_CTUP  = 8'h2E, CMD_CTDN  = 8'h2C,   // '.'/',' 对比度（无需 Shift）
               CMD_PLDMP = 8'h4C,                      // 'L' 播放列表转储（调试）
               CMD_RDUMP = 8'h44,                      // 'D' 显存读回转储（撕裂三分法取证）
               CMD_BARQ  = 8'h51,                      // 'Q' 脉动条开关
               CMD_SENUP = 8'h27, CMD_SENDN = 8'h3B;   // ''';' 灵敏度（' 加 ; 减）

    reg cmd_next, cmd_auto, cmd_prev, cmd_stat, cmd_vup, cmd_vdn, cmd_pdm;
    reg cmd_pup, cmd_pdn, cmd_bup, cmd_bdn, cmd_cup, cmd_cdn;
    reg cmd_barq, cmd_sup, cmd_sdn, cmd_rdm;
    wire normal_cmd_val = cmd_val && !subtitle_consume;

    // Explicit mode commands are idempotent across UART and Ethernet retries.
    always @(posedge clk or posedge rst) begin
        if (rst) transition_mode <= 2'd0;
        else if (set_valid && set_op == 8'd4 && set_value <= 8'd2)
            transition_mode <= set_value[1:0];
        else if (normal_cmd_val) begin
            case (cmd)
                8'h30: transition_mode <= 2'd0; // '0' direct cut
                8'h31: transition_mode <= 2'd1; // '1' crossfade
                8'h32: transition_mode <= 2'd2; // '2' soft wipe
                default: ;
            endcase
        end
    end

    always @(posedge clk or posedge rst) begin
        if (rst) osd_mode <= 2'd1;
        else if (set_valid && set_op == 8'd5 && set_value <= 8'd2)
            osd_mode <= set_value[1:0];
        else if (normal_cmd_val) begin
            case (cmd)
                8'h33: osd_mode <= 2'd0; // '3' off
                8'h34: osd_mode <= 2'd1; // '4' show for 3s after adjustment
                8'h35: osd_mode <= 2'd2; // '5' always visible
                default: ;
            endcase
        end
    end

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            cmd_next <= 0; cmd_auto <= 0; cmd_prev <= 0;
            cmd_stat <= 0; cmd_vup <= 0; cmd_vdn <= 0;
            cmd_pup  <= 0; cmd_pdn  <= 0;
            cmd_bup  <= 0; cmd_bdn  <= 0;
            cmd_cup  <= 0; cmd_cdn  <= 0; cmd_pdm <= 0;
            cmd_barq <= 0; cmd_sup <= 0; cmd_sdn <= 0; cmd_rdm <= 0;
        end else begin
            cmd_next <= 1'b0; cmd_auto <= 1'b0; cmd_prev <= 1'b0;
            cmd_stat <= 1'b0; cmd_vup <= 1'b0; cmd_vdn <= 1'b0;
            cmd_pup  <= 1'b0; cmd_pdn <= 1'b0;
            cmd_bup  <= 1'b0; cmd_bdn <= 1'b0;
            cmd_cup  <= 1'b0; cmd_cdn <= 1'b0; cmd_pdm <= 1'b0;
            cmd_barq <= 1'b0; cmd_sup <= 1'b0; cmd_sdn <= 1'b0; cmd_rdm <= 1'b0;
            if (normal_cmd_val) begin
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
                    CMD_CTUP:  cmd_cup <= 1'b1;
                    CMD_CTDN:  cmd_cdn <= 1'b1;
                    CMD_PLDMP: cmd_pdm <= 1'b1;
                    CMD_RDUMP: cmd_rdm <= 1'b1;
                    CMD_BARQ:  cmd_barq <= 1'b1;
                    CMD_SENUP: cmd_sup  <= 1'b1;
                    CMD_SENDN: cmd_sdn  <= 1'b1;
                    default: ;
                endcase
            end
        end
    end

    // ================= 控制参数（与命令分离，供各功能模块取用）=================
    reg [3:0] bri_level;                   // 亮度 9 档：4=原始（0 偏移）
    reg [3:0] ct_level;                    // 对比度 7 档：0..6，2=原始(k=1.0)
                                           // 增益表（围绕中灰 128）：0:0.5 1:0.75
                                           // 2:1.0 3:1.25 4:1.5 5:1.75 6:2.0
    reg        bar_en_r;                   // 音频脉动条开关（默认关）
    reg [1:0]  bar_sens;                   // 灵敏度 0..3：包络右移量 20-3*sens
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            vol_gain      <= 4'd8;         // 音量 8 档：8=原始，0=静音
            auto_period_s <= 4'd1;         // 轮播周期 1..10 秒（上电 1s，与旧行为一致）
            bri_level     <= 4'd4;         // 亮度 9 档：4=原始（0 偏移）
            ct_level      <= 4'd2;         // 对比度 7 档：2=原始
            bar_en_r      <= 1'b0;         // 脉动条默认关
            bar_sens      <= 2'd1;         // 灵敏度上电 = 1（shift 17）
        end else if (set_valid) begin
            case (set_op)
                8'd1: vol_gain <= (set_value > 8'd8) ? 4'd8 : set_value[3:0];
                8'd2: bri_level <= (set_value > 8'd8) ? 4'd8 : set_value[3:0];
                8'd3: ct_level <= (set_value > 8'd6) ? 4'd6 : set_value[3:0];
                8'd6: bar_en_r <= set_value[0];
                8'd7: bar_sens <= (set_value > 8'd3) ? 2'd3 : set_value[1:0];
                default: ;
            endcase
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
            if (cmd_cup)
                ct_level <= (ct_level >= 4'd6) ? 4'd6 : ct_level + 1'b1;
            else if (cmd_cdn)
                ct_level <= (ct_level <= 4'd0) ? 4'd0 : ct_level - 1'b1;
            if (cmd_barq)
                bar_en_r <= ~bar_en_r;
            if (cmd_sup)
                bar_sens <= (bar_sens >= 2'd3) ? 2'd3 : bar_sens + 1'b1;
            else if (cmd_sdn)
                bar_sens <= (bar_sens <= 2'd0) ? 2'd0 : bar_sens - 1'b1;
        end
    end

    assign bar_en = bar_en_r;
    assign brightness_value = bri_level;
    assign contrast_value = ct_level;
    assign sensitivity_value = bar_sens;

    // 亮度/对比度跨时钟域（sd_card_clk → video_clk）：格雷码每次步进只变 1 位，
    // 多位 2FF 同步后恒为合法旧值或新值（二进制多位直传会出现过渡混合值）
    assign bri_gray = (bri_level >> 1) ^ bri_level;
    assign ct_gray  = (ct_level  >> 1) ^ ct_level;
    assign vol_gray = (vol_gain >> 1) ^ vol_gain;
    assign bar_sens_gray = (bar_sens >> 1) ^ bar_sens;   // 2 位格雷码 → 包络域

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
            v1      <= normal_cmd_val;
            echo1   <= normal_cmd_val ? cmd : echo1;
            d1_stat <= normal_cmd_val && (cmd == CMD_STAT);
            v2      <= v1;
            echo2   <= v1 ? echo1 : echo2;
        end
    end
    wire d2_stat = v2 && (echo2 == CMD_STAT);
    wire d2_pdm  = v2 && (echo2 == CMD_PLDMP);
    wire d2_rdm  = v2 && (echo2 == CMD_RDUMP);

    // 'S' 的应答内容：A5 | state | fat | flagA | flagB | underrun | img | wav
    wire [63:0] status_pkt;
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            pl_dump_start <= 1'b0;
            rdump_start   <= 1'b0;
        end
        else begin
            pl_dump_start <= d2_pdm;
            rdump_start   <= d2_rdm;
        end
    end
    assign tx_req = v2 | pl_pkt_val | subtitle_ack_pulse;
    // ⚠ 每个字段都必须是**整字节**。曾把 pkt[6] 写成 {3'b0, bri_level}（7 位），
    //   整条拼接到不了 64 位 → 赋值给 tx_pkt[63:0] 时高位补零，**所有字段错位半个
    //   字节**；只因原来 pkt[7] 恒 0 才没暴露（新加的 auto 标志位一比就露馅，
    //   tb_uart T12 抓住）。判据：拼接总位宽必须正好 64。
    assign tx_pkt = pl_pkt_val ? pl_pkt :
                    d2_stat ? status_pkt :
                    {{subtitle_ack_pulse && subtitle_ack_ok,
                      bar_sens, bar_en_r, ct_level[2:0], auto_on},
                                                  // pkt[7] 标志位：bit0=自动轮播开关
                                                  //   bit[3:1]=对比度档位 bit4=脉动条
                                                  //   bit[6:5]=脉动灵敏度 bit7=T上传成功
                     {osd_mode, transition_mode, bri_level},
                     ld_diag,                     // pkt[5] {0,result,ld,busy,该图配WAV}
                     {3'b0, img_idx},             // pkt[4] 当前图索引
                     {4'b0, auto_period_s},       // pkt[3] 轮播周期（秒）
                     {4'b0, vol_gain},            // pkt[2] 音量档位
                     subtitle_ack_pulse ? 8'h54 : echo2,
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
            end else if (cmd_next || cmd_auto || cmd_prev ||
                         touch_next || touch_prev) begin
                vk_cnt  <= VK_PULSE_CYC - 1;
                vk_next <= cmd_next || touch_next;
                vk_auto <= cmd_auto;
                vk_prev <= cmd_prev || touch_prev;
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
                         {2'b0, osd_mode, und_s1},
                         {1'b0, transition_mode, auto_on, flag_b},
                         {ct_level, flag_a},        // flagA 字节空出的高 4 位 = 对比度档位
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
