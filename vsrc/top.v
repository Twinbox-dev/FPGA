// vsrc/top.v — 系统顶层（仿真用；板级顶层在 TD 工程，board/ 目录）
//
// 全局视图见 docs/architecture.md，规格决策见 docs/design.md。
//
// 当前集成度（图像轮播）：音频已在重构中改走 SDRAM（boardtest → board 线开发），
// 本仿真顶层保持图像专用 golden：
//   卡 ← sd_spi ← fat32_ro → bmp_dec → mem_sim(乒乓) → vga_ctrl → VGA
//
// 轮播控制（本文件实现，板级同源逻辑在 boardtest/vsrc/sd_card_bmp.v）：
//   - 挂载后自动加载第一个图片项；btn_next 切下一张（到尾回绕、跳过音频项）
//   - 首图提交后 vsync 沿原子切换显示缓冲（装载期间旧图照常显示）
//   - 坏图（img_err）不提交、光标推进
//
// 装载顺序（与 frame_fifo_write 语义配套）：
//   空闲 → 开写通道（write_req 保持到 ack，清写 FIFO 并锁存长度）
//        → 再向 fat32_ro 发文件请求。
//
// 时钟：仿真顶层单时钟 clk = 板级 100MHz mem_clk；像素域 1/4 时钟使能（25MHz）。
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
    output wire [1:0]  o_disp_idx,      // 当前显示缓冲（乒乓切换观察）
    output wire        o_disp_valid,    // 已提交过至少一张图（首图后恒高）
    output wire [7:0]  o_img_fat_state,
    output wire [1:0]  o_ld_state       // 装载 FSM 状态
);

    // ==================== 扇区读通道（fat32_ro → sd_spi） ====================
    wire [31:0] sec_lba;
    wire        sec_req, sec_ready, sec_dval, sec_done, sec_err;
    wire [7:0]  sec_data;

    wire [7:0]  sd_dbg, bmp_dbg;

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

    // ==================== fat32_ro → bmp_dec ====================
    wire        fat_mounted, fat_idle, fat_cur_is_wav;
    wire        fat_err;
    wire [5:0]  fat_file_cnt, fat_bmp_cnt, fat_wav_cnt, fat_type_map;
    wire [7:0]  fat_dbg;
    wire [7:0]  file_byte;
    wire        file_bval, file_done;
    reg         file_req;
    reg  [4:0]  file_idx;

    fat32_ro u_fat (
        .clk          (clk),
        .rst_n        (rst_n),
        .o_lba        (sec_lba),
        .o_req        (sec_req),
        .i_ready      (sec_ready),
        .i_data       (sec_data),
        .i_dval       (sec_dval),
        .i_done       (sec_done),
        .i_err        (sec_err),
        .o_byte       (file_byte),
        .o_bval       (file_bval),
        .o_file_done  (file_done),
        .i_file_idx   (file_idx),
        .i_file_req   (file_req),
        .o_mounted    (fat_mounted),
        .o_file_cnt   (fat_file_cnt),
        .o_bmp_cnt    (fat_bmp_cnt),
        .o_wav_cnt    (fat_wav_cnt),
        .o_type_map   (fat_type_map),
        .o_cur_is_wav (fat_cur_is_wav),
        .o_err        (fat_err),
        .o_file_idle  (fat_idle),
        .o_dbg_state  (fat_dbg)
    );

    wire        img_ok, img_err;
    wire        bmp_pix_val;
    wire [23:0] bmp_pix;
    bmp_dec u_bmp (
        .clk        (clk),
        .rst_n      (rst_n),
        .i_byte     (file_byte),
        .i_bval     (file_bval),
        .i_restart  (file_req),
        .o_pix_val  (bmp_pix_val),
        .o_pix      (bmp_pix),
        .o_img_ok   (img_ok),
        .o_img_err  (img_err),
        .o_dbg_state(bmp_dbg)
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

    // ==================== 轮播 + vsync 原子提交 ====================
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

    reg        started;
    reg        req_pending;
    reg  [5:0] req_idx;
    reg  [5:0] cur_idx;
    reg        btn_prev;
    reg        vsync_prev;

    localparam [1:0] LD_IDLE = 2'd0, LD_MEM_ACK = 2'd1, LD_FILE = 2'd2;
    reg [1:0]  ld_state;

    reg        load_busy;
    reg        commit_pending;
    reg        write_done_seen;
    reg        display_valid;
    reg [31:0] load_timeout_cnt;

    wire [5:0] next_idx  = next_img_idx(cur_idx, fat_file_cnt, fat_type_map);
    wire [5:0] first_idx = first_img_of(fat_file_cnt, fat_type_map);
    wire btn_rise = btn_next & ~btn_prev;
    wire vsync_edge = vsync_prev & ~vga_vsync;   // 场同步下降沿 = 帧边界

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            started         <= 1'b0;
            req_pending     <= 1'b0;
            req_idx         <= 6'd0;
            cur_idx         <= 6'd0;
            btn_prev        <= 1'b0;
            vsync_prev      <= 1'b0;
            ld_state        <= LD_IDLE;
            mem_wr_req      <= 1'b0;
            wr_buf_idx      <= 2'd0;
            disp_buf_idx    <= 2'd0;
            file_req        <= 1'b0;
            file_idx        <= 5'd0;
            load_busy       <= 1'b0;
            commit_pending  <= 1'b0;
            write_done_seen <= 1'b0;
            display_valid   <= 1'b0;
        end
        else begin
            btn_prev   <= btn_next;
            vsync_prev <= vga_vsync;
            file_req   <= 1'b0;
            mem_wr_req <= 1'b0;

            // ---- 首次 / 按键 / TB 点播：登记要装载的图片 ----
            if (!started && fat_mounted && fat_file_cnt != 6'd0) begin
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

            // ---- 装载序列：开写通道 → 发文件请求 ----
            case (ld_state)
                LD_IDLE: begin
                    if (req_pending && fat_idle) begin
                        wr_buf_idx <= ~disp_buf_idx;   // 写非显示缓冲
                        ld_state   <= LD_MEM_ACK;
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
                    file_req        <= 1'b1;
                    file_idx        <= req_idx[4:0];
                    load_busy       <= 1'b1;
                    write_done_seen <= 1'b0;
                    req_pending     <= 1'b0;
                    ld_state        <= LD_IDLE;
                end

                default: ld_state <= LD_IDLE;
            endcase

            // ---- 装载进度：图就绪 → 等场同步 → 原子提交 ----
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
                    if (img_ok && write_done_seen)
                        commit_pending <= 1'b1;
                end
            end

            if (commit_pending) begin
                if (vsync_edge) begin
                    // 场同步沿原子切换显示缓冲
                    disp_buf_idx    <= wr_buf_idx;
                    display_valid   <= 1'b1;
                    cur_idx         <= req_idx;
                    load_busy       <= 1'b0;
                    commit_pending  <= 1'b0;
                    write_done_seen <= 1'b0;
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
        if (!rst_n)            frame_ready <= 1'b0;
        else if (file_req)     frame_ready <= 1'b0;
        else if (mem_wr_finish) frame_ready <= 1'b1;
    end
    assign o_frame_ready = frame_ready;

    // ==================== 状态指示 / 输出 ====================
    reg  fat_err_latched;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)            fat_err_latched <= 1'b0;
        else if (fat_err)      fat_err_latched <= 1'b1;
    end

    assign seg = img_err         ? bmp_dbg
               : fat_err_latched ? fat_dbg
               :                   sd_dbg;
    assign led = {img_err, img_ok, fat_mounted, sec_ready};

    assign o_mounted      = fat_mounted;
    assign o_file_cnt     = fat_file_cnt;
    assign o_bmp_cnt      = fat_bmp_cnt;
    assign o_wav_cnt      = fat_wav_cnt;
    assign o_img_ok       = img_ok;
    assign o_img_err      = img_err;
    assign o_file_done    = file_done;
    assign o_sd_err       = sec_err;
    assign o_disp_idx     = disp_buf_idx;
    assign o_disp_valid   = display_valid;
    assign o_img_fat_state= fat_dbg;
    assign o_ld_state     = ld_state;

    // 吸收未用信号
    wire _unused = &{1'b0, mem_rd_finish, fat_cur_is_wav, 1'b0};

endmodule
