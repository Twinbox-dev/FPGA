// vsrc/bmp_dec.v — BMP 解码器（W2，自 bmp_loader 拆出；2026-10-03 多分辨率扩展）
//
// 上游：fat32_ro 的文件字节流（与 wav_reader 并联共享）
// 下游：帧存储写口（仿真 mem_sim，板级 frame_read_write）
// 板级：原样搬
// 全局视图见 docs/architecture.md
//
// 消费 fat32_ro 的文件字节流：校验 BMP 头（BM/24bpp/不压缩/尺寸 ≤1280×720 且
// 非 0）→ 数据流 3 字节组 1 像素（BGR → RGB）→ 以 o_pix_val/o_pix 线性吐出。
// **分辨率不再是单一的 1280×720**：头部声明 w×h（≤720p 任意尺寸，含 BMP 行
// 4 字节对齐填充的跳过）都接受——信箱式适配（居中 + 黑边）由下游打包器完成，
// 本模块只负责把「文件像素」按行内顺序吐干净。
// 头校验失败 o_img_err；吐满 w*h 像素后 o_img_ok。
// 轮播切换时由 i_restart 复位全部解析状态（含撤销 img_ok/img_err）。
//
// ---------------------------------------------------------------------------
// 为什么这里不算地址、也不做上下翻转（2026-09-23 修正）
// ---------------------------------------------------------------------------
// 早先本模块自己算 pix_addr 并用 disp_row = 479 - row 做 BMP 自底向上翻转。
// 精读例程 frame_fifo_write.v 后发现板级写口**根本没有地址输入**：
//     else if(App_wr_en) App_wr_addr_r <= App_wr_addr_r + 1'b1;
// 生产者只能往 FIFO 里推数据，地址由存储侧线性生成；厂商把翻转做成了存储侧
// 的 WRITE_V_FLIP 参数（首地址落在末行行首，每满一行回跳 2*W-1）。
//
// 也就是说旧写法搬上板会**上下颠倒**，而且仿真里一切正常、波形上也看不出来
// —— 正是 docs/TODO.md 标记的那类"仿真全绿、上板必炸"。故本模块退化为纯粹的
// 「BMP 字节流 → 像素流」转换器，行序归属存储层（mem_sim/WRITE_V_FLIP）。
module bmp_dec (
    input  wire        clk,
    input  wire        rst_n,

    // ---- 文件字节流（来自 fat32_ro）----
    input  wire [7:0]  i_byte,
    input  wire        i_bval,
    input  wire        i_restart,    // 新文件开始：复位解析状态（轮播切换）

    // ---- 像素流（接 mem_sim 写口；无地址、无背压，见文件头说明）----
    output reg         o_pix_val,
    output reg  [23:0] o_pix,        // {R,G,B}，按 BMP 文件顺序（自底向上）

    // ---- 头部导出（打包器做信箱适配用；byte53 校验通过后有效）----
    output reg  [11:0] o_img_w,      // 图像宽（像素）
    output reg  [11:0] o_img_h,      // 图像高（像素）
    output reg         o_hdr_ok,     // 本文件头校验通过（i_restart 清零）。⚠ 消费方
                                     //   不可用「o_img_w!=0」代替：w 在两次装载间
                                     //   保持旧值，会让新会话拿旧图尺寸提前开门
                                     //   （card.img S5-S8 连锁失败即此因）

    // ---- 状态 ----
    output reg         o_img_ok,     // 全部 w*h 像素吐完（含头校验通过）
    output reg         o_img_err,    // 头校验失败
    output wire [7:0]  o_dbg_state
);

    localparam [22:0] HDR_BYTES = 23'd54;
    localparam [11:0] MAX_W = 12'd1280, MAX_H = 12'd720;

    localparam [7:0]
        S_RUN  = 8'd0,   // 头部/数据流转中
        S_PAD  = 8'd1,   // 行尾对齐填充字节跳过
        S_OK   = 8'd2,   // 全图完成
        S_HDR  = 8'd3;   // 头校验失败

    reg [7:0] state;
    assign o_dbg_state = state;

    reg [22:0] byte_cnt;             // 文件内字节序号（头部用）
    reg [31:0] w_le, h_le, comp_le;  // 头部字段收集（小端右插）
    reg [15:0] bpp_le;
    reg [15:0] pix_sh;               // 像素组装（B、G 两字节，R 直通）
    reg [1:0]  by3;
    reg [11:0] col, row;             // 行内像素列 / 行号（图像坐标系）
    reg [1:0]  pad_left;             // 当前行剩余对齐填充字节数
    reg [23:0] px_cnt;               // 已吐像素数（判完成：== w*h）

    // 行对齐：BMP 每行 4 字节对齐。row_bytes = (w*3 + 3) & ~3，pad = row_bytes - w*3
    wire [13:0] w3        = {2'b0, o_img_w} * 3'd3;           // ≤ 3840
    wire [13:0] row_bytes = (w3 + 13'd3) & 13'h3FFC;
    // ⚠ pad 不能取 row_bytes[1:0]（4 对齐后恒 0）——pad = (4 - w*3%4) % 4，
    //   2 位补码减法恰好给出该值（w3=1923 → -3 mod 4 = 1 ✓）
    wire [1:0]  row_pad   = 2'd0 - w3[1:0];

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state      <= S_RUN;
            o_pix_val  <= 1'b0;
            o_pix      <= 24'd0;
            o_img_ok   <= 1'b0;
            o_img_err  <= 1'b0;
            o_img_w    <= 12'd0;
            o_img_h    <= 12'd0;
            o_hdr_ok   <= 1'b0;
            byte_cnt   <= 23'd0;
            w_le       <= 32'd0;
            h_le       <= 32'd0;
            comp_le    <= 32'd0;
            bpp_le     <= 16'd0;
            pix_sh     <= 16'd0;
            by3        <= 2'd0;
            col        <= 12'd0;
            row        <= 12'd0;
            pad_left   <= 2'd0;
            px_cnt     <= 24'd0;
        end
        else begin
            o_pix_val <= 1'b0;

            if (i_restart) begin
                // 轮播切换到新文件：全部解析状态归零，img_ok/img_err 撤销
                state      <= S_RUN;
                byte_cnt   <= 23'd0;
                w_le       <= 32'd0;
                h_le       <= 32'd0;
                comp_le    <= 32'd0;
                bpp_le     <= 16'd0;
                pix_sh     <= 16'd0;
                by3        <= 2'd0;
                col        <= 12'd0;
                row        <= 12'd0;
                pad_left   <= 2'd0;
                px_cnt     <= 24'd0;
                o_img_ok   <= 1'b0;
                o_img_err  <= 1'b0;
                o_hdr_ok   <= 1'b0;
            end
            else if (state == S_OK || state == S_HDR) begin
                // 完成/失败后剩余字节照收不吐（文件尾由 fat32 的 file_done 收口）
            end
            else if (state == S_PAD) begin
                // 行尾对齐填充：只吞字节不吐像素
                if (i_bval) begin
                    pad_left <= pad_left - 1'b1;
                    if (pad_left == 2'd1)
                        state <= S_RUN;
                end
            end
            else if (i_bval) begin
                if (byte_cnt < HDR_BYTES) begin
                    // ---- 头部：校验与收集 ----
                    case (byte_cnt)
                        20'd0: begin
                            if (i_byte != 8'h42) begin        // 'B'
                                state     <= S_HDR;
                                o_img_err <= 1'b1;
                            end
                        end
                        20'd1: begin
                            if (i_byte != 8'h4D) begin        // 'M'
                                state     <= S_HDR;
                                o_img_err <= 1'b1;
                            end
                        end
                        // 字段为小端：先到的字节在低位 → 右移插入
                        20'd18, 20'd19, 20'd20, 20'd21: begin
                            w_le <= {i_byte, w_le[31:8]};
                        end
                        20'd22, 20'd23, 20'd24, 20'd25: begin
                            h_le <= {i_byte, h_le[31:8]};
                        end
                        20'd28, 20'd29: begin
                            bpp_le <= {i_byte, bpp_le[15:8]};
                        end
                        20'd30, 20'd31, 20'd32, 20'd33: begin
                            comp_le <= {i_byte, comp_le[31:8]};
                        end
                        20'd53: begin
                            // ⚠ 多分辨率：尺寸 ≤720p 的 24bit 非压缩 BMP 都接受
                            //（信箱适配由下游打包器完成）；其余一律拒绝
                            if (w_le == 32'd0 || h_le == 32'd0 ||
                                w_le > 32'd1280 || h_le > 32'd720 ||
                                bpp_le != 16'd24 || comp_le != 32'd0) begin
                                state     <= S_HDR;
                                o_img_err <= 1'b1;
                            end
                            else begin
                                o_img_w  <= w_le[11:0];
                                o_img_h  <= h_le[11:0];
                                o_hdr_ok <= 1'b1;
                            end
                        end
                        default: ;
                    endcase
                end
                else begin
                    // ---- 数据相：3 字节组 1 像素（BGR → RGB），保持文件顺序 ----
                    pix_sh <= {pix_sh[7:0], i_byte};
                    if (by3 == 2'd2) begin
                        // 第 3 字节 = R；pix_sh[7:0] = G，pix_sh[15:8] = B
                        o_pix_val <= 1'b1;
                        o_pix     <= {i_byte, pix_sh[7:0], pix_sh[15:8]};
                        by3       <= 2'd0;
                        px_cnt    <= px_cnt + 1'b1;
                        if (col == o_img_w - 12'd1) begin
                            col <= 12'd0;
                            if (row == o_img_h - 12'd1) begin
                                state    <= S_OK;              // 全图完成
                                o_img_ok <= 1'b1;
                            end
                            else begin
                                row      <= row + 1'b1;
                                pad_left <= row_pad;           // 行对齐填充
                                state    <= (row_pad == 2'd0) ? S_RUN : S_PAD;
                            end
                        end
                        else begin
                            col <= col + 1'b1;
                        end
                    end
                    else begin
                        by3 <= by3 + 2'd1;
                    end
                end

                byte_cnt <= byte_cnt + 1'b1;
            end
        end
    end

endmodule
