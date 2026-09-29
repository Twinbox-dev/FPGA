`timescale 1ns/1ps
// ---------------------------------------------------------------------------
// uart_link.v — UART 传输前端（2026-09-29 拆分后）
//
// 只做「传输」：8N1 收发 + [CMD,~CMD] 成对校验 → 把已校验的命令字节交给
// ctrl_core（命令语义在那边，与传输无关）；状态包内容也由 ctrl_core 提供，
// 本模块只负责按 8 字节流发送。
//
//   本模块（帧）─ cmd/cmd_val ─► ctrl_core ─ stat_req/status_pkt ─► 本模块（发）
//
// 8N1：波特率 = CLK_FREQ_HZ/BAUD（默认 1Mbaud = 整 100 拍/位，无小数分频）。
// CH340G 实测支持 2Mbaud，1M 有 2 倍裕量。
//
// 协议（v1）：
//   RX：命令帧 = 2 字节 [CMD, ~CMD]（异或校验，两字节必须相邻接收），
//       成对后把首字节作为命令交给 ctrl_core；未知/不成对字节静默丢弃。
//   TX：状态包 8 字节（内容见 ctrl_core.status_pkt）——ctrl_core 的
//       stat_req 脉冲触发一包。无心跳。
//
// 命令表见 ctrl_core.v（N/A/P/S、音量 +/-）。
// ---------------------------------------------------------------------------
module uart_link #(
    parameter CLK_FREQ_HZ  = 100_000_000,
    parameter BAUD         = 1_000_000
)(
    input               clk,          // sd_card_clk 域（与 ctrl_core 同域）
    input               rst,
    input               rx,
    output              tx,
    // 命令出口：已校验命令字节（单拍）
    output reg [7:0]    cmd,
    output reg          cmd_val,
    // 状态包入口：stat_req 脉冲触发一次发送，内容取自 status_pkt
    input               stat_req,
    input  [63:0]       status_pkt
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

    // ============ 成帧：[CMD, ~CMD] 相邻两字节 → 命令出口 ============
    reg [7:0] prev_byte;
    reg       prev_val;                       // 上一字节待配对

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            prev_byte <= 8'd0; prev_val <= 1'b0;
            cmd <= 8'd0; cmd_val <= 1'b0;
        end else begin
            cmd_val <= 1'b0;
            if (rx_val) begin
                if (prev_val && (prev_byte == ~rx_byte)) begin
                    // 成对：命令以配对首字节为准
                    prev_val <= 1'b0;
                    cmd      <= prev_byte;
                    cmd_val  <= 1'b1;
                end else begin
                    prev_byte <= rx_byte;
                    prev_val  <= 1'b1;
                end
            end
        end
    end

    // ================= TX：状态包（8 字节，内容由 ctrl_core 提供）=================
    // 待发队列：发送中新来的请求丢弃（连按 S 会丢包，可接受）
    reg [7:0] pkt [0:7];
    reg [3:0] pkt_len;                    // 剩余字节数（含第 8 字节需 4 位）
    reg [3:0] pkt_idx;                    // 已发送字节数

    always @(posedge clk or posedge rst) begin
        if (rst) pkt_len <= 4'd0;
        else begin
            if (stat_req && pkt_len == 4'd0) begin
                pkt[0] <= status_pkt[7:0];
                pkt[1] <= status_pkt[15:8];
                pkt[2] <= status_pkt[23:16];
                pkt[3] <= status_pkt[31:24];
                pkt[4] <= status_pkt[39:32];
                pkt[5] <= status_pkt[47:40];
                pkt[6] <= status_pkt[55:48];
                pkt[7] <= status_pkt[63:56];
                pkt_len <= 4'd8;
            end else if (tx_done_byte)
                pkt_len <= pkt_len - 1'b1;
        end
    end

    // pkt_idx：tx_load 拍指向当前待发字节，随后前移（8 字节后回卷归零）。
    // 注意判发条件用 pkt_len!=0——pkt_idx 递增、pkt_len 递减，二者相减
    // 恒为 8，用 pkt_idx<pkt_len 只能发出前 5 个字节。
    // 还须屏蔽 done 拍：done_r 拉高时 st 已回 IDLE 而 len 的递减要到下一拍
    // 才生效，该拍 len 仍为旧值会多装一个字节并使 len 下溢
    wire       tx_load = (pkt_len != 4'd0) && tx_idle && !tx_done_byte;
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
            pkt_idx <= 4'd0;
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
