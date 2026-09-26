// vsrc/sd_spi.v — SD 卡 SPI 模式主机（只读，扇区级接口）
//
// 上游：fat32_ro（给扇区号，收字节流）
// 下游：SPI 四线引脚 —— 仿真接 csrc/sd_card_model，板级接 TF 卡座
// 板级：原样搬（只跟 SD 协议打交道，仿真与上板是同一件事）
// 全局视图见 docs/architecture.md
//
// 功能：
//   上电初始化：CS 高 80 时钟(≥74) → CMD0 → CMD8 → CMD55/ACMD41 轮询 → 就绪
//   扇区读：CMD17 单块读，512B 以字节流从 o_data/o_dval 吐出，o_done 结束
//
// 时序：SPI 模式 0（CPOL=0/CPHA=0），MSB first
// 时钟：clk = 100MHz fabric；SPI 时钟由 ce 分频产生：
//   初始化 100M/(2*128) ≈ 390kHz（规格要求 ≤400kHz）
//   就绪后 100M/(2*2)   = 25MHz（SD SPI 规格上限；真卡不稳改 DIV_FAST=3）
//
// 寻址：ACMD41 带 HCS 位 → SDHC/SDXC 块寻址，CMD17 参数即 LBA
//   （仅支持 ≥2GB 的 SDHC/SDXC 卡；SDSC 字节寻址不支持）
//
// 错误处理（均有用例覆盖，见 csrc/main.cpp 的 S4..S9）：
//   R1 等待 64 字节超时 / 数据令牌 2048 字节超时，各自重试至多 3 次
//   CMD17 重试耗尽或参数错 → o_err 脉冲一拍，回 READY（上层可弃图）
//   初始化命令重试耗尽     → o_err 脉冲一拍 + S_ERR 卡死（复位才能重来）
//
// 契约（docs/design.md §3）：i_req 在 o_ready=1 的拍被采样并锁存 i_lba；
//   数据 512 拍 o_dval；o_done/o_err 各一拍。
module sd_spi (
    input  wire        clk,
    input  wire        rst_n,

    // ---- 上层扇区读接口（fat32_ro / 测试激励）----
    input  wire [31:0] i_lba,
    input  wire        i_req,
    output reg         o_ready,
    output reg  [7:0]  o_data,
    output reg         o_dval,      // o_data 有效一拍
    output reg         o_done,      // 512B 完成，一拍
    output reg         o_err,       // 扇区读失败 / 初始化失败，一拍

    // ---- SPI 引脚 ----
    output reg         spi_cs_n,
    output reg         spi_sclk,
    output reg         spi_mosi,
    input  wire        spi_miso,

    output wire [7:0]  o_dbg_state  // 状态码（数码管调试用）
);

    // ---------------- 参数 ----------------
    localparam [7:0]  DIV_SLOW       = 8'd128;   // ~390kHz 初始化
    localparam [7:0]  DIV_FAST       = 8'd2;     // 25MHz
    localparam [11:0] R1_WAIT_TO     = 12'd64;   // R1 响应超时（字节次数）
    localparam [11:0] TOKEN_WAIT_TO  = 12'd2048; // 数据令牌超时
    localparam [10:0] ACMD41_MAX_POLL = 11'd512; // ACMD41 轮询上限
    localparam [1:0]  RETRY_MAX      = 2'd3;

    // ---------------- 状态 ----------------
    localparam [7:0]
        S_RST     = 8'd0,
        S_POWERUP = 8'd1,   // CS=1，10 字节 80 时钟
        S_IGAP    = 8'd2,   // init 命令间 CS=1 一字节，去向 gap_next
        S_CMD0    = 8'd3,
        S_CMD8    = 8'd4,
        S_CMD55   = 8'd5,
        S_ACMD41  = 8'd6,
        S_SWITCH  = 8'd7,   // CS=1 一字节后进 READY（入口已切快速时钟）
        S_READY   = 8'd8,
        S_CMD17   = 8'd9,
        S_TOKEN   = 8'd10,  // 等 0xFE
        S_DATA    = 8'd11,  // 收 512 字节
        S_CRC2    = 8'd12,  // 收 2 字节 CRC
        S_END     = 8'd13,  // CS=1 一字节 → o_done
        S_RETRY   = 8'd14,  // CS=1 一字节 → 重发 CMD17
        S_FAIL    = 8'd15,  // CS=1 一字节 → o_err
        S_ERR     = 8'd16;  // 初始化失败，卡死（复位才能重来）

    reg [7:0] state;
    assign o_dbg_state = state;

    // ---------------- ce 分频（SPI 半周期使能）----------------
    reg  [7:0] div_cnt;
    reg        fast_mode;              // 由 FSM 在初始化完成时置位
    wire [7:0] div_now = fast_mode ? DIV_FAST : DIV_SLOW;
    reg        ce;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            div_cnt <= 8'd0;
            ce      <= 1'b0;
        end
        else if (div_cnt >= div_now - 8'd1) begin
            div_cnt <= 8'd0;
            ce      <= 1'b1;
        end
        else begin
            div_cnt <= div_cnt + 8'd1;
            ce      <= 1'b0;
        end
    end

    // ---------------- SPI 字节引擎 ----------------
    // eng_start 一拍：装载 tx_byte，产生 16 个半周期时钟；
    //   第 8 个上升沿（hp=14）时 eng_rx 有效
    //   第 8 个下降沿（hp=15）时 eng_done 一拍、sclk 回 0
    // 上升沿采 miso，下降沿驱下一位 mosi —— 模式 0
    reg        eng_start;
    reg  [7:0] tx_byte;
    reg  [6:0] tx_sh, rx_sh;      // 7 位移位：第 8 位装载时直通，避免死位
    reg  [7:0] eng_rx;
    reg  [4:0] hp;
    reg        eng_busy, eng_done;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            eng_busy <= 1'b0;
            eng_done <= 1'b0;
            tx_sh    <= 7'h00;
            rx_sh    <= 7'h00;
            eng_rx   <= 8'h00;
            hp       <= 5'd0;
            spi_sclk <= 1'b0;
            spi_mosi <= 1'b1;
        end
        else begin
            eng_done <= 1'b0;
            if (eng_start) begin
                tx_sh    <= tx_byte[6:0];
                spi_mosi <= tx_byte[7];    // 上升沿采样前先摆好 MSB
                rx_sh    <= 7'h00;
                hp       <= 5'd0;
                eng_busy <= 1'b1;
                spi_sclk <= 1'b0;
            end
            else if (eng_busy && ce) begin
                hp       <= hp + 5'd1;
                spi_sclk <= ~spi_sclk;
                if (!spi_sclk) begin
                    // 上升沿：采样
                    rx_sh <= {rx_sh[5:0], spi_miso};
                    if (hp == 5'd14) begin
                        eng_rx <= {rx_sh, spi_miso};    // 第 8 个上升沿：字节齐
                    end
                end
                else begin
                    // 下降沿：驱下一位
                    tx_sh    <= {tx_sh[5:0], 1'b0};
                    spi_mosi <= tx_sh[6];
                    if (hp == 5'd15) begin
                        eng_busy <= 1'b0;               // 第 8 个下降沿：完成
                        eng_done <= 1'b1;
                    end
                end
            end
        end
    end

    // ---------------- 发送字节选择 ----------------
    // bi：当前交换的第几字节；0..5 = 命令字节，>=6 = 接收相（发 0xFF）
    //     （饱和在 6，长接收不会回绕；字节数用 rxc 数）
    reg  [2:0]  bi;
    reg  [47:0] cmd_reg;

    wire is_cmd_state = (state == S_CMD0) || (state == S_CMD8) ||
                        (state == S_CMD55) || (state == S_ACMD41) ||
                        (state == S_CMD17);

    reg [7:0] tx_sel;
    always @(*) begin
        tx_sel = 8'hFF;                  // 间隙/上电/接收相默认 0xFF
        if (is_cmd_state) begin
            case (bi)
                3'd0:    tx_sel = cmd_reg[47:40];
                3'd1:    tx_sel = cmd_reg[39:32];
                3'd2:    tx_sel = cmd_reg[31:24];
                3'd3:    tx_sel = cmd_reg[23:16];
                3'd4:    tx_sel = cmd_reg[15:8];
                3'd5:    tx_sel = cmd_reg[7:0];
                default: tx_sel = 8'hFF;
            endcase
        end
    end

    // ---------------- 主 FSM ----------------
    reg  [11:0] wait_cnt;    // R1/令牌等待的字节数
    reg  [11:0] rxc;         // 接收相字节数（回显/数据/CRC/上电计数）
    reg  [1:0]  retry;
    reg  [10:0] poll_cnt;
    reg  [31:0] lba_r;
    reg  [23:0] echo_reg;    // CMD8 回显收集（前 3 字节，第 4 字节用 eng_rx 比）
    reg  [7:0]  gap_next;    // S_IGAP 的去向

    wire state_clocking = (state != S_RST) && (state != S_READY) && (state != S_ERR);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state    <= S_RST;
            bi       <= 3'd0;
            cmd_reg  <= 48'h0;
            wait_cnt <= 12'd0;
            rxc      <= 12'd0;
            retry    <= 2'd0;
            poll_cnt <= 11'd0;
            lba_r    <= 32'd0;
            echo_reg <= 24'd0;
            gap_next <= S_CMD0;
            fast_mode <= 1'b0;
            o_ready  <= 1'b0;
            o_data   <= 8'h00;
            o_dval   <= 1'b0;
            o_done   <= 1'b0;
            o_err    <= 1'b0;
            spi_cs_n <= 1'b1;
            eng_start <= 1'b0;
            tx_byte   <= 8'hFF;
        end
        else begin
            // 默认：脉冲信号清零
            o_dval    <= 1'b0;
            o_done    <= 1'b0;
            o_err     <= 1'b0;
            eng_start <= 1'b0;

            // ---- 字节喂给引擎：状态需要时钟且引擎空闲 ----
            if (state_clocking && !eng_busy && !eng_start && !eng_done) begin
                eng_start <= 1'b1;
                tx_byte   <= tx_sel;
            end

            // ---- 复位释放后进入上电时钟 ----
            if (state == S_RST) begin
                state <= S_POWERUP;
                bi    <= 3'd0;
                rxc   <= 12'd0;
            end

            // ---- 就绪：接受扇区读请求 ----
            // （READY 不跑字节，必须放在 eng_done 之外）
            if (state == S_READY) begin
                o_ready <= 1'b1;
                if (i_req && o_ready) begin
                    o_ready  <= 1'b0;
                    lba_r    <= i_lba;
                    retry    <= 2'd0;
                    poll_cnt <= 11'd0;
                    cmd_reg  <= {8'h51, i_lba, 8'h01};
                    spi_cs_n <= 1'b0;
                    bi       <= 3'd0;
                    rxc      <= 12'd0;
                    wait_cnt <= 12'd0;
                    state    <= S_CMD17;
                end
            end

            // ---- 字节完成的处理（bi = 刚完成字节的序号）----
            if (eng_done) begin
                if (bi != 3'd6) begin
                    bi <= bi + 3'd1;
                end

                case (state)

                    // ===== 上电：10 字节 80 时钟（CS 高）=====
                    S_POWERUP: begin
                        rxc <= rxc + 12'd1;
                        if (rxc == 12'd9) begin
                            gap_next <= S_CMD0;
                            state    <= S_IGAP;
                            bi       <= 3'd0;
                            rxc      <= 12'd0;
                        end
                    end

                    // ===== 命令间间隙：1 字节后去 gap_next =====
                    S_IGAP: begin
                        bi       <= 3'd0;
                        rxc      <= 12'd0;
                        wait_cnt <= 12'd0;
                        state    <= gap_next;
                        case (gap_next)
                            S_CMD0: begin
                                cmd_reg  <= {8'h40, 32'h0000_0000, 8'h95};
                                spi_cs_n <= 1'b0;
                            end
                            S_CMD8: begin
                                cmd_reg  <= {8'h48, 32'h0000_01AA, 8'h87};
                                spi_cs_n <= 1'b0;
                            end
                            S_CMD55: begin
                                cmd_reg  <= {8'h77, 32'h0000_0000, 8'h01};
                                spi_cs_n <= 1'b0;
                            end
                            S_ACMD41: begin
                                cmd_reg  <= {8'h69, 32'h4000_0000, 8'h01};
                                spi_cs_n <= 1'b0;
                            end
                            S_SWITCH: begin
                                fast_mode <= 1'b1;   // 切 25MHz
                            end
                            default: ;
                        endcase
                    end

                    // ===== CMD0：期待 R1 = 0x01（idle）=====
                    S_CMD0: if (bi >= 3'd6) begin
                        if (eng_rx == 8'hFF) begin
                            wait_cnt <= wait_cnt + 12'd1;
                            if (wait_cnt >= R1_WAIT_TO) begin
                                if (retry < RETRY_MAX) begin
                                    retry    <= retry + 2'd1;
                                    gap_next <= S_CMD0;
                                    state    <= S_IGAP;
                                    bi       <= 3'd0;
                                    rxc      <= 12'd0;
                                    wait_cnt <= 12'd0;
                                    spi_cs_n <= 1'b1;
                                end
                                else begin
                                    state    <= S_ERR;
                                    o_err    <= 1'b1;
                                    spi_cs_n <= 1'b1;
                                end
                            end
                        end
                        else if (eng_rx == 8'h01) begin
                            retry    <= 2'd0;
                            gap_next <= S_CMD8;
                            state    <= S_IGAP;
                            bi       <= 3'd0;
                            rxc      <= 12'd0;
                            wait_cnt <= 12'd0;
                            spi_cs_n <= 1'b1;
                        end
                        else if (retry < RETRY_MAX) begin
                            retry    <= retry + 2'd1;
                            gap_next <= S_CMD0;
                            state    <= S_IGAP;
                            bi       <= 3'd0;
                            rxc      <= 12'd0;
                            wait_cnt <= 12'd0;
                            spi_cs_n <= 1'b1;
                        end
                        else begin
                            state    <= S_ERR;
                            o_err    <= 1'b1;
                            spi_cs_n <= 1'b1;
                        end
                    end

                    // ===== CMD8：R1 = 0x01 + 回显 00 00 01 AA =====
                    S_CMD8: if (bi >= 3'd6) begin
                        if (rxc == 12'd0) begin
                            // R1
                            if (eng_rx == 8'hFF) begin
                                wait_cnt <= wait_cnt + 12'd1;
                                if (wait_cnt >= R1_WAIT_TO) begin
                                    if (retry < RETRY_MAX) begin
                                        retry    <= retry + 2'd1;
                                        gap_next <= S_CMD8;
                                        state    <= S_IGAP;
                                        bi       <= 3'd0;
                                        rxc      <= 12'd0;
                                        wait_cnt <= 12'd0;
                                        spi_cs_n <= 1'b1;
                                    end
                                    else begin
                                        state    <= S_ERR;
                                        o_err    <= 1'b1;
                                        spi_cs_n <= 1'b1;
                                    end
                                end
                            end
                            else if (eng_rx == 8'h01) begin
                                rxc      <= 12'd1;
                                wait_cnt <= 12'd0;
                            end
                            else begin
                                state    <= S_ERR;   // 0x05：v1 旧卡，不支持
                                o_err    <= 1'b1;
                                spi_cs_n <= 1'b1;
                            end
                        end
                        else if (rxc >= 12'd1 && rxc <= 12'd4) begin
                            // 回显 4 字节
                            echo_reg <= {echo_reg[15:0], eng_rx};
                            rxc      <= rxc + 12'd1;
                            if (rxc == 12'd4) begin
                                if (echo_reg == 24'h00_0001 && eng_rx == 8'hAA) begin
                                    retry    <= 2'd0;
                                    gap_next <= S_CMD55;
                                    state    <= S_IGAP;
                                    bi       <= 3'd0;
                                    rxc      <= 12'd0;
                                    wait_cnt <= 12'd0;
                                    spi_cs_n <= 1'b1;
                                end
                                else begin
                                    state    <= S_ERR;
                                    o_err    <= 1'b1;
                                    spi_cs_n <= 1'b1;
                                end
                            end
                        end
                    end

                    // ===== CMD55：R1 无错误位即可 =====
                    S_CMD55: if (bi >= 3'd6) begin
                        if (eng_rx == 8'hFF) begin
                            wait_cnt <= wait_cnt + 12'd1;
                            if (wait_cnt >= R1_WAIT_TO) begin
                                if (retry < RETRY_MAX) begin
                                    retry    <= retry + 2'd1;
                                    gap_next <= S_CMD55;
                                    state    <= S_IGAP;
                                    bi       <= 3'd0;
                                    rxc      <= 12'd0;
                                    wait_cnt <= 12'd0;
                                    spi_cs_n <= 1'b1;
                                end
                                else begin
                                    state    <= S_ERR;
                                    o_err    <= 1'b1;
                                    spi_cs_n <= 1'b1;
                                end
                            end
                        end
                        else if ((eng_rx & 8'h7C) == 8'h00) begin
                            retry    <= 2'd0;
                            gap_next <= S_ACMD41;
                            state    <= S_IGAP;
                            bi       <= 3'd0;
                            rxc      <= 12'd0;
                            wait_cnt <= 12'd0;
                            spi_cs_n <= 1'b1;
                        end
                        else begin
                            state    <= S_ERR;
                            o_err    <= 1'b1;
                            spi_cs_n <= 1'b1;
                        end
                    end

                    // ===== ACMD41：0x00 就绪 / 0x01 busy 轮询 =====
                    S_ACMD41: if (bi >= 3'd6) begin
                        if (eng_rx == 8'hFF) begin
                            wait_cnt <= wait_cnt + 12'd1;
                            if (wait_cnt >= R1_WAIT_TO) begin
                                if (retry < RETRY_MAX) begin
                                    retry    <= retry + 2'd1;
                                    gap_next <= S_ACMD41;
                                    state    <= S_IGAP;
                                    bi       <= 3'd0;
                                    rxc      <= 12'd0;
                                    wait_cnt <= 12'd0;
                                    spi_cs_n <= 1'b1;
                                end
                                else begin
                                    state    <= S_ERR;
                                    o_err    <= 1'b1;
                                    spi_cs_n <= 1'b1;
                                end
                            end
                        end
                        else if (eng_rx == 8'h00) begin
                            gap_next <= S_SWITCH;
                            state    <= S_IGAP;
                            bi       <= 3'd0;
                            rxc      <= 12'd0;
                            wait_cnt <= 12'd0;
                            spi_cs_n <= 1'b1;
                        end
                        else if (eng_rx == 8'h01) begin
                            poll_cnt <= poll_cnt + 11'd1;
                            if (poll_cnt >= ACMD41_MAX_POLL) begin
                                state    <= S_ERR;
                                o_err    <= 1'b1;
                                spi_cs_n <= 1'b1;
                            end
                            else begin
                                gap_next <= S_CMD55;
                                state    <= S_IGAP;
                                bi       <= 3'd0;
                                rxc      <= 12'd0;
                                wait_cnt <= 12'd0;
                                spi_cs_n <= 1'b1;
                            end
                        end
                        else begin
                            state    <= S_ERR;
                            o_err    <= 1'b1;
                            spi_cs_n <= 1'b1;
                        end
                    end

                    // ===== CMD17：R1 = 0x00 → 等令牌 =====
                    S_CMD17: if (bi >= 3'd6) begin
                        if (eng_rx == 8'hFF) begin
                            wait_cnt <= wait_cnt + 12'd1;
                            if (wait_cnt >= R1_WAIT_TO) begin
                                if (retry < RETRY_MAX) begin
                                    retry    <= retry + 2'd1;
                                    state    <= S_RETRY;
                                    bi       <= 3'd0;
                                    rxc      <= 12'd0;
                                    wait_cnt <= 12'd0;
                                    spi_cs_n <= 1'b1;
                                end
                                else begin
                                    state    <= S_FAIL;
                                    bi       <= 3'd0;
                                    rxc      <= 12'd0;
                                    wait_cnt <= 12'd0;
                                    spi_cs_n <= 1'b1;
                                end
                            end
                        end
                        else if (eng_rx == 8'h00) begin
                            state    <= S_TOKEN;
                            rxc      <= 12'd0;
                            wait_cnt <= 12'd0;
                        end
                        else if (eng_rx[6]) begin
                            // 参数错（越界）：不重试
                            state    <= S_FAIL;
                            bi       <= 3'd0;
                            rxc      <= 12'd0;
                            wait_cnt <= 12'd0;
                            spi_cs_n <= 1'b1;
                        end
                        else if (retry < RETRY_MAX) begin
                            retry    <= retry + 2'd1;
                            state    <= S_RETRY;
                            bi       <= 3'd0;
                            rxc      <= 12'd0;
                            wait_cnt <= 12'd0;
                            spi_cs_n <= 1'b1;
                        end
                        else begin
                            state    <= S_FAIL;
                            bi       <= 3'd0;
                            rxc      <= 12'd0;
                            wait_cnt <= 12'd0;
                            spi_cs_n <= 1'b1;
                        end
                    end

                    // ===== 等数据令牌 0xFE =====
                    S_TOKEN: begin
                        if (eng_rx == 8'hFF) begin
                            wait_cnt <= wait_cnt + 12'd1;
                            if (wait_cnt >= TOKEN_WAIT_TO) begin
                                if (retry < RETRY_MAX) begin
                                    retry    <= retry + 2'd1;
                                    state    <= S_RETRY;
                                    bi       <= 3'd0;
                                    rxc      <= 12'd0;
                                    wait_cnt <= 12'd0;
                                    spi_cs_n <= 1'b1;
                                end
                                else begin
                                    state    <= S_FAIL;
                                    bi       <= 3'd0;
                                    rxc      <= 12'd0;
                                    wait_cnt <= 12'd0;
                                    spi_cs_n <= 1'b1;
                                end
                            end
                        end
                        else if (eng_rx == 8'hFE) begin
                            state    <= S_DATA;
                            rxc      <= 12'd0;
                            wait_cnt <= 12'd0;
                        end
                        else if (retry < RETRY_MAX) begin
                            // 数据错误令牌
                            retry    <= retry + 2'd1;
                            state    <= S_RETRY;
                            bi       <= 3'd0;
                            rxc      <= 12'd0;
                            wait_cnt <= 12'd0;
                            spi_cs_n <= 1'b1;
                        end
                        else begin
                            state    <= S_FAIL;
                            bi       <= 3'd0;
                            rxc      <= 12'd0;
                            wait_cnt <= 12'd0;
                            spi_cs_n <= 1'b1;
                        end
                    end

                    // ===== 数据：512 字节 =====
                    S_DATA: begin
                        o_data <= eng_rx;
                        o_dval <= 1'b1;
                        rxc    <= rxc + 12'd1;
                        if (rxc == 12'd511) begin
                            state <= S_CRC2;
                            rxc   <= 12'd0;
                        end
                    end

                    // ===== 2 字节 CRC（不校验）=====
                    S_CRC2: begin
                        rxc <= rxc + 12'd1;
                        if (rxc == 12'd1) begin
                            state    <= S_END;
                            bi       <= 3'd0;
                            spi_cs_n <= 1'b1;
                        end
                    end

                    // ===== 各一字节间隙的出口 =====
                    S_RETRY: begin
                        cmd_reg  <= {8'h51, lba_r, 8'h01};   // 重发 CMD17
                        spi_cs_n <= 1'b0;
                        bi       <= 3'd0;
                        rxc      <= 12'd0;
                        wait_cnt <= 12'd0;
                        state    <= S_CMD17;
                    end

                    S_END: begin
                        o_done <= 1'b1;
                        state  <= S_READY;
                        bi     <= 3'd0;
                    end

                    S_FAIL: begin
                        o_err  <= 1'b1;
                        state  <= S_READY;
                        bi     <= 3'd0;
                    end

                    S_SWITCH: begin
                        state <= S_READY;
                        bi    <= 3'd0;
                    end

                    default: ;
                endcase
            end
        end
    end

endmodule
