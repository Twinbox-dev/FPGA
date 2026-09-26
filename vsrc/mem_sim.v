// vsrc/mem_sim.v — 帧存储模型（板级 frame_read_write + SDRAM IP 的仿真替身）
//
// 上游：bmp_dec 的像素流（写口）
// 下游：vga_ctrl 的像素读口
// 板级：★ 本文件删除 —— 换成例程的 frame_read_write + sdr_as_ram.enc.v，
//       端口与握手已按例程 1:1 对齐，替换时上下游模块不用改
// 全局视图见 docs/architecture.md
//
// ============================================================================
// 为什么不是简单的 reg 阵列（前身 fb_sim 的教训）
// ============================================================================
// fb_sim 把帧缓存写成「给地址 + 给数据 = 立即写入」，这与板级接口有两处本质
// 不符，照搬上板会出现「仿真全绿、板上必错」：
//
//   1) 板级写口**不接受地址**。frame_fifo_write.v 里地址是存储侧自己生成的：
//          else if(App_wr_en) App_wr_addr_r <= App_wr_addr_r + 1'b1;
//      生产者只能往异步 FIFO 里推数据，**必须按线性地址顺序供数**。
//      BMP 自底向上的翻转由存储侧的 WRITE_V_FLIP 地址发生器完成，不是生产者
//      算地址。（fb_sim 时代 bmp_dec 自己算 disp_row = 479 - row，无处安放。）
//
//   2) 板级写口**没有背压**。frame_read_write.v 例化 wfifo_32_32_512 时
//      full_flag 端口是空着的 —— 生产者写快了就是静默丢数据，没有任何信号
//      告诉你。所以这里不发明一个板上不存在的 ready，而是**如实建模 FIFO
//      占用并在溢出时点亮 o_wr_ovf**，把板上会静默发生的事变成仿真可断言的事。
//
// ============================================================================
// 与例程的对应关系
// ============================================================================
// 端口名、状态机结构、突发判据均照抄 frame_fifo_write.v / frame_fifo_read.v，
// 仅有的简化：
//   - 单时钟（仿真顶层 clk 兼作 mem_clk/write_clk/read_clk），故省去例程里
//     write_req/read_req 的三级同步链；握手协议本身完全一致
//   - 复位用本仓库惯例 rst_n（低有效异步），例程是高有效 rst
//   - 基地址只保留 0/1 两块（乒乓够用），例程有 0..3 四块
//
// 时钟比必须建模，不能省（2026-09-23 实测教训）：
//   板级 mem_clk=100MHz、像素时钟=25MHz，存储侧有 4 倍带宽余量。最初图省事让
//   两者同频，结果读 FIFO 水位被**钉死在 256**、每帧必然下溢 —— 因为补水条件
//   是 rfifo_cnt < FIFO_DEPTH-BURST_SIZE（即 <256），而行消隐期水位恰好等于
//   256，唯一的空闲带宽被条件挡在门外，于是只在弹像素时补水、补多少弹多少，
//   零余量。这不是「偏保守」而是「退化到不可用」：o_rd_und 恒亮，等于没有。
//   现在由顶层用 1/4 时钟使能把 vga_ctrl 放进像素域，比例与板级一致。
//
// 握手协议（与例程逐字一致）：
//   写：write_req 拉高并保持，直到 write_req_ack=1 才可撤销；ack 期间锁存
//       write_len 与 write_addr_index，并清空写 FIFO。此后用 write_en/
//       write_data 线性供数，全部落盘后 write_finish 脉冲一拍。
//   读：read_req 同上；ack 后存储侧开始预填读 FIFO，read_en 弹出一个字，
//       read_data 在**下一拍**有效（例程 FIFO dout 是寄存输出）。
//
// 诊断输出（仿真专用，板级没有对应物，也正因如此才要在这里抓）：
//   o_wr_ovf  写 FIFO 溢出 —— 板上表现为静默丢像素
//   o_rd_und  读 FIFO 下溢 —— 板上表现为重复上一个像素（横向拖影）
//   o_len_err write_len 不是 BURST_SIZE 整数倍 —— 板上表现为最后一个突发
//             永远等不到 burst_cnt >= BURST_SIZE，状态机**死锁**
//             （例程靠 640*480 = 256*1200 恰好整除侥幸避开，音频缓冲若照搬
//              这套接口就会踩中，故在此显式断言）
module mem_sim #(
    parameter ADDR_BITS    = 21,
    parameter DATA_BITS    = 32,
    parameter BURST_SIZE   = 256,
    parameter FIFO_DEPTH   = 512,
    parameter WRITE_V_FLIP = 1,
    parameter FRAME_WIDTH  = 640,
    parameter FRAME_HEIGHT = 480,
    parameter MEM_WORDS    = 614400    // 2 块 640x480 缓冲
) (
    input  wire                   clk,
    input  wire                   rst_n,

    // ---- 写口（接 bmp_dec，语义同例程 frame_read_write 的 write_* ）----
    input  wire                   write_req,
    output reg                    write_req_ack,
    output wire                   write_finish,
    input  wire [ADDR_BITS-1:0]   write_addr_0,
    input  wire [ADDR_BITS-1:0]   write_addr_1,
    input  wire [1:0]             write_addr_index,
    input  wire [ADDR_BITS-1:0]   write_len,
    input  wire                   write_en,
    input  wire [DATA_BITS-1:0]   write_data,

    // ---- 读口（接 vga_ctrl，语义同例程的 read_* ）----
    input  wire                   read_req,
    output reg                    read_req_ack,
    output wire                   read_finish,
    input  wire [ADDR_BITS-1:0]   read_addr_0,
    input  wire [ADDR_BITS-1:0]   read_addr_1,
    input  wire [1:0]             read_addr_index,
    input  wire [ADDR_BITS-1:0]   read_len,
    input  wire                   read_en,
    output reg  [DATA_BITS-1:0]   read_data,

    // ---- 仿真诊断（sticky，一旦点亮不再熄灭）----
    output reg                    o_wr_ovf,
    output reg                    o_rd_und,
    output reg                    o_len_err
);

    // ------------------------------------------------------------------
    // 常量
    // ------------------------------------------------------------------
    // V_FLIP 地址映射：首字落在最后一显示行的行首，每写满一行回跳两行减一
    localparam [ADDR_BITS-1:0] VFLIP_FIRST_OFFSET = (FRAME_HEIGHT - 1) * FRAME_WIDTH;
    localparam [ADDR_BITS-1:0] VFLIP_LINE_JUMP    = (FRAME_WIDTH * 2) - 1;
    localparam [15:0]          VFLIP_LINE_LAST_X  = FRAME_WIDTH - 1;

    // 索引位宽：FIFO 指针与存储体地址各自按容量取，避免高位恒零
    localparam FIFO_AW = $clog2(FIFO_DEPTH);
    localparam MEM_AW  = $clog2(MEM_WORDS);

    localparam [3:0]
        S_IDLE      = 4'd0,
        S_ACK       = 4'd1,
        S_CHECK     = 4'd2,
        S_BURST     = 4'd3,
        S_BURST_END = 4'd4,
        S_END       = 4'd5;

    // ------------------------------------------------------------------
    // 存储体
    // ------------------------------------------------------------------
    reg [DATA_BITS-1:0] mem [0:MEM_WORDS-1];

    // ------------------------------------------------------------------
    // 写通道
    // ------------------------------------------------------------------
    reg  [3:0]            wstate;
    reg  [ADDR_BITS-1:0]  wlen_latch;
    reg  [ADDR_BITS-1:0]  write_cnt;        // 已落盘字数
    reg  [ADDR_BITS-1:0]  wr_addr;          // 存储侧自生成的写地址
    reg  [15:0]           wr_x;             // V_FLIP 用的行内列计数
    reg  [9:0]            wburst_cnt;

    // 写 FIFO（对应例程的 wfifo_32_32_512）
    reg  [DATA_BITS-1:0]  wfifo [0:FIFO_DEPTH-1];
    reg  [FIFO_AW-1:0]    wfifo_wp, wfifo_rp;
    reg  [10:0]           wfifo_cnt;

    // 读通道
    reg  [3:0]            rstate;
    reg  [ADDR_BITS-1:0]  rlen_latch;
    reg  [ADDR_BITS-1:0]  read_cnt;
    reg  [ADDR_BITS-1:0]  rd_addr;
    reg  [9:0]            rburst_cnt;

    // 读 FIFO（对应例程的 rfifo_32_32_512）
    reg  [DATA_BITS-1:0]  rfifo [0:FIFO_DEPTH-1];
    reg  [FIFO_AW-1:0]    rfifo_wp, rfifo_rp;
    reg  [10:0]           rfifo_cnt;

    // ------------------------------------------------------------------
    // 突发仲裁（照抄例程：写优先）
    //   例程 O_wr_busy 含「正在突发」和「即将突发」两种，O_rd_busy 只含
    //   「正在突发」—— 于是写方的意图能挡住读方，读方的意图挡不住写方。
    // ------------------------------------------------------------------
    // 声明次序即依赖次序：rd_busy → wr_into_burst → wr_busy → rd_into_burst，无组合环
    wire rd_busy       = (rstate == S_BURST);
    wire [ADDR_BITS-1:0] wfifo_cnt_ext = {{(ADDR_BITS-11){1'b0}}, wfifo_cnt};
    wire wr_into_burst = ((wlen_latch <= (wfifo_cnt_ext + write_cnt)) ||
                          (wfifo_cnt > BURST_SIZE)) && !rd_busy;
    wire wr_busy       = (wstate == S_BURST) || ((wstate == S_CHECK) && wr_into_burst);
    wire rd_into_burst = (rfifo_cnt < (FIFO_DEPTH - BURST_SIZE)) && !wr_busy;

    wire wr_pop  = (wstate == S_BURST) && (wburst_cnt < BURST_SIZE);
    wire rd_push = (rstate == S_BURST) && (rburst_cnt < BURST_SIZE);

    assign write_finish = (wstate == S_END);
    assign read_finish  = (rstate == S_END);

    // 选中的基地址（只用 index[0]，两块乒乓）
    wire [ADDR_BITS-1:0] wbase = write_addr_index[0] ? write_addr_1 : write_addr_0;
    wire [ADDR_BITS-1:0] rbase = read_addr_index[0]  ? read_addr_1  : read_addr_0;

    // index[1] 仅为对齐例程的四缓冲端口形态而保留，本模型两块乒乓够用
    wire _unused_idx = &{1'b0, write_addr_index[1], read_addr_index[1], 1'b0};

    // ------------------------------------------------------------------
    // 写 FIFO：推入（生产者侧，无背压，溢出即丢并点亮诊断）
    // ------------------------------------------------------------------
    wire wfifo_full = (wfifo_cnt >= FIFO_DEPTH);
    wire wr_push    = write_en && !wfifo_full;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wfifo_wp <= {FIFO_AW{1'b0}};
        end
        else if (wstate == S_ACK && write_req) begin
            // ack 期间清空 FIFO（例程的 fifo_aclr）
            wfifo_wp <= {FIFO_AW{1'b0}};
        end
        else if (wr_push) begin
            wfifo[wfifo_wp] <= write_data;
            wfifo_wp        <= wfifo_wp + 1'b1;
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wfifo_rp <= {FIFO_AW{1'b0}};
        end
        else if (wstate == S_ACK && write_req) begin
            wfifo_rp <= {FIFO_AW{1'b0}};
        end
        else if (wr_pop) begin
            wfifo_rp <= wfifo_rp + 1'b1;
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wfifo_cnt <= 11'd0;
        end
        else if (wstate == S_ACK && write_req) begin
            wfifo_cnt <= 11'd0;
        end
        else begin
            case ({wr_push, wr_pop})
                2'b10:   wfifo_cnt <= wfifo_cnt + 11'd1;
                2'b01:   wfifo_cnt <= wfifo_cnt - 11'd1;
                default: wfifo_cnt <= wfifo_cnt;
            endcase
        end
    end

    // ------------------------------------------------------------------
    // 写地址生成 + 落盘（V_FLIP 逻辑照抄 frame_fifo_write.v）
    // ------------------------------------------------------------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wr_addr <= {ADDR_BITS{1'b0}};
            wr_x    <= 16'd0;
        end
        else if (wstate == S_ACK && write_req) begin
            wr_x    <= 16'd0;
            wr_addr <= WRITE_V_FLIP ? (wbase + VFLIP_FIRST_OFFSET) : wbase;
        end
        else if (wr_pop) begin
            mem[wr_addr[MEM_AW-1:0]] <= wfifo[wfifo_rp];
            if (WRITE_V_FLIP) begin
                if (wr_x == VFLIP_LINE_LAST_X) begin
                    wr_x    <= 16'd0;
                    wr_addr <= wr_addr - VFLIP_LINE_JUMP;
                end
                else begin
                    wr_x    <= wr_x + 16'd1;
                    wr_addr <= wr_addr + {{(ADDR_BITS-1){1'b0}}, 1'b1};
                end
            end
            else begin
                wr_addr <= wr_addr + {{(ADDR_BITS-1){1'b0}}, 1'b1};
            end
        end
    end

    // ------------------------------------------------------------------
    // 写状态机（结构照抄 frame_fifo_write.v）
    // ------------------------------------------------------------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wstate        <= S_IDLE;
            wlen_latch    <= {ADDR_BITS{1'b0}};
            write_cnt     <= {ADDR_BITS{1'b0}};
            wburst_cnt    <= 10'd0;
            write_req_ack <= 1'b0;
        end
        else begin
            case (wstate)
                S_IDLE: begin
                    if (write_req) begin
                        wstate <= S_ACK;
                    end
                    write_req_ack <= 1'b0;
                end

                S_ACK: begin
                    if (!write_req) begin
                        wstate        <= S_CHECK;
                        write_req_ack <= 1'b0;
                    end
                    else begin
                        write_req_ack <= 1'b1;
                        wlen_latch    <= write_len;
                    end
                    write_cnt <= {ADDR_BITS{1'b0}};
                end

                S_CHECK: begin
                    wburst_cnt <= 10'd0;
                    if (write_req) begin
                        wstate <= S_ACK;
                    end
                    else if (wr_into_burst) begin
                        wstate <= S_BURST;
                    end
                end

                S_BURST: begin
                    wburst_cnt <= wburst_cnt + 10'd1;
                    if (wburst_cnt == BURST_SIZE - 1) begin
                        wstate    <= S_BURST_END;
                        write_cnt <= write_cnt + BURST_SIZE[ADDR_BITS-1:0];
                    end
                end

                S_BURST_END: begin
                    if (write_req) begin
                        wstate <= S_ACK;
                    end
                    else if (write_cnt < wlen_latch) begin
                        wstate <= S_CHECK;
                    end
                    else begin
                        wstate <= S_END;
                    end
                end

                S_END: begin
                    wstate <= S_IDLE;
                end

                default: wstate <= S_IDLE;
            endcase
        end
    end

    // ------------------------------------------------------------------
    // 读 FIFO + 读地址 + 读状态机
    // ------------------------------------------------------------------
    wire rfifo_empty = (rfifo_cnt == 11'd0);
    wire rd_pop      = read_en && !rfifo_empty;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rfifo_wp <= {FIFO_AW{1'b0}};
            rd_addr  <= {ADDR_BITS{1'b0}};
        end
        else if (rstate == S_ACK && read_req) begin
            rfifo_wp <= {FIFO_AW{1'b0}};
            rd_addr  <= rbase;
        end
        else if (rd_push) begin
            rfifo[rfifo_wp] <= mem[rd_addr[MEM_AW-1:0]];
            rfifo_wp        <= rfifo_wp + 1'b1;
            rd_addr         <= rd_addr + {{(ADDR_BITS-1){1'b0}}, 1'b1};
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rfifo_rp  <= {FIFO_AW{1'b0}};
            read_data <= {DATA_BITS{1'b0}};
        end
        else if (rstate == S_ACK && read_req) begin
            rfifo_rp <= {FIFO_AW{1'b0}};
        end
        else if (rd_pop) begin
            // 例程 FIFO dout 为寄存输出：read_en 的下一拍数据才有效
            read_data <= rfifo[rfifo_rp];
            rfifo_rp  <= rfifo_rp + 1'b1;
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rfifo_cnt <= 11'd0;
        end
        else if (rstate == S_ACK && read_req) begin
            rfifo_cnt <= 11'd0;
        end
        else begin
            case ({rd_push, rd_pop})
                2'b10:   rfifo_cnt <= rfifo_cnt + 11'd1;
                2'b01:   rfifo_cnt <= rfifo_cnt - 11'd1;
                default: rfifo_cnt <= rfifo_cnt;
            endcase
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rstate       <= S_IDLE;
            rlen_latch   <= {ADDR_BITS{1'b0}};
            read_cnt     <= {ADDR_BITS{1'b0}};
            rburst_cnt   <= 10'd0;
            read_req_ack <= 1'b0;
        end
        else begin
            case (rstate)
                S_IDLE: begin
                    if (read_req) begin
                        rstate <= S_ACK;
                    end
                    read_req_ack <= 1'b0;
                end

                S_ACK: begin
                    if (!read_req) begin
                        rstate       <= S_CHECK;
                        read_req_ack <= 1'b0;
                    end
                    else begin
                        read_req_ack <= 1'b1;
                        rlen_latch   <= read_len;
                    end
                    read_cnt <= {ADDR_BITS{1'b0}};
                end

                S_CHECK: begin
                    rburst_cnt <= 10'd0;
                    if (read_req) begin
                        rstate <= S_ACK;
                    end
                    else if (rd_into_burst) begin
                        rstate <= S_BURST;
                    end
                end

                S_BURST: begin
                    rburst_cnt <= rburst_cnt + 10'd1;
                    if (rburst_cnt == BURST_SIZE - 1) begin
                        rstate   <= S_BURST_END;
                        read_cnt <= read_cnt + BURST_SIZE[ADDR_BITS-1:0];
                    end
                end

                S_BURST_END: begin
                    if (read_req) begin
                        rstate <= S_ACK;
                    end
                    else if (read_cnt < rlen_latch) begin
                        rstate <= S_CHECK;
                    end
                    else begin
                        rstate <= S_END;
                    end
                end

                S_END: begin
                    rstate <= S_IDLE;
                end

                default: rstate <= S_IDLE;
            endcase
        end
    end

    // ------------------------------------------------------------------
    // 诊断（sticky）
    // ------------------------------------------------------------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            o_wr_ovf  <= 1'b0;
            o_rd_und  <= 1'b0;
            o_len_err <= 1'b0;
        end
        else begin
            // 写 FIFO 已满还在写：板级会静默丢数据
            if (write_en && wfifo_full && !wr_pop) begin
                o_wr_ovf <= 1'b1;
            end
            // 读 FIFO 空还在弹：板级会重复上一个像素
            if (read_en && rfifo_empty) begin
                o_rd_und <= 1'b1;
            end
            // 传输长度非突发整数倍：板级最后一个突发等不到 burst_cnt 满 → 死锁
            if (wstate == S_ACK && write_req &&
                (write_len & (BURST_SIZE - 1)) != 0) begin
                o_len_err <= 1'b1;
            end
            if (rstate == S_ACK && read_req &&
                (read_len & (BURST_SIZE - 1)) != 0) begin
                o_len_err <= 1'b1;
            end
        end
    end

endmodule
