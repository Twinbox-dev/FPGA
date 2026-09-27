// vsrc/bmp_dec.v — BMP 解码器（W2，自 bmp_loader 拆出）
//
// 上游：fat32_ro 的文件字节流（与 wav_reader 并联共享）
// 下游：帧存储写口（仿真 mem_sim，板级 frame_read_write）
// 板级：原样搬
// 全局视图见 docs/architecture.md
//
// 消费 fat32_ro 的文件字节流：校验 BMP 头（BM/1280x720/24bpp/不压缩）→
// 数据流 3 字节组 1 像素（BGR → RGB）→ 以 o_pix_val/o_pix 线性吐出。
// 头校验失败 o_img_err；全部字节处理完 o_img_ok。
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

    // ---- 状态 ----
    output reg         o_img_ok,     // 整图完成（含头校验通过）
    output reg         o_img_err,    // 头校验失败
    output wire [7:0]  o_dbg_state
);

    localparam [22:0] HDR_BYTES   = 23'd54;
    localparam [22:0] TOTAL_BYTES = 23'd2764854;  // 54 + 1280*720*3

    localparam [7:0]
        S_RUN = 8'd0,
        S_OK  = 8'd1,
        S_HDR = 8'd2;   // 头校验失败

    reg [7:0] state;
    assign o_dbg_state = state;

    reg [22:0] byte_cnt;             // 文件内字节序号
    reg [31:0] w_le, h_le, comp_le;  // 头部字段收集（小端右插）
    reg [15:0] bpp_le;
    reg [15:0] pix_sh;               // 像素组装（B、G 两字节，R 直通）
    reg [1:0]  by3;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state      <= S_RUN;
            o_pix_val  <= 1'b0;
            o_pix      <= 24'd0;
            o_img_ok   <= 1'b0;
            o_img_err  <= 1'b0;
            byte_cnt   <= 20'd0;
            w_le       <= 32'd0;
            h_le       <= 32'd0;
            comp_le    <= 32'd0;
            bpp_le     <= 16'd0;
            pix_sh     <= 16'd0;
            by3        <= 2'd0;
        end
        else begin
            o_pix_val <= 1'b0;

            if (i_restart) begin
                // 轮播切换到新文件：全部解析状态归零，img_ok/img_err 撤销
                state      <= S_RUN;
                byte_cnt   <= 20'd0;
                w_le       <= 32'd0;
                h_le       <= 32'd0;
                comp_le    <= 32'd0;
                bpp_le     <= 16'd0;
                pix_sh     <= 16'd0;
                by3        <= 2'd0;
                o_img_ok   <= 1'b0;
                o_img_err  <= 1'b0;
            end
            else if (state == S_RUN && i_bval) begin
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
                            if (w_le != 32'd1280 || h_le != 32'd720 ||
                                bpp_le != 16'd24 || comp_le != 32'd0) begin
                                state     <= S_HDR;
                                o_img_err <= 1'b1;
                            end
                        end
                        default: ;
                    endcase
                end
                else if (byte_cnt < TOTAL_BYTES) begin
                    // ---- 数据相：3 字节组 1 像素（BGR → RGB），保持文件顺序 ----
                    pix_sh <= {pix_sh[7:0], i_byte};
                    if (by3 == 2'd2) begin
                        // 第 3 字节 = R；pix_sh[7:0] = G，pix_sh[15:8] = B
                        o_pix_val <= 1'b1;
                        o_pix     <= {i_byte, pix_sh[7:0], pix_sh[15:8]};
                        by3       <= 2'd0;
                    end
                    else begin
                        by3 <= by3 + 2'd1;
                    end
                end

                byte_cnt <= byte_cnt + 20'd1;
                if (byte_cnt == TOTAL_BYTES - 20'd1) begin
                    state    <= S_OK;
                    o_img_ok <= 1'b1;
                end
            end
        end
    end

endmodule
