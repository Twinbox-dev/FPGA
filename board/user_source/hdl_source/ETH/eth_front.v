`timescale 1ns / 1ps
// ---------------------------------------------------------------------------
// eth_front.v — 以太网控制前端（传输层=官方 udp_ip_protocol_stack，见
//               udp_transmit_test demo / APUG013）。与 uart_link 同级：
//               只把 UDP 载荷翻译成「命令字节 + valid」喂 ctrl_core；
//               ctrl_core 的 tx_req/tx_pkt 应答包由本模块打成 UDP 发回 PC。
//
// 应用层帧格式（APUG013，UDP payload = 8 字节应用头 + 数据）：
//   [header0=0xAABB][header1=0xCCDD][type][length] + 数据
//   PC→板 命令帧：type=0x0001, length=0x0002, 数据=[CMD,~CMD]（与串口同款）
//   板→PC 应答帧：type=0x0002, length=0x0008, 数据=ctrl_core 的 8 字节包
//                （5A|cmd回显|vol|period|img|wav|bri|00 或 A5 状态包）
//
// 时钟：udp_clk（千兆 125M / 百兆 12.5M，由 udp_clk_gen 按 tri_speed 选）。
// 复位：reset 高有效（接 eth 子系统复位）。
//
// 注意：demo 的 udp_loopback 依赖 TD 库宏 ram_fifo（工程里无源码），本模块
// 自带解析/组包逻辑，不依赖 ram_fifo。
// ---------------------------------------------------------------------------
module eth_front(
    input  wire        app_rx_clk,
    input  wire        app_tx_clk,
    input  wire        reset,

    // UDP 栈 RX：payload 字节流（含 8 字节应用头）
    input  wire [7:0]  app_rx_data,
    input  wire        app_rx_data_valid,
    input  wire [15:0] app_rx_data_length,

    // UDP 栈 TX
    input  wire        udp_tx_ready,
    input  wire        app_tx_ack,
    output wire [7:0]  app_tx_data,
    output reg         app_tx_data_request,
    output wire        app_tx_data_valid,
    output reg  [15:0] udp_data_length,

    // 应用出口：命令握手（跨时钟域，udp_clk ↔ sd_card_clk 由顶层完成）——
    // 命中命令置 cmd_pending 并锁存 cmd（保持稳定）；顶层取走后翻转 cmd_ack_t
    // 清除 pending。pending 未清期间新命令被丢弃（人手速度不可能）。
    output reg  [7:0]  cmd,
    output reg         cmd_pending,
    input  wire        cmd_ack_t,
    // 应用入口：ctrl_core 应答包（顶层每应答一次翻转 tx_tog；tx_pkt 在翻转
    // 前后稳定）
    input  wire        tx_tog,
    input  wire [63:0] tx_pkt
);
    localparam HDR0   = 16'hAABB;        // 应用头（APUG013 demo 同款）
    localparam HDR1   = 16'hCCDD;
    localparam TYPE_ACK = 16'h0002;      // 板→PC 应答帧类型
    localparam PKT_BYTES = 16;           // 应答帧数据长度 = 8 头 + 8 包

    // ================= RX：跳过 8 字节头 → [CMD,~CMD] 配对 =================
    reg [15:0] rx_cnt;
    reg [7:0]  prev_byte;
    reg        prev_val;

    always @(posedge app_rx_clk or posedge reset) begin
        if (reset) begin
            rx_cnt <= 16'd0; prev_byte <= 8'd0; prev_val <= 1'b0;
            cmd <= 8'd0; cmd_pending <= 1'b0;
        end else begin
            if (app_rx_data_valid) begin
                rx_cnt <= rx_cnt + 16'd1;
                // 前 8 字节为应用头，其后才是命令数据
                if (rx_cnt >= 16'd8) begin
                    if (prev_val && (prev_byte == ~app_rx_data)) begin
                        prev_val <= 1'b0;
                        if (!cmd_pending) begin   // 上条未取走则丢弃（防阻塞）
                            cmd        <= prev_byte;
                            cmd_pending <= 1'b1;
                        end
                    end else begin
                        prev_byte <= app_rx_data;
                        prev_val  <= 1'b1;
                    end
                end
            end else begin
                rx_cnt   <= 16'd0;       // 包尾：清配对状态，防跨包误配
                prev_val <= 1'b0;
            end
            if (ack_seen)
                cmd_pending <= 1'b0;     // 顶层已取走命令
        end
    end

    // ---- 命令握手：cmd_ack_t toggle 同步（取走确认）----
    reg ack_s0, ack_s1, ack_loc;
    always @(posedge app_rx_clk or posedge reset) begin
        if (reset) begin
            ack_s0 <= 1'b0; ack_s1 <= 1'b0; ack_loc <= 1'b0;
        end else begin
            ack_s0  <= cmd_ack_t;
            ack_s1  <= ack_s0;
            ack_loc <= ack_s1;
        end
    end
    wire ack_seen = (ack_s1 != ack_loc);

    // ---- 应答包入口：tx_tog toggle 同步（新包到达）----
    reg tog_s0, tog_s1, tog_loc;
    always @(posedge app_tx_clk or posedge reset) begin
        if (reset) begin
            tog_s0 <= 1'b0; tog_s1 <= 1'b0; tog_loc <= 1'b0;
        end else begin
            tog_s0  <= tx_tog;
            tog_s1  <= tog_s0;
            tog_loc <= tog_s1;
        end
    end
    wire tx_pulse = (tog_s1 != tog_loc);

    // ================= TX：ctrl_core 应答包 → 带头 UDP帧 =================
    // 时序照抄 demo udp_loopback：request 拉高 → 等 app_tx_ack → 逐拍
    // valid+data（udp_data_length 保持）→ 发完回 WAIT。
    localparam TX_WAIT = 2'd0, TX_RDY = 2'd1, TX_ACK = 2'd2, TX_SEND = 2'd3;
    reg [1:0]  st;
    // 16 字节整帧：字节 0..7 = 应用头，字节 8..15 = tx_pkt（pkt[0] 先发）。
    // ⚠ 曾写成 64 位（只锁 tx_pkt、按 16 字节索引）→ **应用头根本没发出去**，
    //   且 tx_i≥8 读越界位（=0）；PC 侧能看到 ACK 只是走了"没有头"的兜底分支。
    //   头常量按"字节 0 在最低位"写：0xAA BB CC DD 00 02 00 08 → 08_00_02_00_DD_CC_BB_AA
    reg [127:0] tx_buf;
    reg [4:0]  tx_i;                     // 当前输出字节序号 0..15
    reg        valid_r;

    // 应用头常量：字节序 AA BB CC DD 00 02 00 08（**低字节先发**，所以按字节
    // 从低到高拼：byte0=AA … byte7=08）。用 HDR0/HDR1/TYPE_ACK 拼装避免手写常数出错。
    localparam [63:0] TX_HDR = {8'h08, 8'h00,                    // length = 0x0008
                                TYPE_ACK[7:0], TYPE_ACK[15:8],   // type   = 0x0002
                                HDR1[7:0], HDR1[15:8],           // CC DD
                                HDR0[7:0], HDR0[15:8]};          // AA BB

    always @(posedge app_tx_clk or posedge reset) begin
        if (reset) begin
            st <= TX_WAIT; app_tx_data_request <= 1'b0;
            valid_r <= 1'b0; udp_data_length <= 16'd0;
            tx_i <= 5'd0; tx_buf <= 128'd0;
        end else begin
            case (st)
                TX_WAIT:
                    if (tx_pulse) begin
                        // 锁存整帧（toggle 到达时 tx_pkt 已稳定）
                        tx_buf <= {tx_pkt, TX_HDR};
                        tx_i <= 5'd0;
                        if (udp_tx_ready) begin
                            app_tx_data_request <= 1'b1;
                            st <= TX_ACK;
                        end else
                            st <= TX_RDY;
                    end
                TX_RDY:                      // 等协议栈就绪
                    if (udp_tx_ready) begin
                        app_tx_data_request <= 1'b1;
                        st <= TX_ACK;
                    end
                TX_ACK:
                    if (app_tx_ack) begin
                        app_tx_data_request <= 1'b0;
                        udp_data_length     <= PKT_BYTES;
                        valid_r             <= 1'b1;   // 首字节本拍起有效
                        tx_i <= 5'd0;
                        st <= TX_SEND;
                    end else
                        app_tx_data_request <= 1'b1;
                TX_SEND:
                    if (tx_i == PKT_BYTES - 1) begin
                        valid_r <= 1'b0; // 末字节（tx_i=15）已输出
                        tx_i <= 5'd0;
                        st <= TX_WAIT;
                    end else begin
                        tx_i <= tx_i + 1'b1;
                    end
                default: st <= TX_WAIT;
            endcase
        end
    end
    assign app_tx_data       = tx_buf[8*tx_i[3:0] +: 8];
    assign app_tx_data_valid = valid_r;

endmodule
