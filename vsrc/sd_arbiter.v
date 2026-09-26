// vsrc/sd_arbiter.v — 双 fat32_ro 实例共享 sd_spi 的扇区读仲裁器（3a）
//
// 3a 音画同步需要同时从卡里读「图」和「音」两条文件流。sd_spi 同一时刻只能
// 服务一个扇区读，故用本模块把两个 fat32_ro（A=图像、B=音频）的扇区读请求
// 仲裁到同一个 sd_spi：
//
//   fat32_ro(A,图) ──► sd_arbiter ──► sd_spi ──► 卡
//   fat32_ro(B,音) ──►      ▲
//                          └ 仲裁：音频优先
//
// 协议（两侧都同 fat32_ro 的扇区读协议）：
//   主机侧：o_req 一拍 + o_lba，i_ready 采样，i_data/i_dval 数据流，i_done/i_err 一拍
//   从机侧：i_req 保持到 o_ready 采样，o_data/o_dval/o_done/o_err
//
// 仲裁策略：音频（B）优先。
//
// 音频节流（i_b_hold）：i_b_hold=1 时 b_ready 拉低，fat32_ro(B) 停在 S_ISSUE
//   不发请求，扇区级停流（字节流只是暂停，不会丢数据）；FIFO 掉回低水位后自动
//   续流。不设节流的后果：卡速 ≫ 48kHz 消费，装载期 FIFO 灌满后尾部样本被
//   写丢弃永久丢失，长 WAV 提交后 ~42ms 即下溢（design.md §2「低水位请求」）。
//   迟到请求照常进 pending： grant 多给一拍至多溢出 128 样本，由 FIFO 写丢弃兜底。
//
// ⚠ 关键时序（本模块最重要的正确性约束）：
//   fat32_ro 在 i_ready=1 的下一拍才发 o_req（S_ISSUE→S_STREAM）。因此可能
//   「A 的请求已被仲裁器受理进入 SERVE 后，B 才把自己那一拍 o_req 发出来」。
//   若仲裁器在 SERVE 不再监听，B 的请求就丢了、B 永远卡在 S_STREAM —— 挂载死锁。
//   故 SERVE 期间仍要监听非 owner 的迟到请求并排队（pending），服务完当前扇区
//   紧接着服务它。同一时刻最多只有一路会迟到（owner 在 S_STREAM 不会发请求）。
module sd_arbiter (
    input  wire        clk,
    input  wire        rst_n,

    // ---- 主机 A（图像 fat32_ro）----
    input  wire [31:0] a_lba,
    input  wire        a_req,
    output reg         a_ready,
    output reg  [7:0]  a_data,
    output reg         a_dval,
    output reg         a_done,
    output reg         a_err,

    // ---- 主机 B（音频 fat32_ro，优先）----
    input  wire [31:0] b_lba,
    input  wire        b_req,
    output reg         b_ready,
    output reg  [7:0]  b_data,
    output reg         b_dval,
    output reg         b_done,
    output reg         b_err,

    // ---- 从机（sd_spi）----
    output reg  [31:0] s_lba,
    output reg         s_req,
    input  wire        s_ready,
    input  wire [7:0]  s_data,
    input  wire        s_dval,
    input  wire        s_done,
    input  wire        s_err,

    // ---- 音频节流（高水位停流：B 的 ready 由上游按 FIFO 水位拉低）----
    input  wire        i_b_hold,

    // ---- 诊断 ----
    output wire [1:0]  o_state,
    output wire        o_owner,
    output wire        o_pending
);

    localparam [1:0] IDLE = 2'd0, SERVE = 2'd1;
    reg [1:0]  state;
    reg        owner;        // 0=A 1=B（当前服务的路）
    reg        pending;      // 有排队请求
    reg        pend_which;   // 排队的路（0=A 1=B）
    reg [31:0] lba_cur;      // 当前服务的 LBA
    reg [31:0] pend_lba;     // 排队的 LBA

    // s_ready 由从机（sd_spi）自己采样 s_req 锁存，本模块只负责保持 s_req
    wire _unused_sready = &{1'b0, s_ready, 1'b0};

    assign o_state   = state;
    assign o_owner   = owner;
    assign o_pending = pending;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state     <= IDLE;
            owner     <= 1'b0;
            pending   <= 1'b0;
            pend_which<= 1'b0;
            lba_cur   <= 32'd0;
            pend_lba  <= 32'd0;
            a_ready   <= 1'b0;
            b_ready   <= 1'b0;
            a_data    <= 8'd0;
            a_dval    <= 1'b0;
            a_done    <= 1'b0;
            a_err     <= 1'b0;
            b_data    <= 8'd0;
            b_dval    <= 1'b0;
            b_done    <= 1'b0;
            b_err     <= 1'b0;
            s_lba     <= 32'd0;
            s_req     <= 1'b0;
        end
        else begin
            // 默认：脉冲清零（s_req 在 SERVE 里重新拉高）
            a_dval <= 1'b0;  a_done <= 1'b0;  a_err <= 1'b0;
            b_dval <= 1'b0;  b_done <= 1'b0;  b_err <= 1'b0;
            s_req  <= 1'b0;

            case (state)

                IDLE: begin
                    a_ready <= 1'b1;
                    b_ready <= !i_b_hold;   // 高水位停流：B 停在 S_ISSUE 不发请求
                    if (a_req || b_req) begin
                        // 同一拍双请求：音频(B)优先，图像(A)排队
                        if (a_req && b_req) begin
                            owner      <= 1'b1;
                            lba_cur    <= b_lba;
                            pending    <= 1'b1;
                            pend_which <= 1'b0;
                            pend_lba   <= a_lba;
                            state      <= SERVE;
                        end
                        else if (b_req) begin
                            owner   <= 1'b1;
                            lba_cur <= b_lba;
                            state   <= SERVE;
                        end
                        else begin
                            owner   <= 1'b0;
                            lba_cur <= a_lba;
                            state   <= SERVE;
                        end
                    end
                end

                SERVE: begin
                    a_ready <= 1'b0;
                    b_ready <= 1'b0;
                    s_lba   <= lba_cur;
                    s_req   <= 1'b1;            // 保持到 sd_spi 采样（s_ready && s_req）

                    if (owner) begin
                        // ---- 服务 B（音频）；监听 A 的迟到请求 ----
                        if (a_req && !pending) begin
                            pending    <= 1'b1;
                            pend_which <= 1'b0;
                            pend_lba   <= a_lba;
                        end
                        b_data <= s_data;
                        b_dval <= s_dval;
                        if (s_done) begin
                            b_done <= 1'b1;
                            if (pending) begin
                                owner   <= pend_which;
                                lba_cur <= pend_lba;
                                s_lba   <= pend_lba;  // 同拍换 s_lba：sd_spi 回到
                                pending <= 1'b0;      // READY 后 ~1 拍即采样，晚一
                            end                     // 拍更新会被陈旧 lba 接受
                            else begin
                                state <= IDLE;
                                s_req <= 1'b0;  // 同拍撤请求：防止 IDLE 首拍
                            end                 // 被 sd_spi 以过期 s_lba 接受
                        end
                        else if (s_err) begin
                            b_err <= 1'b1;
                            if (pending) begin
                                owner   <= pend_which;
                                lba_cur <= pend_lba;
                                s_lba   <= pend_lba;  // 同拍换 s_lba：sd_spi 回到
                                pending <= 1'b0;      // READY 后 ~1 拍即采样，晚一
                            end                     // 拍更新会被陈旧 lba 接受
                            else begin
                                state <= IDLE;
                                s_req <= 1'b0;  // 同上（错误出口也要撤）
                            end
                        end
                    end
                    else begin
                        // ---- 服务 A（图像）；监听 B 的迟到请求 ----
                        if (b_req && !pending) begin
                            pending    <= 1'b1;
                            pend_which <= 1'b1;
                            pend_lba   <= b_lba;
                        end
                        a_data <= s_data;
                        a_dval <= s_dval;
                        if (s_done) begin
                            a_done <= 1'b1;
                            if (pending) begin
                                owner   <= pend_which;
                                lba_cur <= pend_lba;
                                s_lba   <= pend_lba;  // 同拍换 s_lba：sd_spi 回到
                                pending <= 1'b0;      // READY 后 ~1 拍即采样，晚一
                            end                     // 拍更新会被陈旧 lba 接受
                            else begin
                                state <= IDLE;
                                s_req <= 1'b0;  // 同拍撤请求（见上）
                            end
                        end
                        else if (s_err) begin
                            a_err <= 1'b1;
                            if (pending) begin
                                owner   <= pend_which;
                                lba_cur <= pend_lba;
                                s_lba   <= pend_lba;  // 同拍换 s_lba：sd_spi 回到
                                pending <= 1'b0;      // READY 后 ~1 拍即采样，晚一
                            end                     // 拍更新会被陈旧 lba 接受
                            else begin
                                state <= IDLE;
                                s_req <= 1'b0;  // 同上（错误出口也要撤）
                            end
                        end
                    end
                end

                default: state <= IDLE;
            endcase
        end
    end

endmodule
