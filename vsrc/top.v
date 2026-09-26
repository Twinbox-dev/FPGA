// vsrc/top.v — 系统顶层（仿真用；板级顶层在 TD 工程仓库另写）
//
// 全局视图见 docs/architecture.md，规格决策见 docs/design.md。
//
// 当前集成度（3a 音画同步）：从卡实时流式音频 + 双就绪原子提交
//   卡 ← sd_spi ← sd_arbiter ┬─ fat32_ro(图) → bmp_dec   → mem_sim(乒乓) → vga_ctrl → VGA
//                             └─ fat32_ro(音) → wav_reader → audio_path(乒乓FIFO) → 48kHz 音频输出
//
//   两个 fat32_ro 各自维护播放列表（同名配对靠 8 字节主名）；
//   扇区读由 sd_arbiter 仲裁，音频优先（低水位才请求，不会饿死图像）。
//
// 轮播控制（本文件实现，板级整段可搬）：
//   - 挂载后自动加载第一个图片项；btn_next 切下一张（到尾回绕、跳过音频项）
//   - 切图时按主名找配对 WAV（IMG001.BMP ↔ IMG001.WAV），有则同步从卡流式播放
//   - 双就绪原子提交：图片整帧落盘 + 配对音频 FIFO 就位 → 场同步沿同时切换
//     （装载期间旧图旧音照常播放，切换瞬间无黑屏无静音）
//   - 坏图（img_err）不提交、光标推进；配对 WAV 非法（fmt_err）静音不阻塞
//
// 装载顺序（与 frame_fifo_write 语义配套）：
//   空闲 → 配对搜索 → 先开写通道（write_req 保持到 ack，清写 FIFO 并锁存长度）
//        → 再同时向图/音两个 fat32_ro 发文件请求。
//
// 时钟：仿真顶层单时钟 clk = 板级 100MHz mem_clk；像素域 1/4 时钟使能（25MHz）。
// 48kHz 音频节拍 = clk ÷2083（实际 48.0077kHz，与 design.md §2 一致）。
module top (
    input  wire        clk,
    input  wire        rst_n,

    // ---- SPI 引脚（接 SD 卡座 / 仿真卡模型）----
    output wire        spi_cs_n,
    output wire        spi_sclk,
    output wire        spi_mosi,
    input  wire        spi_miso,

    // ---- 板上人机接口 ----
    input  wire        btn_next,    // 下一张（轮播；板级接 ui_ctrl 去抖后）

    // ---- TB 点播旁路（仿真用：直接请求任意播放列表项作图片）----
    input  wire [4:0]  i_tb_file_idx,
    input  wire        i_tb_file_req,

    // ---- VGA 输出（nvboard / 板级视频通路）----
    output wire        vga_hsync,
    output wire        vga_vsync,
    output wire        vga_blank_n,
    output wire [7:0]  vga_r,
    output wire [7:0]  vga_g,
    output wire [7:0]  vga_b,

    // ---- 状态指示 / TB 观察 ----
    output wire [7:0]  seg,        // 状态码
    output wire [3:0]  led,        // LED0=sd就绪 LED1=已挂载 LED2=图ok LED3=图err
    output wire        o_mounted,
    output wire [5:0]  o_file_cnt,
    output wire [5:0]  o_bmp_cnt,
    output wire [5:0]  o_wav_cnt,
    output wire        o_img_ok,
    output wire        o_img_err,
    output wire        o_file_done,   // 图片文件读完（轮播扩展用）
    output wire        o_sd_err,
    // 存储层观测（mem_sim；板级对应 frame_read_write）
    output wire        o_frame_ready,   // 整图已全部落盘（write_finish 锁存）
    output wire        o_mem_wr_ovf,    // 写 FIFO 溢出 —— 板级会静默丢像素
    output wire        o_mem_rd_und,    // 读 FIFO 下溢 —— 板级会出横向拖影
    output wire        o_mem_len_err,   // 传输长度非突发整数倍 —— 板级会死锁
    output wire        o_pix_ce,        // 像素节拍（TB/nvboard 按此采样）
    // 音频观测（3a：48kHz 节拍输出）
    output wire signed [15:0] o_audio_left,
    output wire signed [15:0] o_audio_right,
    output wire        o_audio_valid,
    output wire        o_aud_underrun,  // 播放 FIFO 下溢（应恒 0）
    output wire [11:0] o_aud_prim_fill, // 装载中音频 FIFO 填充（就绪判断）
    output wire        o_aud_pair_valid,// 当前图片有配对 WAV
    output wire [4:0]  o_aud_idx,       // 配对 WAV 播放列表索引
    output wire [1:0]  o_disp_idx,      // 当前显示缓冲（乒乓切换观察）
    output wire        o_disp_valid,    // 已提交过至少一张图（首图后恒高）
    // 诊断（定位 3a 卡点）
    output wire [1:0]  o_arb_state,
    output wire        o_arb_owner, o_arb_pending,
    output wire [7:0]  o_img_fat_state,
    output wire [7:0]  o_aud_fat_state,
    output wire [5:0]  o_aud_file_cnt,   // 音频实例播放列表计数（排查空表假设）
    output wire [1:0]  o_ld_state,       // 装载 FSM 状态
    // 原始 PCM（wav_reader 直出，调试用）
    output wire signed [15:0] o_pcm_left,
    output wire signed [15:0] o_pcm_right,
    output wire        o_pcm_sval,
    output wire        o_wav_hdr_ok,
    output wire        o_wav_fmt_err,
    output wire [31:0] o_wav_data_bytes
);

    // ==================== 扇区读通道（sd_arbiter 双主机 → sd_spi 单从机） ====================
    // 图像 fat32_ro 主机侧
    wire [31:0] img_lba;
    wire        img_req, img_ready, img_dval, img_done, img_sec_err;
    wire [7:0]  img_data;
    // 音频 fat32_ro 主机侧
    wire [31:0] aud_lba;
    wire        aud_req, aud_sec_ready, aud_dval, aud_done, aud_err;
    wire [7:0]  aud_data;
    // 从机侧（→ sd_spi）
    wire [31:0] sec_lba;
    wire        sec_req, sec_ready, sec_dval, sec_done, sec_err;
    wire [7:0]  sec_data;

    // 各模块调试状态（seg 显示用）
    wire [7:0]  sd_dbg, bmp_dbg;
    wire [1:0]  arb_state;
    wire        arb_owner, arb_pending;

    // 音频节流：写入目标 FIFO 高水位停流。卡速 ≫ 48kHz 消费；若只按装载水位
    // 停流，续播期（写目标=播放 FIFO）会永久停流 → 播放 FIFO 放干后下溢
    wire [11:0] aud_prim_fill;
    wire [11:0] aud_wr_fill;
    wire aud_hold = (aud_wr_fill >= 12'd1920);
    wire aud_load_aud;      // 正在装载下一张图的配对音频
    wire aud_silence;       // 本次提交无配对音 → 静音

    sd_arbiter u_arb (
        .clk     (clk),
        .rst_n   (rst_n),
        .a_lba   (img_lba),  .a_req   (img_req),  .a_ready (img_ready),
        .a_data  (img_data), .a_dval  (img_dval), .a_done  (img_done),  .a_err (img_sec_err),
        .b_lba   (aud_lba),  .b_req   (aud_req),  .b_ready (aud_sec_ready),
        .b_data  (aud_data), .b_dval  (aud_dval), .b_done  (aud_done),  .b_err (aud_err),
        .s_lba   (sec_lba),  .s_req   (sec_req),  .s_ready (sec_ready),
        .s_data  (sec_data), .s_dval  (sec_dval), .s_done  (sec_done),  .s_err (sec_err),
        .i_b_hold(aud_hold),
        .o_state (arb_state), .o_owner (arb_owner), .o_pending (arb_pending)
    );

    sd_spi u_sd (
        .clk        (clk),
        .rst_n      (rst_n),
        .i_lba      (sec_lba),
        .i_req      (sec_req),
        .o_ready    (sec_ready),
        .o_data     (sec_data),
        .o_dval     (sec_dval),
        .o_done     (sec_done),
        .o_err      (sec_err),
        .spi_cs_n   (spi_cs_n),
        .spi_sclk   (spi_sclk),
        .spi_mosi   (spi_mosi),
        .spi_miso   (spi_miso),
        .o_dbg_state(sd_dbg)
    );

    // ==================== 图像 fat32_ro → bmp_dec ====================
    wire        img_mounted, img_idle, img_cur_is_wav;
    wire        img_fat_err;
    wire [5:0]  img_file_cnt, img_bmp_cnt, img_wav_cnt, img_type_map;
    wire [7:0]  img_fat_dbg;
    wire [7:0]  img_byte;
    wire        img_bval, img_file_done;
    reg         img_file_req;
    reg  [4:0]  img_file_idx;

    // 播放列表查找口（配对用）
    wire [4:0]  pl_lookup_idx;
    wire [63:0] pl_lookup_name;
    wire        pl_lookup_is_wav, pl_lookup_valid;

    fat32_ro u_fat_img (
        .clk          (clk),
        .rst_n        (rst_n),
        .o_lba        (img_lba),
        .o_req        (img_req),
        .i_ready      (img_ready),
        .i_data       (img_data),
        .i_dval       (img_dval),
        .i_done       (img_done),
        .i_err        (img_sec_err),
        .o_byte       (img_byte),
        .o_bval       (img_bval),
        .o_file_done  (img_file_done),
        .i_file_idx   (img_file_idx),
        .i_file_req   (img_file_req),
        .o_mounted    (img_mounted),
        .o_file_cnt   (img_file_cnt),
        .o_bmp_cnt    (img_bmp_cnt),
        .o_wav_cnt    (img_wav_cnt),
        .o_type_map   (img_type_map),
        .o_cur_is_wav (img_cur_is_wav),
        .o_err        (img_fat_err),
        .o_file_idle  (img_idle),
        .o_dbg_state  (img_fat_dbg),
        .i_pl_idx     (pl_lookup_idx),
        .o_pl_name    (pl_lookup_name),
        .o_pl_is_wav  (pl_lookup_is_wav),
        .o_pl_valid   (pl_lookup_valid)
    );

    wire        img_ok, img_err;
    wire        bmp_pix_val;
    wire [23:0] bmp_pix;
    bmp_dec u_bmp (
        .clk        (clk),
        .rst_n      (rst_n),
        .i_byte     (img_byte),
        .i_bval     (img_bval),
        .i_restart  (img_file_req),
        .o_pix_val  (bmp_pix_val),
        .o_pix      (bmp_pix),
        .o_img_ok   (img_ok),
        .o_img_err  (img_err),
        .o_dbg_state(bmp_dbg)
    );

    // ==================== 音频 fat32_ro → wav_reader → audio_path ====================
    wire        aud_mounted, aud_idle, aud_cur_is_wav;
    wire        aud_fat_err;
    wire [5:0]  aud_file_cnt;
    wire [5:0]  aud_cnt_unused;
    wire [63:0] aud_pl_unused;
    wire        aud_pl_is_wav_unused;
    wire        aud_pl_valid_unused;
    wire [7:0]  aud_fat_dbg;
    wire [7:0]  aud_byte;
    wire        aud_bval, aud_file_done;
    reg         aud_file_req;
    reg  [4:0]  aud_file_idx;

    fat32_ro u_fat_aud (
        .clk          (clk),
        .rst_n        (rst_n),
        .o_lba        (aud_lba),
        .o_req        (aud_req),
        .i_ready      (aud_sec_ready),
        .i_data       (aud_data),
        .i_dval       (aud_dval),
        .i_done       (aud_done),
        .i_err        (aud_err),
        .o_byte       (aud_byte),
        .o_bval       (aud_bval),
        .o_file_done  (aud_file_done),
        .i_file_idx   (aud_file_idx),
        .i_file_req   (aud_file_req),
        .o_mounted    (aud_mounted),
        .o_file_cnt   (aud_file_cnt),
        .o_bmp_cnt    (aud_cnt_unused),
        .o_wav_cnt    (aud_cnt_unused),
        .o_type_map   (aud_cnt_unused),
        .o_cur_is_wav (aud_cur_is_wav),
        .o_err        (aud_fat_err),
        .o_file_idle  (aud_idle),
        .o_dbg_state  (aud_fat_dbg),
        .i_pl_idx     (5'd0),
        .o_pl_name    (aud_pl_unused),
        .o_pl_is_wav  (aud_pl_is_wav_unused),
        .o_pl_valid   (aud_pl_valid_unused)
    );

    wire signed [15:0] pcm_left, pcm_right;
    wire        pcm_sval, wav_hdr_ok, wav_fmt_err;
    wire [31:0] wav_data_bytes;
    wire [7:0]  wav_dbg;
    wav_reader u_wav (
        .clk          (clk),
        .rst_n        (rst_n),
        .i_byte       (aud_byte),
        .i_bval       (aud_bval),
        .i_restart    (aud_file_req),
        .o_left       (pcm_left),
        .o_right      (pcm_right),
        .o_sval       (pcm_sval),
        .o_hdr_ok     (wav_hdr_ok),
        .o_fmt_err    (wav_fmt_err),
        .o_data_bytes (wav_data_bytes),
        .o_dbg_state  (wav_dbg)
    );

    // 48kHz 节拍：100M ÷ 2083 ≈ 48.0077kHz
    reg [11:0] met_cnt;
    wire aud_tick = (met_cnt == 12'd2082);
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)            met_cnt <= 12'd0;
        else if (aud_tick)     met_cnt <= 12'd0;
        else                   met_cnt <= met_cnt + 12'd1;
    end

    reg  audio_enable;                     // 首次提交后置位：允许播放
    wire aud_rd_en = aud_tick && audio_enable;
    wire        aud_underrun;
    wire signed [15:0] audio_left, audio_right;
    wire        audio_valid;
    wire        aud_commit;                // 提交脉冲 → audio_path 翻转角色
    audio_path u_audio (
        .clk        (clk),
        .rst_n      (rst_n),
        .i_sval     (pcm_sval),
        .i_left     (pcm_left),
        .i_right    (pcm_right),
        .i_commit   (aud_commit),
        .i_silence  (aud_silence),
        .i_play_en  (audio_enable),
        .i_load_aud (aud_load_aud),
        .i_rd_en    (aud_rd_en),
        .o_left     (audio_left),
        .o_right    (audio_right),
        .o_sval     (audio_valid),
        .o_underrun (aud_underrun),
        .o_prim_fill(aud_prim_fill),
        .o_wr_fill  (aud_wr_fill)
    );

    // ==================== 帧存储（乒乓双缓冲）→ VGA ====================
    localparam [20:0] BUF0_ADDR    = 21'd0;
    localparam [20:0] BUF1_ADDR    = 21'd307200;
    localparam [20:0] FRAME_PIXELS = 21'd307200;

    wire        mem_wr_req_ack, mem_wr_finish;
    wire        mem_rd_req, mem_rd_req_ack, mem_rd_en, mem_rd_finish;
    wire [31:0] mem_rd_data;
    reg         mem_wr_req;
    reg  [1:0]  wr_buf_idx;
    reg  [1:0]  disp_buf_idx;

    // 像素时钟使能：clk 当 100MHz，4 分频得 25MHz 像素节拍
    reg [1:0] pix_div;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) pix_div <= 2'd0;
        else        pix_div <= pix_div + 2'd1;
    end
    wire pix_ce = (pix_div == 2'd0);
    assign o_pix_ce = pix_ce;

    mem_sim #(
        .WRITE_V_FLIP (1),
        .FRAME_WIDTH  (640),
        .FRAME_HEIGHT (480)
    ) u_mem (
        .clk              (clk),
        .rst_n            (rst_n),
        .write_req        (mem_wr_req),
        .write_req_ack    (mem_wr_req_ack),
        .write_finish     (mem_wr_finish),
        .write_addr_0     (BUF0_ADDR),
        .write_addr_1     (BUF1_ADDR),
        .write_addr_index (wr_buf_idx),
        .write_len        (FRAME_PIXELS),
        .write_en         (bmp_pix_val),
        .write_data       ({bmp_pix, 8'd0}),
        .read_req         (mem_rd_req),
        .read_req_ack     (mem_rd_req_ack),
        .read_finish      (mem_rd_finish),
        .read_addr_0      (BUF0_ADDR),
        .read_addr_1      (BUF1_ADDR),
        .read_addr_index  (disp_buf_idx),
        .read_len         (FRAME_PIXELS),
        .read_en          (mem_rd_en),
        .read_data        (mem_rd_data),
        .o_wr_ovf         (o_mem_wr_ovf),
        .o_rd_und         (o_mem_rd_und),
        .o_len_err        (o_mem_len_err)
    );

    vga_ctrl u_vga (
        .clk            (clk),
        .rst_n          (rst_n),
        .i_ce           (pix_ce),
        .o_read_req     (mem_rd_req),
        .i_read_req_ack (mem_rd_req_ack),
        .o_read_en      (mem_rd_en),
        .i_read_data    (mem_rd_data),
        .vga_hsync   (vga_hsync),
        .vga_vsync   (vga_vsync),
        .vga_blank_n (vga_blank_n),
        .vga_r       (vga_r),
        .vga_g       (vga_g),
        .vga_b       (vga_b)
    );

    // ==================== 轮播 + 配对 + 双就绪原子提交 ====================
    function [5:0] next_img_idx;
        input [5:0] cur;
        input [5:0] cnt;
        input [5:0] tmap;
        reg   [5:0] cand;
        integer     k;
        begin
            next_img_idx = cur;
            cand = cur;
            for (k = 0; k < 6; k = k + 1) begin
                cand = (cand + 6'd1 >= cnt) ? 6'd0 : (cand + 6'd1);
                if (!((cand < 6'd6) && tmap[cand[2:0]]) &&
                    (next_img_idx == cur)) begin
                    next_img_idx = cand;
                end
            end
        end
    endfunction

    function [5:0] first_img_of;
        input [5:0] cnt;
        input [5:0] tmap;
        integer     k;
        reg         found;
        begin
            first_img_of = 6'd0;
            found = 1'b0;
            for (k = 0; k < 6; k = k + 1) begin
                if (!found && (k < cnt) && !tmap[k[2:0]]) begin
                    first_img_of = k[5:0];
                    found = 1'b1;
                end
            end
        end
    endfunction

    localparam [11:0] AUD_THRESH = 12'd1024;   // 音频就绪水位（≈21ms）

    reg        started;
    reg        req_pending;
    reg  [5:0] req_idx;
    reg  [5:0] cur_idx;
    reg        btn_prev;
    reg        vsync_prev;

    localparam [1:0] LD_IDLE = 2'd0, LD_SEARCH = 2'd1, LD_MEM_ACK = 2'd2, LD_FILE = 2'd3;
    reg [1:0]  ld_state;
    reg  [4:0] srch_j;
    reg  [63:0] img_name;
    reg        aud_pair_valid;
    reg  [4:0] aud_pair_idx;

    reg        load_busy;
    reg        commit_pending;
    reg        write_done_seen;
    reg        display_valid;
    reg [31:0] load_timeout_cnt;

    wire [5:0] next_idx  = next_img_idx(cur_idx, img_file_cnt, img_type_map);
    wire [5:0] first_idx = first_img_of(img_file_cnt, img_type_map);
    wire btn_rise = btn_next & ~btn_prev;
    wire vsync_edge = vsync_prev & ~vga_vsync;   // 场同步下降沿 = 帧边界

    // 配对搜索：LD_IDLE 时读图片自身名，LD_SEARCH 时逐项比 WAV 主名
    assign pl_lookup_idx = (ld_state == LD_IDLE) ? req_idx[4:0] : srch_j;

    // 音频就绪：无配对 / 配对 WAV 非法 → 静音即就绪；到水位或文件已读完
    // （短于水位的 WAV 靠 aud_file_done 兜底，否则水位永远不达标 → 超时死循环）
    reg  aud_load_done;
    assign aud_load_aud = load_busy && aud_pair_valid;
    assign aud_silence  = aud_commit  && !aud_pair_valid;
    wire aud_ready = !aud_pair_valid ? 1'b1
                   : wav_fmt_err     ? 1'b1
                   : aud_load_done   ? 1'b1
                   : (aud_prim_fill >= AUD_THRESH);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            started        <= 1'b0;
            req_pending    <= 1'b0;
            req_idx        <= 6'd0;
            cur_idx        <= 6'd0;
            btn_prev       <= 1'b0;
            vsync_prev     <= 1'b0;
            ld_state       <= LD_IDLE;
            srch_j         <= 5'd0;
            img_name       <= 64'd0;
            aud_pair_valid <= 1'b0;
            aud_pair_idx   <= 5'd0;
            mem_wr_req     <= 1'b0;
            wr_buf_idx     <= 2'd0;
            disp_buf_idx   <= 2'd0;
            img_file_req   <= 1'b0;
            img_file_idx   <= 5'd0;
            aud_file_req   <= 1'b0;
            aud_file_idx   <= 5'd0;
            load_busy      <= 1'b0;
            commit_pending <= 1'b0;
            write_done_seen<= 1'b0;
            aud_load_done  <= 1'b0;
            display_valid  <= 1'b0;
            audio_enable   <= 1'b0;
        end
        else begin
            btn_prev       <= btn_next;
            vsync_prev     <= vga_vsync;
            img_file_req   <= 1'b0;
            aud_file_req   <= 1'b0;
            mem_wr_req     <= 1'b0;

            // ---- 首次 / 按键 / TB 点播：登记要装载的图片 ----
            if (!started && img_mounted && img_file_cnt != 6'd0) begin
                started     <= 1'b1;
                req_pending <= 1'b1;
                req_idx     <= first_idx;
            end
            else if (btn_rise && started && !load_busy && !commit_pending) begin
                req_pending <= 1'b1;
                req_idx     <= next_idx;
            end
            else if (i_tb_file_req && started && !load_busy && !commit_pending) begin
                req_pending <= 1'b1;
                req_idx     <= {1'b0, i_tb_file_idx};
            end

            // ---- 装载序列：配对搜索 → 开写通道 → 发图/音请求 ----
            case (ld_state)
                LD_IDLE: begin
                    if (req_pending && img_idle && aud_idle) begin
                        wr_buf_idx     <= ~disp_buf_idx;   // 写非显示缓冲
                        img_name       <= pl_lookup_name;  // 读图片自身名
                        srch_j         <= 5'd0;
                        aud_pair_valid <= 1'b0;
                        ld_state       <= LD_SEARCH;
                    end
                end

                LD_SEARCH: begin
                    // 组合读 srch_j 的名字，与图片主名比对
                    if (pl_lookup_valid && pl_lookup_is_wav &&
                        (pl_lookup_name == img_name)) begin
                        aud_pair_valid <= 1'b1;
                        aud_pair_idx   <= srch_j;
                    end
                    if (srch_j == 5'd31) begin
                        ld_state <= LD_MEM_ACK;
                    end
                    else begin
                        srch_j <= srch_j + 5'd1;
                    end
                end

                LD_MEM_ACK: begin
                    // 协议：write_req 保持到 write_req_ack（一拍脉冲会永远等不到 ack）
                    mem_wr_req <= 1'b1;
                    if (mem_wr_req_ack) begin
                        mem_wr_req <= 1'b0;
                        ld_state   <= LD_FILE;
                    end
                end

                LD_FILE: begin
                    img_file_req <= 1'b1;
                    img_file_idx <= req_idx[4:0];
                    if (aud_pair_valid) begin
                        aud_file_req <= 1'b1;
                        aud_file_idx <= aud_pair_idx;
                    end
                    load_busy       <= 1'b1;
                    write_done_seen <= 1'b0;
                    aud_load_done   <= 1'b0;
                    req_pending     <= 1'b0;
                    ld_state        <= LD_IDLE;
                end

                default: ld_state <= LD_IDLE;
            endcase

            // ---- 装载进度：双就绪 → 等场同步 → 原子提交 ----
            if (load_busy && !commit_pending) begin
                if (img_err) begin
                    // 坏图：放弃不提交，光标推进（下一张从坏图之后找）
                    load_busy       <= 1'b0;
                    write_done_seen <= 1'b0;
                    cur_idx         <= req_idx;
                    req_pending     <= 1'b1;
                end
                else begin
                    if (mem_wr_finish) write_done_seen <= 1'b1;
                    if (aud_file_done) aud_load_done   <= 1'b1;
                    if (img_ok && write_done_seen && aud_ready)
                        commit_pending <= 1'b1;
                end
            end

            if (commit_pending) begin
                if (vsync_edge) begin
                    // 场同步沿原子切换：图 + 音同时换
                    disp_buf_idx   <= wr_buf_idx;
                    display_valid  <= 1'b1;
                    cur_idx        <= req_idx;
                    audio_enable   <= 1'b1;
                    load_busy      <= 1'b0;
                    commit_pending <= 1'b0;
                    write_done_seen<= 1'b0;
                end
            end

            // 超时兜底：坏卡/异常不挂死（100M 周期 = 1s）
            if (load_busy && !commit_pending) begin
                if (load_timeout_cnt > 32'd100_000_000) begin
                    load_busy       <= 1'b0;
                    write_done_seen <= 1'b0;
                    cur_idx         <= req_idx;
                    req_pending     <= 1'b1;
                end
                else begin
                    load_timeout_cnt <= load_timeout_cnt + 32'd1;
                end
            end
            else begin
                load_timeout_cnt <= 32'd0;
            end
        end
    end

    // 整图落盘标志：write_finish 单拍脉冲，锁存到下一次装载开始
    reg frame_ready;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)             frame_ready <= 1'b0;
        else if (img_file_req)  frame_ready <= 1'b0;
        else if (mem_wr_finish) frame_ready <= 1'b1;
    end
    assign o_frame_ready = frame_ready;

    assign aud_commit = (commit_pending && vsync_edge);

    // ==================== 状态指示 / 输出 ====================
    reg  fat_err_latched;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)             fat_err_latched <= 1'b0;
        else if (img_fat_err)   fat_err_latched <= 1'b1;
    end

    assign seg = img_err          ? bmp_dbg
               : fat_err_latched  ? img_fat_dbg
               :                   sd_dbg;
    assign led = {img_err, img_ok, img_mounted, sec_ready};

    assign o_mounted     = img_mounted;
    assign o_file_cnt    = img_file_cnt;
    assign o_bmp_cnt     = img_bmp_cnt;
    assign o_wav_cnt     = img_wav_cnt;
    assign o_img_ok      = img_ok;
    assign o_img_err     = img_err;
    assign o_file_done   = img_file_done;
    assign o_sd_err      = sec_err;
    assign o_audio_left  = audio_left;
    assign o_audio_right = audio_right;
    assign o_audio_valid = audio_valid;
    assign o_aud_underrun  = aud_underrun;
    assign o_aud_prim_fill = aud_prim_fill;
    assign o_aud_pair_valid= aud_pair_valid;
    assign o_aud_idx       = aud_pair_idx;
    assign o_disp_idx      = disp_buf_idx;
    assign o_disp_valid    = display_valid;
    assign o_arb_state     = arb_state;
    assign o_arb_owner     = arb_owner;
    assign o_arb_pending   = arb_pending;
    assign o_img_fat_state = img_fat_dbg;
    assign o_aud_fat_state = aud_fat_dbg;
    assign o_aud_file_cnt  = aud_file_cnt;
    assign o_ld_state      = ld_state;
    assign o_pcm_left    = pcm_left;
    assign o_pcm_right   = pcm_right;
    assign o_pcm_sval    = pcm_sval;
    assign o_wav_hdr_ok  = wav_hdr_ok;
    assign o_wav_fmt_err = wav_fmt_err;
    assign o_wav_data_bytes = wav_data_bytes;

    // 吸收未用信号
    wire _unused_rdfin = &{1'b0, mem_rd_finish,
                           aud_cur_is_wav, aud_fat_dbg[7:0],
                           aud_mounted, img_cur_is_wav,
                           aud_fat_err, wav_dbg[7:0],
                           aud_cnt_unused[5:0], aud_pl_unused[63:0],
                           aud_pl_is_wav_unused, aud_pl_valid_unused,
                           1'b0};

endmodule
