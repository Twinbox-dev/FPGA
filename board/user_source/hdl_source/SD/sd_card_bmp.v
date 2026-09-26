// =============================================================================
// sd_card_bmp.v — SD 卡图像控制（FAT32 版）
// -----------------------------------------------------------------------------
// 本模块把例程的「原始扇区线性扫描」方案换成正宗 FAT32 只读解析：
//
//   TF卡 ── sd_card_top(SPI+init，板上已验证) ──► sd_adapter ──► fat32_ro ──► bmp_dec ──► frame_write
//                                                  ▲                                     │
//                                                   └────── 扇区读协议翻译 ───────────────┘
//
// 模块名/端口与例程版本完全一致，top_tf_hdmi_audio.v 无需改动。
// fat32_ro / bmp_dec 为仿真侧（anlogic 仓库）验证通过的原样移植；板级差异只有两点：
//   1. 复位极性：本模块 rst 高有效 → 子模块接 ~rst；
//   2. fat32_ro 的扇区读协议（o_req/o_lba/i_ready/i_dval/i_done/i_err）经 sd_adapter
//      适配到 sd_card_top 的 sd_sec_read 协议（电平请求 + 数据有效 + end 一拍）。
//   板上 sd_card_top 无错误上抛（坏扇区会在 CMD17 重试），故 i_err 恒 0，
//   恢复靠本模块 1s 装载超时——与例程行为一致。
//
// 装载顺序（关键，与 frame_fifo_write 语义配套）：
//   空闲 → 先开写通道（write_req 保持到 ack，存储侧借此清写 FIFO 并锁存长度）
//        → 再向 fat32_ro 发文件请求。顺序反了会把上一张图的残留像素算进这一张。
//
// 完成判定：bmp_dec 的 o_img_ok（整图字节处理完、头校验通过）且 write_finish 已同步到
//   （整帧真正落盘）→ 切换显示缓冲。坏图（o_img_err）立即放弃不提交，旧图继续显示，
//   光标推进跳过，轮播不会卡死在坏图上。
//
// 轮播控制逻辑与仿真侧 top.v 一致：挂载后自动加载第一个图片项（跳过 WAV 项），
// key_next 切下一张（到尾回绕、跳过音频项），装载中按键排队到文件完成。
// =============================================================================

