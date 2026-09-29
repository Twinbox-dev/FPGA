`timescale 1ns/1ps
// ---------------------------------------------------------------------------
// uart_link.v — PC ↔ FPGA 交互通道 v1（2026-09-27）
//
// 8N1 UART，RX 命令 + TX 遥测。整个模块跑在 sd_card_clk（100MHz）域：
// 命令消费方（sd_card_bmp 的按键去抖）同域，免 CDC。
//
// 波特率 = CLK_FREQ_HZ/BAUD（默认 1Mbaud = 整 100 拍/位，无小数分频）。
// CH340G 实测支持 2Mbaud，1M 有 2 倍裕量。
//
// 协议（v1）：
//   RX：命令帧 = 2 字节 [CMD, ~CMD]（异或校验，两字节必须相邻接收）。
//       'N'(4E)=下一张   'A'(41)=自动轮播开关   'P'(50)=上一张
//       ——以 100ms 低脉冲注入按键线，复用 sd_card_bmp 现有去抖，零侵入
//       'S'(53)=回读一包状态
//       未知/不成对字节静默丢弃
//   TX：状态包 8 字节 = A5 | state_code | fat_state | flagA | flagB | underrun
//       | img_idx | wav_flag（'S' 请求一包，无心跳）
//       img_idx = 当前图索引（5bit），wav_flag = 该图是否配同名 WAV
//
// flagA={video_pll_lock,sys_pll_lock,Sdr_init_done,display_valid}
// flagB={hdmi_locked,fat_err,disp_buf[1:0]}  underrun={vid_stick,aud_stick,2'b00}
// （underrun 来自 clk 域粘滞寄存器，模块内 2FF 同步；其余均为准静态电平）
// ---------------------------------------------------------------------------
module uart_link #(
    parameter CLK_FREQ_HZ  = 100_000_000,
    parameter BAUD         = 1_000_000,
    parameter VK_PULSE_CYC = 10_000_000      // 虚拟按键低脉冲 100ms @100MHz
                                             // （实际脉宽 = CYC-1 拍；必须明显大于
                                             // 消费方 sd_card_bmp 的 50ms 去抖窗，
                                             // 设成 50ms 时差 1 拍永远不触发）
)(
    input               clk,          // sd_card_clk 域
    input               rst,
    input               rx,
    output              tx,
    // 虚拟按键（低有效，与物理按键线相与）
    output              vk_next_n,
    output              vk_auto_n,
    output              vk_prev_n,
    // 状态回读（与 top 调试面板同源）
    input  [3:0]        state_code,
    input  [7:0]        dbg_fat_state,
    input  [3:0]        flag_a,
    input  [3:0]        flag_b,
    input  [3:0]        dbg_underrun,  // clk 域粘滞位，内部 2FF 同步
    // 遥测：当前图索引 + 该图是否配同名 WAV（状态包 pkt[6]/pkt[7]）
    input  [4:0]        img_idx,
    input               img_wav
);
    localparam BIT_CYC = CLK_FREQ_HZ / BAUD;

    // ================= RX：位中心采样 =================
    reg rx_s0, rx_s1;
    always @(posedge clk or posedge rst) begin
        if (rst) begin rx_s0 <= 1'b1; rx_s1 <= 1'b1; end
        else     begin rx_s0 <= rx;  rx_s1 <= rx_s0; end
    end

    localparam RX_IDLE = 2'd0, RX_START = 2'd1, RX_DATA = 2'd2, RX_STOP = 2'd3;
    reg [1:0]  rx_st;
    reg [15:0] rx_cnt;                    // 位内计数（BIT_CYC ≤ 65536）
    reg [2:0]  rx_bit;
    reg [7:0]  rx_shr;
    reg        rx_val;                    // 单拍：收到一个字节
    reg [7:0]  rx_byte;

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            rx_st <= RX_IDLE; rx_cnt <= 0; rx_bit <= 0;
            rx_shr <= 0; rx_val <= 0; rx_byte <= 0;
        end else begin
            rx_val <= 1'b0;
            case (rx_st)
                RX_IDLE:
                    if (!rx_s1) begin
                        rx_st   <= RX_START;
                        rx_cnt  <= 0;
                    end
                RX_START: begin
                    // 计到半位处校验起始位仍为 0（滤毛刺），随后对齐位中心
                    if (rx_cnt == BIT_CYC/2 - 1) begin
                        if (!rx_s1) begin
                            rx_st  <= RX_DATA;
                            rx_cnt <= 0;
                            rx_bit <= 0;
                        end else
                            rx_st <= RX_IDLE;   // 毛刺
                    end else
                        rx_cnt <= rx_cnt + 1'b1;
                end
                RX_DATA: begin
                    if (rx_cnt == BIT_CYC - 1) begin
                        rx_shr  <= {rx_s1, rx_shr[7:1]};   // LSB first
                        rx_cnt  <= 0;
                        if (rx_bit == 3'd7) begin
                            rx_st  <= RX_STOP;
                            rx_bit <= 0;
                        end else
                            rx_bit <= rx_bit + 1'b1;
                    end else
                        rx_cnt <= rx_cnt + 1'b1;
                end
                RX_STOP: begin
                    if (rx_cnt == BIT_CYC - 1) begin
                        rx_st <= RX_IDLE;
                        if (rx_s1) begin                   // 停止位=1 才有效
                            rx_byte <= rx_shr;
                            rx_val  <= 1'b1;
                        end
                    end else
                        rx_cnt <= rx_cnt + 1'b1;
                end
            endcase
        end
    end

    // ================= 命令解码：[CMD, ~CMD] 相邻两字节 =================
    localparam CMD_NEXT = 8'h4E, CMD_AUTO = 8'h41, CMD_STAT = 8'h53,
               CMD_PREV = 8'h50;
    reg [7:0] prev_byte;
    reg       prev_val;                       // 上一字节待配对

    reg cmd_next, cmd_auto, cmd_stat, cmd_prev;

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            prev_byte <= 0; prev_val <= 0;
            cmd_next <= 0; cmd_auto <= 0; cmd_stat <= 0; cmd_prev <= 0;
        end else begin
            cmd_next <= 1'b0; cmd_auto <= 1'b0; cmd_stat <= 1'b0; cmd_prev <= 1'b0;
            if (rx_val) begin
                if (prev_val && (prev_byte == ~rx_byte)) begin
                    // 成对：执行命令并清配对状态（命令以配对首字节为准）
                    prev_val <= 1'b0;
                    case (prev_byte)
                        CMD_NEXT: cmd_next <= 1'b1;
                        CMD_AUTO: cmd_auto <= 1'b1;
                        CMD_STAT: cmd_stat <= 1'b1;
                        CMD_PREV: cmd_prev <= 1'b1;
                        default: ;
                    endcase
                end else begin
                    prev_byte <= rx_byte;
                    prev_val  <= 1'b1;
                end
            end
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

    // ================= TX：状态包 =================
    // 2FF 同步 clk 域的 underrun 粘滞位（准静态，仅消亚稳）
    reg [3:0] und_s0, und_s1;
    always @(posedge clk or posedge rst) begin
        if (rst) begin und_s0 <= 0; und_s1 <= 0; end
        else     begin und_s0 <= dbg_underrun; und_s1 <= und_s0; end
    end

    // 待发队列：状态包 8 字节（发送中新来的请求丢弃——'S' 连打会丢包，可接受）
    reg [7:0] pkt [0:7];
    reg [3:0] pkt_len;                    // 剩余字节数（含第 8 字节需 4 位）
    reg [3:0] pkt_idx;                    // 已发送字节数

    wire pkt_req = cmd_stat;

    always @(posedge clk or posedge rst) begin
        if (rst) pkt_len <= 0;
        else begin
            if (pkt_req && pkt_len == 0) begin
                pkt[0] <= 8'hA5;
                pkt[1] <= {4'b0, state_code};
                pkt[2] <= dbg_fat_state;
                pkt[3] <= {4'b0, flag_a};
                pkt[4] <= {4'b0, flag_b};
                pkt[5] <= {4'b0, und_s1};
                pkt[6] <= {3'b0, img_idx};    // 当前图索引（5bit）
                pkt[7] <= {7'b0, img_wav};    // 该图是否配同名 WAV
                pkt_len <= 8;
            end else if (tx_done_byte)
                pkt_len <= pkt_len - 1'b1;
        end
    end

    // pkt_idx：tx_load 拍指向当前待发字节，随后前移（8 字节后回卷归零）。
    // 注意判发条件用 pkt_len!=0——pkt_idx 递增、pkt_len 递减，二者相减
    // 恒为 8，用 pkt_idx<pkt_len 只能发出前 5 个字节。
    // 还须屏蔽 done 拍：done_r 拉高时 st 已回 IDLE 而 len 的递减要到下一拍
    // 才生效，该拍 len 仍为旧值会多装一个字节并使 len 下溢
    wire       tx_load = (pkt_len != 0) && tx_idle && !tx_done_byte;
    wire       tx_idle;
    wire       tx_done_byte;

    uart_tx_byte #(.BIT_CYC(BIT_CYC)) u_tx (
        .clk       (clk),
        .rst       (rst),
        .load      (tx_load),
        .data      (pkt[pkt_idx]),
        .tx        (tx),
        .idle      (tx_idle),
        .done_byte (tx_done_byte)
    );

    always @(posedge clk or posedge rst) begin
        if (rst)
            pkt_idx <= 0;
        else if (tx_load)
            pkt_idx <= (pkt_idx == 4'd7) ? 4'd0 : pkt_idx + 1'b1;
    end

endmodule

// 单字节 8N1 发送器（停止位独立状态，保证满 1 位宽——否则连发时下一字节
// 起始位立刻覆盖停止位，收端帧错误）
module uart_tx_byte #(
    parameter BIT_CYC = 100
)(
    input            clk,
    input            rst,
    input            load,
    input      [7:0] data,
    output           tx,
    output           idle,
    output           done_byte          // 单拍：一字节（含停止位）发完
);
    localparam TX_IDLE = 3'd0, TX_START = 3'd1, TX_DATA = 3'd2,
               TX_STOP = 3'd3, TX_STOPBIT = 3'd4;
    reg [2:0]  st;
    reg [15:0] cnt;
    reg [2:0]  bit_i;
    reg [7:0]  shr;
    reg        tx_r, done_r;

    assign tx = tx_r;
    assign idle = (st == TX_IDLE);
    assign done_byte = done_r;

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            st <= TX_IDLE; cnt <= 0; bit_i <= 0;
            shr <= 0; tx_r <= 1'b1; done_r <= 1'b0;
        end else begin
            done_r <= 1'b0;
            case (st)
                TX_IDLE:
                    if (load) begin
                        shr <= data; tx_r <= 1'b0;      // 起始位
                        st <= TX_START; cnt <= 0; bit_i <= 0;
                    end
                TX_START:
                    if (cnt == BIT_CYC - 1) begin
                        tx_r <= shr[0];                 // bit0
                        shr <= {1'b0, shr[7:1]};
                        st <= TX_DATA; cnt <= 0; bit_i <= 1;
                    end else
                        cnt <= cnt + 1'b1;
                TX_DATA:
                    if (cnt == BIT_CYC - 1) begin
                        tx_r <= shr[0];
                        shr <= {1'b0, shr[7:1]};
                        cnt <= 0;
                        if (bit_i == 3'd7)
                            st <= TX_STOP;
                        else
                            bit_i <= bit_i + 1'b1;
                    end else
                        cnt <= cnt + 1'b1;
                TX_STOP:                                // 末数据位 D7 满宽结束
                    if (cnt == BIT_CYC - 1) begin
                        tx_r <= 1'b1;                   // 停止位开始
                        st   <= TX_STOPBIT;
                        cnt  <= 0;
                    end else
                        cnt <= cnt + 1'b1;
                TX_STOPBIT:                             // 停止位满 1 位宽
                    if (cnt == BIT_CYC - 1) begin
                        done_r <= 1'b1;
                        st     <= TX_IDLE;
                    end else
                        cnt <= cnt + 1'b1;
            endcase
        end
    end
endmodule
