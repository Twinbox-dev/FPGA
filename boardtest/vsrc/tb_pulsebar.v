`timescale 1ns/1ps
// ---------------------------------------------------------------------------
// tb_pulsebar.v — 音频脉动条自检（2026-10-03）
//
// pulse_bar 不在主仿真覆盖内（渲染在 top 的显示通路、包络在音频出口，两者都
// 是主仿真盲区），按 video_delay/tb_vdelay 的先例补独立自检。层次引用读内部
// 状态（env/amp8），仿 tb_readeng/tb_uart 的做法。
//
// 幅度基准：drive_loud 源 = 30<<16（2^20.9）；sens=2（上电默认，shift 14）
//   → amp8 = 120（不满格，便于观察攻击/饱和/渐变各档）。
//
// 用例：
//   T1 复位态：env=0、无条
//   T2 快攻：env 每样本 +16 至 amp8=120 不超调
//   T5 条覆盖：fill=env>>2=30 行以下全亮（BAR_H=64）、=fill 白色峰值线、之上不亮
//   T6 渐变色：t=0/17/19/20 四点精确 RGB（蓝→绿→红两段线性）
//   T3 慢落：静音每 32 样本 -1
//   T4 灵敏度：sens=3 同源饱和 255；sens=0 同源只有 1
//   T8 静音足够久 env=0 → 条消失（无配对图静音路径）
//   T7 bar_en=0：条消失
// ---------------------------------------------------------------------------
module tb_pulsebar;
    localparam TCK_A = 10;      // 100MHz 音频域
    localparam TCK_V = 13;      // ~75MHz 视频域（TB 不必精确 13.32ns）

    reg               clk_a = 0, clk_v = 0, rst_a = 1, rst_v = 1;
    reg signed [27:0] aud_l = 0, aud_r = 0;
    reg               aud_val = 0;
    reg  [1:0]        sens_gray = 2'b11;   // 格雷 11 = 二进制 2（上电默认）
    reg               bar_en = 0;
    reg               de_r = 0, vs_r = 0;
    wire [23:0]       bar_rgb;
    wire              bar_hit;

    pulse_bar dut (
        .clk_a(clk_a), .rst_a(rst_a),
        .aud_l(aud_l), .aud_r(aud_r), .aud_val(aud_val),
        .sens_gray(sens_gray), .bar_en(bar_en),
        .clk_v(clk_v), .rst_v(rst_v),
        .de_r(de_r), .vs_r(vs_r),
        .bar_rgb(bar_rgb), .bar_hit(bar_hit)
    );

    always #5   clk_a = ~clk_a;
    always #6.5 clk_v = ~clk_v;

    integer errors = 0;
    reg [23:0] rgb;
    integer    hit;

    task check(input cond, input [255:0] tag);
        if (!cond) begin
            errors = errors + 1;
            $display(">>FAIL %0t %0s", $time, tag);
        end else
            $display("  PASS %0s", tag);
    endtask

    // 音频域：发一个样本有效拍（TB 加速节拍：20 clk_a）
    task aud_tick;
        begin
            aud_val = 1; #TCK_A; aud_val = 0; #(TCK_A * 19);
        end
    endtask

    // 发 N 个响样本（30<<16；sens=2 → amp8=120）
    task drive_loud(input integer n);
        integer i;
        begin
            for (i = 0; i < n; i = i + 1) begin
                aud_l = $signed(30 * 65536); aud_r = $signed(15 * 65536);
                aud_tick;
            end
        end
    endtask

    task drive_silence(input integer n);
        integer i;
        begin
            for (i = 0; i < n; i = i + 1) begin
                aud_l = 0; aud_r = 0;
                aud_tick;
            end
        end
    endtask

    // 视频域：扫一帧，在 row_fb == want 的行中段读 bar_hit/bar_rgb
    task probe_row(input integer want);
        integer r, c;
        begin
            vs_r = 1; #TCK_V; vs_r = 0; #TCK_V;
            hit = 0; rgb = 0;
            for (r = 0; r < 720; r = r + 1) begin
                de_r = 1;
                for (c = 0; c < 40; c = c + 1) begin
                    #TCK_V;
                    if ((719 - r) == want) begin hit = bar_hit; rgb = bar_rgb; end
                end
                de_r = 0;
                #(TCK_V * 10);
            end
        end
    endtask

    initial begin
        #(TCK_A * 4);
        rst_a = 0; rst_v = 0;
        #(TCK_A * 4);

        // ---------- T1 复位态 ----------
        check(dut.env == 8'd0, "T1 复位 env=0");
        bar_en = 1;
        #(TCK_A * 4);
        probe_row(0);
        check(hit == 0, "T1 复位无条（env=0 fill=0）");

        // ---------- T2 快攻 ----------
        drive_loud(3);   // 16+16+16
        check(dut.env == 8'd48, "T2 三样本攻到 48（16/样本）");
        drive_loud(6);
        check(dut.env == 8'd120, "T2 到达 amp8=120 不超调");
        check(dut.amp8 == 8'd120, "T2 amp8 = 源>>14（sens=2）");

        // ---------- T5/T6 条渲染（env=120 → fill=120>>2=30，BAR_H=64）----------
        probe_row(0);
        check(hit == 1, "T5 底行亮");
        check(rgb == 24'h00_50_FF, "T6 t=0 蓝 (0,80,255)");
        probe_row(29);
        check(hit == 1, "T5 fill-1 行亮");
        check(rgb == 24'h3A_C4_6E, "T6 t=29 (58,196,110)");
        probe_row(30);
        check(hit == 1 && rgb == 24'hFF_FF_FF, "T5 峰值线白色 @row_fb=fill");
        probe_row(31);
        check(hit == 0, "T5 fill 之上不亮");
        probe_row(63);
        check(hit == 0, "T5 条区顶高于 fill 不亮");
        probe_row(100);
        check(hit == 0, "T5 条区外不亮");

        // ---------- T6 渐变段界 ----------
        probe_row(31);
        check(rgb == 24'h3E_CC_64, "T6 t=31 段1末端 (62,204,100)");
        probe_row(32);
        check(rgb == 24'h3C_DC_50, "T6 t=32 段2起点 (60,220,80)");

        // ---------- T3 慢落（sens=2、env=120）----------
        begin
            integer e0, e1;
            e0 = dut.env;
            drive_silence(32 * 3);    // 96 样本 ≈ 3 次衰减
            e1 = dut.env;
            check(e0 - e1 >= 2 && e0 - e1 <= 4, "T3 静音慢落 ~1/32 样本");
        end

        // ---------- T4 灵敏度 ----------
        drive_silence(400);           // env 回 0
        sens_gray = 2'b10;            // 格雷 10 = 二进制 3（shift 11）
        #(TCK_A * 8);
        drive_loud(1);
        check(dut.amp8 == 8'hFF, "T4 sens=3 满幅饱和 255");
        drive_silence(4000);          // 清包络（255 满格也够落完）
        check(dut.env == 8'd0, "T4 中间清理 env=0");
        sens_gray = 2'b00;            // 二进制 0（shift 20）
        #(TCK_A * 8);
        drive_loud(1);
        check(dut.amp8 == 8'd1, "T4 sens=0 shift 20 → 1");

        // ---------- T8 衰减到 0 条消失 ----------
        drive_silence(4000);
        check(dut.env == 8'd0, "T8 静音足够久 env=0");
        bar_en = 1;
        #(TCK_A * 4);
        probe_row(0);
        check(hit == 0, "T8 env=0 无条");

        // ---------- T7 bar_en=0 ----------
        sens_gray = 2'b11;            // 回 sens=2
        #(TCK_A * 8);
        drive_loud(20);               // env 重新到 120
        bar_en = 0;
        #(TCK_A * 8);
        probe_row(0);
        check(hit == 0, "T7 bar_en=0 条消失");

        if (errors == 0) $display("==== ALL PASS ====");
        else             $display("==== %0d FAILURES ====", errors);
        $finish;
    end
endmodule