module sd_card_bmp #(
    parameter integer CLK_FREQ_HZ       = 100_000_000,
    parameter [31:0]  SCAN_START_SECTOR = 32'd0,      // 保留参数（兼容 top 例化）
    parameter [31:0]  SCAN_MAX_SECTOR   = 32'd131071,
    parameter [2:0]   SCAN_TARGET_COUNT = 3'd4
)(
    input                       clk,
    input                       rst,
    input                       key_next,
    input                       key_auto,
    input  [15:0]               bmp_width,     // 保留（bmp_dec 内部硬编码 640x480）
    input  [15:0]               bmp_height,
    output reg                  display_valid,
    output      [3:0]           state_code,

    input                       write_finish_toggle,
    output reg  [1:0]           write_buf_idx,
    output reg  [1:0]           disp_buf_idx,

    output                      write_req,
    input                       write_req_ack,
    output                      write_en,
    output [31:0]               write_data,
    output                      SD_nCS,
    output                      SD_DCLK,
    output                      SD_MOSI,
    input                       SD_MISO
);

    // ==================== 声明区（先声明后使用，TD 解析要求） ====================

    // ---- 键去抖 ----
    wire key_next_press;
    wire key_auto_press;

    // ---- 扇区读通道（fat32_ro 主机 / sd_card_top 从机，经适配器） ----
    wire        sd_init_done;
    wire [31:0] sec_lba;
    wire        sec_req, sec_ready, sec_dval, sec_done, sec_err;
    wire [7:0]  sec_data;

    // ---- 文件字节流 / 状态 ----
    wire [7:0]  file_byte;
    wire        file_bval, file_done;
    wire        fat_mounted, fat_idle, fat_err, cur_is_wav;
    wire [5:0]  file_cnt, bmp_cnt, wav_cnt, type_map;
    wire [7:0]  fat_dbg, bmp_dbg;
    wire        img_ok, img_err;
    wire        pix_val;
    wire [23:0] pix;

    // ---- 适配器 / SD 从机 ----
    wire        sd_sec_read;
    wire [31:0] sd_sec_read_addr;
    wire [7:0]  sd_sec_read_data;
    wire        sd_sec_read_data_valid;
    wire        sd_sec_read_end;

    // ---- 写帧（frame_read_write 写口） ----
    reg         write_req_r;

    // ---- 装载序列 FSM ----
    localparam [1:0] LD_IDLE = 2'd0, LD_MEM_ACK = 2'd1, LD_FILE = 2'd2;
    reg [1:0] ld_state;
    reg       file_req;
    reg [4:0] file_idx;

    // ---- 外控 ----
    reg [2:0]  wrfin_tgl_sync;
    wire       write_finish_pulse;
    wire       auto_tick;
    reg        load_start_pulse;      // 装载发起一拍（同时复位 bmp_dec）
    reg [5:0]  load_idx;              // 当前装载的播放列表索引
    reg [5:0]  img_idx;               // 轮播光标（当前显示/最近尝试的图片索引）
    reg [5:0]  first_idx_r;           // 首图候选（坏图时推进，避免上电卡死在坏图）
    reg        first_idx_captured;
    reg [1:0]  pending_buf_idx;       // 当前装载目标缓冲
    reg        load_busy;
    reg        write_done_seen;       // 整帧已落盘（write_finish 同步后）
    reg        first_image_committed;
    reg        auto_play_en;
    reg [31:0] auto_cnt;
    reg [31:0] load_timeout_cnt;
    reg        next_req_pending;

    // ---- 组合 ----
    wire [5:0] next_idx;

    // ==================== 函数 ====================
    // 轮播只在图片项之间走：跳过类型位为 WAV 的项（与仿真 top.v 一致）
    // 函数内含阻塞赋值、在时序块中被调用——结果用于非阻塞赋值，安全。
    function [5:0] next_bmp_idx;
        input [5:0] cur;
        input [5:0] cnt;
        input [5:0] tmap;
        reg   [5:0] cand;
        integer     k;
        begin
            next_bmp_idx = cur;
            cand = cur;
            for (k = 0; k < 6; k = k + 1) begin
                cand = (cand + 6'd1 >= cnt) ? 6'd0 : (cand + 6'd1);
                if (!((cand < 6'd6) && tmap[cand[2:0]]) &&
                    (next_bmp_idx == cur)) begin
                    next_bmp_idx = cand;
                end
            end
        end
    endfunction

    function [5:0] first_bmp_idx;
        input [5:0] cnt;
        input [5:0] tmap;
        integer     k;
        reg         found;
        begin
            first_bmp_idx = 6'd0;
            found = 1'b0;
            for (k = 0; k < 6; k = k + 1) begin
                if (!found && (k < cnt) && !tmap[k[2:0]]) begin
                    first_bmp_idx = k[5:0];
                    found = 1'b1;
                end
            end
        end
    endfunction

    function [1:0] next_buf_lut;
        input [1:0] cur_disp_buf;
        input       valid_now;
        begin
            if (!valid_now)
                next_buf_lut = 2'd0;
            else if (cur_disp_buf == 2'd0)
                next_buf_lut = 2'd1;
            else
                next_buf_lut = 2'd0;
        end
    endfunction

    // ==================== 组合赋值 ====================
    assign write_req  = write_req_r;
    assign write_en   = pix_val;
    assign write_data = {pix, 8'b0};      // {R,G,B,0}
    assign write_finish_pulse = wrfin_tgl_sync[2] ^ wrfin_tgl_sync[1];
    assign auto_tick  = (auto_cnt == (CLK_FREQ_HZ - 1));
    assign next_idx   = next_bmp_idx(img_idx, file_cnt, type_map);

    // ---- 状态码（数码管）：1 空闲 2 挂载/扫描 3 FIFO 握手 4 写帧 ----
    assign state_code = !sd_init_done               ? 4'd0
                      : !fat_mounted                ? 4'd2
                      : (ld_state == LD_MEM_ACK)    ? 4'd3
                      : load_busy                   ? 4'd4
                      :                               4'd1;

    // ---- 吸收未用信号，避免 lint 噪声 ----
    wire _unused_absorb = &{1'b0,
                            bmp_width[15:0], bmp_height[15:0],
                            wav_cnt[5:0], cur_is_wav, file_done,
                            fat_dbg[7:0], bmp_dbg[7:0],
                            SCAN_START_SECTOR[31:0], SCAN_MAX_SECTOR[31:0],
                            SCAN_TARGET_COUNT[2:0],
                            1'b0};

    // ==================== 例化 ====================
    key_press_debounce #(.CLK_FREQ_HZ(CLK_FREQ_HZ), .DEBOUNCE_MS(50)) u_key_next (
        .clk        (clk),
        .rst        (rst),
        .button_in  (key_next),
        .press_pulse(key_next_press)
    );

    key_press_debounce #(.CLK_FREQ_HZ(CLK_FREQ_HZ), .DEBOUNCE_MS(50)) u_key_auto (
        .clk        (clk),
        .rst        (rst),
        .button_in  (key_auto),
        .press_pulse(key_auto_press)
    );

    // 适配器：fat32_ro 请求 → sd_card_top sd_sec_read
    sd_adapter u_adapter (
        .clk                    (clk),
        .rst                    (rst),
        .sd_init_done           (sd_init_done),
        .o_lba                  (sec_lba),
        .o_req                  (sec_req),
        .i_ready                (sec_ready),
        .i_data                 (sec_data),
        .i_dval                 (sec_dval),
        .i_done                 (sec_done),
        .i_err                  (sec_err),
        .sd_sec_read            (sd_sec_read),
        .sd_sec_read_addr       (sd_sec_read_addr),
        .sd_sec_read_data       (sd_sec_read_data),
        .sd_sec_read_data_valid (sd_sec_read_data_valid),
        .sd_sec_read_end        (sd_sec_read_end)
    );

    // FAT32 只读引擎（仿真侧原样移植）
    fat32_ro u_fat (
        .clk         (clk),
        .rst_n       (~rst),
        .o_lba       (sec_lba),
        .o_req       (sec_req),
        .i_ready     (sec_ready),
        .i_data      (sec_data),
        .i_dval      (sec_dval),
        .i_done      (sec_done),
        .i_err       (sec_err),
        .o_byte      (file_byte),
        .o_bval      (file_bval),
        .o_file_done (file_done),
        .i_file_idx  (file_idx),
        .i_file_req  (file_req),
        .o_mounted   (fat_mounted),
        .o_file_cnt  (file_cnt),
        .o_bmp_cnt   (bmp_cnt),
        .o_wav_cnt   (wav_cnt),
        .o_type_map  (type_map),
        .o_cur_is_wav(cur_is_wav),
        .o_err       (fat_err),
        .o_file_idle (fat_idle),
        .o_dbg_state (fat_dbg)
    );

    // BMP 解码（行翻转归属存储侧 WRITE_V_FLIP=1）
    bmp_dec u_bmp (
        .clk        (clk),
        .rst_n      (~rst),
        .i_byte     (file_byte),
        .i_bval     (file_bval),
        .i_restart  (load_start_pulse),
        .o_pix_val  (pix_val),
        .o_pix      (pix),
        .o_img_ok   (img_ok),
        .o_img_err  (img_err),
        .o_dbg_state(bmp_dbg)
    );

    // SD SPI 层（板上已验证，原样保留）
    sd_card_top sd_card_top_m0 (
        .clk                    (clk),
        .rst                    (rst),
        .SD_nCS                 (SD_nCS),
        .SD_DCLK                (SD_DCLK),
        .SD_MOSI                (SD_MOSI),
        .SD_MISO                (SD_MISO),
        .sd_init_done           (sd_init_done),
        .sd_sec_read            (sd_sec_read),
        .sd_sec_read_addr       (sd_sec_read_addr),
        .sd_sec_read_data       (sd_sec_read_data),
        .sd_sec_read_data_valid (sd_sec_read_data_valid),
        .sd_sec_read_end        (sd_sec_read_end),
        .sd_sec_write           (1'b0),
        .sd_sec_write_addr      (32'd0),
        .sd_sec_write_data      (8'd0),
        .sd_sec_write_data_req  (),
        .sd_sec_write_end       ()
    );

    // ==================== 装载序列：空闲 → 开写通道（等 ack）→ 发文件请求 ====================
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            ld_state    <= LD_IDLE;
            write_req_r <= 1'b0;
            file_req    <= 1'b0;
            file_idx    <= 5'd0;
        end
        else begin
            file_req <= 1'b0;
            case (ld_state)
                LD_IDLE: begin
                    if (load_start_pulse) begin
                        write_req_r <= 1'b1;
                        ld_state    <= LD_MEM_ACK;
                    end
                end
                LD_MEM_ACK: begin
                    if (write_req_ack) begin
                        write_req_r <= 1'b0;
                        ld_state    <= LD_FILE;
                    end
                end
                LD_FILE: begin
                    file_req <= 1'b1;
                    file_idx <= load_idx[4:0];
                    ld_state <= LD_IDLE;
                end
                default: ld_state <= LD_IDLE;
            endcase
        end
    end

    // ==================== 外控（沿用例程结构，改接 FAT32 信号） ====================
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            wrfin_tgl_sync        <= 3'b000;
            load_start_pulse      <= 1'b0;
            load_busy             <= 1'b0;
            load_timeout_cnt      <= 32'd0;
            write_done_seen       <= 1'b0;
            first_image_committed <= 1'b0;
            auto_play_en          <= 1'b0;
            auto_cnt              <= 32'd0;
            img_idx               <= 6'd0;
            first_idx_r           <= 6'd0;
            first_idx_captured    <= 1'b0;
            load_idx              <= 6'd0;
            pending_buf_idx       <= 2'd0;
            write_buf_idx         <= 2'd0;
            disp_buf_idx          <= 2'd0;
            next_req_pending      <= 1'b0;
            display_valid         <= 1'b0;
        end
        else begin
            wrfin_tgl_sync  <= {wrfin_tgl_sync[1:0], write_finish_toggle};
            load_start_pulse<= 1'b0;

            // ---- SD 未就绪：保持复位态 ----
            if (!sd_init_done) begin
                load_busy             <= 1'b0;
                load_timeout_cnt      <= 32'd0;
                write_done_seen       <= 1'b0;
                first_image_committed <= 1'b0;
                auto_play_en          <= 1'b0;
                auto_cnt              <= 32'd0;
                img_idx               <= 6'd0;
                first_idx_r           <= 6'd0;
                first_idx_captured    <= 1'b0;
                load_idx              <= 6'd0;
                pending_buf_idx       <= 2'd0;
                write_buf_idx         <= 2'd0;
                disp_buf_idx          <= 2'd0;
                next_req_pending      <= 1'b0;
                display_valid         <= 1'b0;
            end
            else if (fat_err) begin
                // FAT 挂载失败/索引越界：清装载，保持黑屏
                load_busy        <= 1'b0;
                load_timeout_cnt <= 32'd0;
                write_done_seen  <= 1'b0;
            end
            else begin
                // ---- 挂载完成：捕获首图候选（坏图推进）----
                if (fat_mounted && !first_idx_captured) begin
                    first_idx_r      <= first_bmp_idx(file_cnt, type_map);
                    first_idx_captured <= 1'b1;
                end

                // ---- 装载完成 / 放弃 / 超时 ----
                // 装载发起的那一拍跳过（load_start_pulse=1），
                // 等 bmp_dec 已被 i_restart 复位、img_ok/img_err 清零后再判。
                if (load_busy && !load_start_pulse) begin
                    if (write_finish_pulse)
                        write_done_seen <= 1'b1;

                    if (img_err) begin
                        // 坏图：立即放弃不提交（旧图继续显示），光标推进跳过
                        load_busy        <= 1'b0;
                        load_timeout_cnt <= 32'd0;
                        write_done_seen  <= 1'b0;
                        if (!first_image_committed)
                            first_idx_r <= next_bmp_idx(first_idx_r, file_cnt, type_map);
                        else
                            img_idx     <= load_idx;
                    end
                    else if (img_ok && write_done_seen) begin
                        // 提交：源完成 + 整帧落盘，切换显示缓冲
                        load_busy             <= 1'b0;
                        load_timeout_cnt      <= 32'd0;
                        write_done_seen       <= 1'b0;
                        disp_buf_idx          <= pending_buf_idx;
                        img_idx               <= load_idx;
                        display_valid         <= 1'b1;
                        first_image_committed <= 1'b1;
                    end
                    else if (load_timeout_cnt > 32'd100_000_000) begin
                        // 超时（坏卡/坏文件卡住）：强制释放，恢复按键
                        load_busy        <= 1'b0;
                        load_timeout_cnt <= 32'd0;
                        write_done_seen  <= 1'b0;
                    end
                    else begin
                        load_timeout_cnt <= load_timeout_cnt + 32'd1;
                    end
                end
                else begin
                    load_timeout_cnt <= 32'd0;
                end

                // ---- 按键请求（装载中只记一次，连按不累积）----
                if (key_next_press && fat_mounted && (bmp_cnt != 6'd0))
                    next_req_pending <= 1'b1;

                // ---- 自动轮播开/关 ----
                if (key_auto_press && fat_mounted && (bmp_cnt > 6'd1)) begin
                    auto_play_en <= ~auto_play_en;
                    auto_cnt     <= 32'd0;
                end

                // ---- 自动轮播 1s 计时（仅空闲且已首图提交）----
                if (fat_mounted && auto_play_en && display_valid && !load_busy &&
                    first_image_committed && (bmp_cnt > 6'd1)) begin
                    if (auto_tick) auto_cnt <= 32'd0;
                    else           auto_cnt <= auto_cnt + 32'd1;
                end
                else begin
                    auto_cnt <= 32'd0;
                end

                // ---- 发起装载：首图 / 手动 / 自动 ----
                if (fat_mounted && fat_idle && !load_busy && (bmp_cnt != 6'd0)) begin
                    if (!first_image_committed) begin
                        // 首图：写 buffer0（首图候选可能已被坏图推进）
                        load_idx         <= first_idx_r;
                        pending_buf_idx  <= 2'd0;
                        write_buf_idx    <= 2'd0;
                        load_busy        <= 1'b1;
                        load_start_pulse <= 1'b1;
                        write_done_seen  <= 1'b0;
                        next_req_pending <= 1'b0;
                        auto_cnt         <= 32'd0;
                    end
                    else if (next_req_pending) begin
                        // 手动下一张：写非当前显示缓冲
                        load_idx         <= next_idx;
                        pending_buf_idx  <= next_buf_lut(disp_buf_idx, display_valid);
                        write_buf_idx    <= next_buf_lut(disp_buf_idx, display_valid);
                        load_busy        <= 1'b1;
                        load_start_pulse <= 1'b1;
                        write_done_seen  <= 1'b0;
                        next_req_pending <= 1'b0;
                        auto_cnt         <= 32'd0;
                    end
                    else if (auto_play_en && auto_tick && (bmp_cnt > 6'd1)) begin
                        load_idx         <= next_idx;
                        pending_buf_idx  <= next_buf_lut(disp_buf_idx, display_valid);
                        write_buf_idx    <= next_buf_lut(disp_buf_idx, display_valid);
                        load_busy        <= 1'b1;
                        load_start_pulse <= 1'b1;
                        write_done_seen  <= 1'b0;
                        next_req_pending <= 1'b0;
                        auto_cnt         <= 32'd0;
                    end
                end
            end
        end
    end

endmodule


// =============================================================================
// key_press_debounce — 按键去抖（例程原样保留）
// =============================================================================
module key_press_debounce #(
    parameter integer CLK_FREQ_HZ = 100_000_000,
    parameter integer DEBOUNCE_MS = 20
)(
    input  wire clk,
    input  wire rst,
    input  wire button_in,    // 默认：松开=1，按下=0
    output reg  press_pulse
);

    localparam integer DEBOUNCE_CYCLES = (CLK_FREQ_HZ / 1000) * DEBOUNCE_MS;

    reg button_sync0;
    reg button_sync1;
    reg button_stable;
    reg [31:0] cnt;

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            button_sync0  <= 1'b1;
            button_sync1  <= 1'b1;
            button_stable <= 1'b1;
            cnt           <= 32'd0;
            press_pulse   <= 1'b0;
        end else begin
            button_sync0 <= button_in;
            button_sync1 <= button_sync0;
            press_pulse  <= 1'b0;

            if (button_sync1 == button_stable) begin
                cnt <= 32'd0;
            end else begin
                if (cnt >= DEBOUNCE_CYCLES - 1) begin
                    if (button_stable && !button_sync1)
                        press_pulse <= 1'b1;
                    button_stable <= button_sync1;
                    cnt           <= 32'd0;
                end else begin
                    cnt <= cnt + 32'd1;
                end
            end
        end
    end

endmodule
