// tb_readeng.v — frame_fifo_write / frame_fifo_read 修复的独立自检测试台
//
// 背景（2026-09-27 板级两连 bug；boardtest 主仿真用 C++ 模型替代这两个引擎，
// 两类 bug 都不可见，故补真实 RTL 级测试）：
//   fix A（frame_fifo_write）：WRITE_V_FLIP 曾对音频通道（index 2/3）也生效，
//     音频字被按 640 字行块倒排打散 → 播放噪声。修复后仅 index 0/1 翻转。
//   fix B（frame_fifo_read）：音频整段读被 512 字 FIFO 节流拉长到秒级，
//     视频按帧抢占音频会话后上下文丢失（地址/计数/长度被覆写）且请求已撤，
//     会话永不恢复 → 每段 ~30ms 声音后永久静音。修复后快照+自动续读。
//
// 桩：行为级 FIFO（re 下一拍 dout 更新并保持；清=计数归零）+
//     SDRAM 读桩（App_rd_en 每拍锁地址，2 拍后按序返回，数据=地址本身，
//     顺序校验直接看 dout 序列）+ SDRAM 写阵列（延迟一拍对齐落址）。
`timescale 1ns/1ps
module tb_readeng;
    localparam ADDR_BITS = 21;
    localparam BURST     = 16;
    localparam DEPTH     = 512;
    // 720p 布局：视频 A/B 各 460800 字，音频 A/B 各 587776 字
    localparam integer BUF0 = 0, BUF1 = 460800, BUF2 = 921600, BUF3 = 1509376;

    reg clk = 0;
    always #5 clk = ~clk;
    reg rst = 1;
    integer cyc = 0;
    always @(posedge clk) cyc = cyc + 1;
    integer errors = 0;

    // ================= DUT 接线 =================
    wire        app_rd_en;
    wire [ADDR_BITS-1:0] app_rd_addr;
    reg         sdr_rd_en = 0;
    reg [31:0]  sdr_rd_dout;
    wire        app_wr_en;
    wire [ADDR_BITS-1:0] app_wr_addr;
    wire [31:0] app_wr_din;

    reg         v_req = 0, a_req = 0;
    wire        v_ack, a_ack, v_fin, a_fin;
    reg  [ADDR_BITS-1:0] v_len, a_len;
    reg  [1:0]  v_idx, a_idx;
    reg         v_re = 0, a_re = 0;
    wire [31:0] v_dout, a_dout;
    wire [9:0]  v_wrusedw, a_wrusedw;
    wire        v_aclr, a_aclr, a_ch_act;

    frame_fifo_read #(.BURST_SIZE(BURST)) u_rd (
        .rst(rst), .mem_clk(clk), .Sdr_init_done(1'b1), .Sdr_init_ref_vld(1'b1),
        .Sdr_busy(1'b0), .Sdr_rd_en(sdr_rd_en), .App_wr_busy(1'b0),
        .O_rd_busy(), .App_rd_en(app_rd_en), .App_rd_addr(app_rd_addr),
        .read_req(v_req), .read_req_ack(v_ack), .read_finish(v_fin),
        .read_addr_0(BUF0[ADDR_BITS-1:0]), .read_addr_1(BUF1[ADDR_BITS-1:0]),
        .read_addr_2(BUF2[ADDR_BITS-1:0]), .read_addr_3(BUF3[ADDR_BITS-1:0]),
        .read_addr_index(v_idx), .read_len(v_len), .fifo_aclr(v_aclr),
        .wrusedw(v_wrusedw),
        .aud_read_req(a_req), .aud_read_req_ack(a_ack), .aud_read_finish(a_fin),
        .aud_read_addr_index(a_idx), .aud_read_len(a_len), .aud_fifo_aclr(a_aclr),
        .aud_wrusedw(a_wrusedw), .aud_ch_active(a_ch_act)
    );

    reg         wr_req = 0, wr_go = 0, wr_active = 0;
    wire        wr_ack, wr_fin;
    reg  [1:0]  wr_idx;
    reg  [ADDR_BITS-1:0] wr_len;
    reg  signed [19:0]   vrow_off = 20'sd0;   // 信箱行偏移（T2b）
    wire [31:0] wr_data_tb;
    wire [9:0]  w_usedw;
    wire        w_aclr;

    frame_fifo_write #(.BURST_SIZE(BURST), .FRAME_WIDTH(640), .FRAME_HEIGHT(720)) u_wr (
        .rst(rst), .mem_clk(clk), .Sdr_init_done(1'b1), .Sdr_init_ref_vld(1'b1),
        .Sdr_busy(1'b0), .App_rd_busy(1'b0), .O_wr_busy(),
        .App_wr_en(app_wr_en), .App_wr_addr(app_wr_addr),
        .write_req(wr_req), .write_req_ack(wr_ack), .write_finish(wr_fin),
        .write_addr_0(BUF0[ADDR_BITS-1:0]), .write_addr_1(BUF1[ADDR_BITS-1:0]),
        .write_addr_2(BUF2[ADDR_BITS-1:0]), .write_addr_3(BUF3[ADDR_BITS-1:0]),
        .write_addr_index(wr_idx), .write_len(wr_len), .vrow_off(vrow_off),
        .fifo_aclr(w_aclr), .rdusedw(w_usedw)
    );

    // ================= 行为级 FIFO =================
    reg [31:0] vmem [0:DEPTH-1]; integer vw = 0, vr = 0;
    reg [31:0] amem [0:DEPTH-1]; integer aw = 0, ar = 0;
    reg [31:0] wmem [0:DEPTH-1]; integer ww = 0, wrr = 0;
    reg [31:0] v_dout_r, a_dout_r;
    reg        v_pop_d = 0, a_pop_d = 0;

    // 读侧弹出：re 下一拍 dout 更新并保持（设计假设的 FIFO 语义）
    always @(posedge clk) begin
        if (rst) begin
            vw <= 0; vr <= 0; aw <= 0; ar <= 0; ww <= 0; wrr <= 0;
            v_dout_r <= 0; a_dout_r <= 0;
        end else begin
            if (v_aclr) begin vw <= 0; vr <= 0; end
            if (a_aclr) begin aw <= 0; ar <= 0; end
            // FIFO 写侧（引擎读回的数据按通道入队）
            if (sdr_rd_en && !a_ch_act) begin vmem[vw % DEPTH] <= sdr_rd_dout; vw <= vw + 1; end
            if (sdr_rd_en &&  a_ch_act) begin amem[aw % DEPTH] <= sdr_rd_dout; aw <= aw + 1; end
            // 弹出与校验解耦：dout 在弹出后一拍有效，逐拍比对
            if (v_re && vr < vw) begin v_dout_r <= vmem[vr % DEPTH]; vr <= vr + 1; end
            v_pop_d <= v_re && (vr < vw);
            if (v_pop_d) begin
                if (v_dout !== v_expect) begin
                    errors = errors + 1;
                    $display("FAIL cyc=%0d: video dout=%0d exp=%0d", cyc, v_dout, v_expect);
                end
                v_expect <= v_expect + 1;
            end
            if (a_re && ar < aw) begin a_dout_r <= amem[ar % DEPTH]; ar <= ar + 1; end
            a_pop_d <= a_re && (ar < aw);
            if (a_pop_d) begin
                if (a_dout !== a_expect) begin
                    errors = errors + 1;
                    $display("FAIL cyc=%0d: audio dout=%0d exp=%0d", cyc, a_dout, a_expect);
                end
                a_expect = a_expect + 1;
                a_got = a_got + 1;
            end
        end
    end

    assign v_dout = v_dout_r;
    assign a_dout = a_dout_r;
    assign v_wrusedw = (vw >= vr) ? (vw - vr) : 0;
    assign a_wrusedw = (aw >= ar) ? (aw - ar) : 0;

    // 写 FIFO：写侧推（对齐 wr_en_tb/wr_data_tb），读侧弹出（延迟一拍落 SDRAM）
    reg [31:0] app_din_r;
    reg        app_wr_d;
    reg [ADDR_BITS-1:0] app_wa_d;
    always @(posedge clk) begin
        if (rst) begin
            ww <= 0; wrr <= 0; app_din_r <= 0; app_wr_d <= 0;
        end else begin
            if (w_aclr) begin ww <= 0; wrr <= 0; end
            if (wr_en_tb && ww - wrr < DEPTH) begin
                wmem[ww % DEPTH] <= wr_data_tb; ww <= ww + 1;
            end
            if (app_wr_en && wrr < ww) begin
                app_din_r <= wmem[wrr % DEPTH]; wrr <= wrr + 1;
            end
            app_wr_d <= app_wr_en;
            app_wa_d <= app_wr_addr;
            if (app_wr_d) sdram[app_wa_d] <= app_din_r;
        end
    end
    assign w_usedw = (ww >= wrr) ? (ww - wrr) : 0;

    // ================= SDRAM 读桩：数据=地址，2 拍延迟按序返回 =================
    reg [ADDR_BITS-1:0] q0, q1;
    reg v0, v1;
    always @(posedge clk) begin
        if (rst) begin v0 <= 0; v1 <= 0; sdr_rd_en <= 0; end
        else begin
            v0 <= app_rd_en; q0 <= app_rd_addr;
            v1 <= v0;        q1 <= q0;
            sdr_rd_en   <= v1;
            sdr_rd_dout <= {11'b0, q1};
        end
    end

    // ================= SDRAM 阵列 =================
    reg [31:0] sdram [0:(1<<21)-1];

    // ================= 写驱动 =================
    integer wr_sent = 0, wr_total = 0;
    reg wr_en_r = 0;
    integer wr_gap = 0, wr_gap_cnt = 0;   // 0=密集（原行为）；>0=每 wr_gap 拍注 1 字（稀疏）
    assign wr_data_tb = wr_sent[31:0];
    assign wr_en_tb = wr_en_r;
    always @(posedge clk) begin
        if (rst) begin
            wr_req <= 0; wr_en_r <= 0; wr_sent <= 0; wr_gap_cnt <= 0;
        end else begin
            if (wr_go) begin wr_req <= 1; wr_go <= 0; end
            if (wr_req && wr_ack) wr_req <= 0;
            if (wr_gap == 0) begin
                wr_en_r <= wr_active && (wr_sent < wr_total);
            end else begin
                // 稀疏注入：模拟图像发射器的真实节奏（字间大空泡）
                if (wr_gap_cnt == 0) begin
                    wr_en_r    <= wr_active && (wr_sent < wr_total);
                    wr_gap_cnt <= wr_gap;
                end else begin
                    wr_en_r    <= 0;
                    wr_gap_cnt <= wr_gap_cnt - 1;
                end
            end
            if (wr_en_r) wr_sent <= wr_sent + 1;
        end
    end

    // ================= 视频流量发生器（抢占源，gen_en 控制）=================
    integer v_expect = 0;
    integer vid_period = 300;
    reg gen_en = 0, v_trig = 0, v_started = 0;
    integer vid_cnt = 0;
    always @(posedge clk) begin
        if (rst) begin
            v_req <= 0; v_re <= 0; v_trig <= 0; vid_cnt <= 0; v_fin_d <= 0;
        end else begin
            v_fin_d <= v_fin;
            if (gen_en && !v_req && (v_fin_d || !v_started) && vid_cnt >= vid_period) begin
                v_trig <= 1; vid_cnt <= 0; v_started <= 1;
            end else begin
                vid_cnt <= vid_cnt + 1;
                v_trig <= 0;
            end
            if (v_trig) begin
                v_req <= 1; v_len <= 2048; v_idx <= 0; v_expect <= BUF0;
            end
            if (v_req && v_ack) v_req <= 0;
            v_re <= (!v_req && (vr < vw));
        end
    end
    reg v_fin_d = 0;

    // 音频消费（T3/T4 用慢速：每 8 拍取一字，逼出 FIFO 节流与抢占）
    integer a_expect = 0, a_got = 0;
    wire wr_en_tb;
    integer a_pace = 0;
    reg slow = 1;
    always @(posedge clk) begin
        if (rst) begin
            a_re <= 0; a_pace <= 0;
        end else begin
            if (!slow) begin
                a_re <= (ar < aw);
            end else begin
                a_pace <= a_pace + 1;
                a_re <= (a_pace >= 7) && (ar < aw);
                if (a_pace >= 7) a_pace <= 0;
            end
        end
    end

    // ================= 校验辅助 =================
    integer a_exp_base;
    reg a_fin_d = 0;
    integer a_len_cur = 0;

    always @(posedge clk) begin
        if (!rst) begin
            a_fin_d <= a_fin;
            if (a_fin && !a_fin_d)
                $display("  [info] audio engine finish at cyc=%0d (consumed %0d/%0d)",
                         cyc, a_got, a_len_cur);
        end
    end

    // 调试监视：T3/T4 期间每 20000 拍打印音频通道状态
    reg dbg = 0;
    always @(posedge clk) begin
        if (dbg && (cyc % 2000 == 0))
            $display("[dbg] cyc=%0d st=%0d ch=%b vreq=%b areq=%b ack_v=%b ack_a=%b vfin=%b afin=%b aw=%0d vw=%0d rdl=%0d bc=%0d enr=%b dly=%0d rd_en=%b ra=%0d sre=%b v0=%b v1=%b",
                     cyc, u_rd.state, u_rd.cur_ch, v_req, a_req, v_ack, a_ack,
                     v_fin, a_fin, aw, vw, u_rd.read_len_latch,
                     u_rd.burst_cnt, u_rd.App_rd_en_r, u_rd.rd_delay,
                     app_rd_en, app_rd_addr, sdr_rd_en, v0, v1);
    end

    task fail_msg(input [255:0] m);
        begin
            errors = errors + 1;
            $display("FAIL cyc=%0d: %0s", cyc, m);
        end
    endtask

    // ================= 主序列 =================
    integer i, t;
    initial begin
        v_idx = 0; a_idx = 2; v_len = 0; a_len = 0;
        wr_idx = 0; wr_len = 0;
        repeat (10) @(posedge clk);
        rst = 0;
        repeat (5) @(posedge clk);

        // ---- T1: 音频写（idx=2）必须顺序落址（fix A）----
        wr_idx = 2; wr_len = 64; wr_total = 64; wr_sent = 0; wr_active = 1; wr_go = 1;
        t = 0; while (!wr_fin && t < 100000) begin @(posedge clk); t = t + 1; end
        wr_active = 0;
        if (!wr_fin) fail_msg("T1 write timeout");
        repeat (20) @(posedge clk);
        for (i = 0; i < 64; i = i + 1)
            if (sdram[BUF2 + i] !== i[31:0]) fail_msg("T1 audio write not sequential");
        $display("T1 audio write sequential (no vflip): PASS");

        // ---- T2: 图像写（idx=0）必须仍翻转 ----
        wr_idx = 0; wr_len = 64; wr_total = 64; wr_sent = 0; wr_active = 1; wr_go = 1;
        t = 0; while (!wr_fin && t < 100000) begin @(posedge clk); t = t + 1; end
        wr_active = 0;
        if (!wr_fin) fail_msg("T2 write timeout");
        repeat (20) @(posedge clk);
        for (i = 0; i < 64; i = i + 1)
            if (sdram[BUF0 + 719*640 + i] !== i[31:0]) fail_msg("T2 image flip lost");
        $display("T2 image write vflip kept: PASS");

        // ---- T2b: 信箱行偏移（多分辨率）：vrow_off=-120 字（480 行图像居中）----
        // 64 字会话应落在 BUF0+(719-120)*640 = BUF0+599*640（首流行=图像底行）
        vrow_off = -20'sd76800;   // -120 行 × 640 字/行（单位=字，与 sd_card_bmp 一致）
        wr_idx = 0; wr_len = 64; wr_total = 64; wr_sent = 0; wr_active = 1; wr_go = 1;
        t = 0;
        while (!wr_fin && t < 100000) begin
            @(posedge clk); t = t + 1;
        end
        wr_active = 0; vrow_off = 20'sd0;
        if (!wr_fin) fail_msg("T2b write timeout");
        repeat (20) @(posedge clk);
        for (i = 0; i < 64; i = i + 1)
            if (sdram[BUF0 + 599*640 + i] !== i[31:0]) fail_msg("T2b row offset misplaced");
        if (sdram[BUF0 + 719*640] !== 32'h5a5a5a5a && sdram[BUF0 + 719*640] === 32'hxxxx_xxxx)
            fail_msg("T2b sdram x");
        $display("T2b mailbox row offset (vflip+off): PASS");

        // ---- T3: 音频整段读 + 视频频繁抢占（fix B 核心）----
        gen_en = 1; dbg = 1;
        a_idx = 2; a_len = 1024; a_len_cur = 1024; a_exp_base = BUF2; a_expect = BUF2; a_got = 0;
        a_req = 1;
        t = 0;
        while (a_got < 1024 && t < 400000) begin
            @(posedge clk); t = t + 1;
            if (a_req && a_ack) a_req = 0;
        end
        a_req = 0;
        repeat (50) @(posedge clk);
        if (a_got != 1024) fail_msg("T3 audio length mismatch");
        else $display("T3 audio session survives preemption: PASS (%0d words, cyc=%0d)", a_got, t);

        // ---- T4: 循环重读（第二次请求 = 全新会话，idx=3 走 BUF3）----
        a_idx = 3; a_len = 1024; a_len_cur = 1024; a_expect = BUF3; a_got = 0;
        a_req = 1;
        t = 0;
        while (a_got < 1024 && t < 400000) begin
            @(posedge clk); t = t + 1;
            if (a_req && a_ack) a_req = 0;
        end
        a_req = 0;
        repeat (50) @(posedge clk);
        if (a_got != 1024) fail_msg("T4 audio length mismatch");
        else $display("T4 audio re-request fresh session: PASS");

        // ---- T30-T33：稀疏流入尾军（2026-10-04 板级"字全发完引擎不收尾"复现）----
        // 现象：图像会话（稀疏流）全部 3s 超时，已发射==会话长度；涂黑（密集）同长度成功。
        // 组合扫 {len, vrow_off, gap}；超时即复现，并打印引擎内部状态定位。
        begin : sparse_tail
            integer g, ln, vo, t30;
            integer lens[4]; integer vos[4]; integer gaps[4];
            lens[0]=307200; vos[0]=0;        gaps[0]=8;
            lens[1]=460800; vos[1]=0;        gaps[1]=8;
            lens[2]=307200; vos[2]=-76800;   gaps[2]=8;
            lens[3]=307200; vos[3]=-76800;   gaps[3]=192;
            for (t30 = 0; t30 < 4; t30 = t30 + 1) begin
                g = gaps[t30]; ln = lens[t30]; vo = vos[t30];
                wr_gap = g; vrow_off = vo; wr_idx = 0;
                wr_len = ln; wr_total = ln + 1; wr_sent = 0; wr_active = 1; wr_go = 1; // +1=发射器末尾填充字
                t = 0;
                while (!wr_fin && t < 80000000 + ln*g*2) begin @(posedge clk); t = t + 1; end
                wr_active = 0;
                if (!wr_fin) begin
                    fail_msg("T3x sparse write timeout");
                    $display("  [hang] len=%0d vrow_off=%0d gap=%0d: 引擎 state=%0d write_cnt=%0d burst_cnt=%0d len_latch=%0d FIFO=%0d sent=%0d",
                             ln, vo, g, u_wr.state, u_wr.write_cnt, u_wr.burst_cnt,
                             u_wr.write_len_latch, w_usedw, wr_sent);
                end else begin
                    $display("T3%d sparse (len=%0d vrow_off=%0d gap=%0d): PASS (%0d cyc, FIFO=%0d)",
                             t30, ln, vo, g, t, w_usedw);
                end
                repeat (20) @(posedge clk);
            end
            wr_gap = 0; vrow_off = 20'sd0;
        end

        gen_en = 0;
        if (errors == 0) $display("==== ALL PASS ====");
        else             $display("==== %0d FAILURES ====", errors);
        $finish;
    end

    initial begin
        #1200000000;
        $display("==== GLOBAL TIMEOUT ====");
        $finish;
    end
endmodule
