#!/usr/bin/env python3
# sd_card_bmp 双副本：播放列表转储 FSM（'L' 调试命令）
for path in ['board/user_source/hdl_source/SD/sd_card_bmp.v', 'boardtest/vsrc/sd_card_bmp.v']:
    c = open(path, encoding='utf-8').read()
    def rep(old, new, tag):
        global c
        assert old in c, f"{path}:{tag}"
        c = c.replace(old, new, 1)

    # 1) 端口（紧跟 o_wr_vrow_off 之后）
    import re
    m = re.search(r'(    output \[19:0\] *o_wr_vrow_off[^\n]*\n)', c)
    assert m, f"{path}:port"
    add = """    // ---- 播放列表转储（'L' 调试命令）：每条目 2 包（0x5C 名字+wav /
    //      0x5D nxt+prv），末包 0x5E 汇总（first/各计数）。节流 2 万拍/包
    //      （> 1Mbaud 发一包的时长），PC 端按类型解码还原整张环表
    input                       i_pl_dump_start,
    output reg  [63:0]          o_pl_dump_pkt,
    output reg                  o_pl_dump_val,
"""
    c = c.replace(m.group(1), m.group(1) + add, 1)

    # 2) 转储 FSM（追加在文件末尾 endmodule 之前）
    m2 = re.search(r'(\nendmodule\s*)$', c)
    assert m2, f"{path}:endmodule"
    fsm = """
    // ==================== 播放列表转储 FSM（'L' 调试命令）====================
    // 读 npass 快照 pl_names/pl_iswav_map + fat32_ro 建的 nxt/prv/first 环表，
    // 每条目 2 包 + 汇总 1 包，经 ctrl_core 的 tx mux → UART 发出。
    // 用途：板上真实 FAT 目录的调试观测（串口 'L' 触发，PC 端解码打印）。
    reg  [1:0]  pd_st;         // 0 空闲 1 发 5C 2 发 5D 3 发 5E
    reg  [5:0]  pd_k;
    reg  [15:0] pd_wait;
    reg  [63:0] pd_pkt;
    reg         pd_v;
    wire [7:0]  pd_n0 = pl_names[pd_k[4:0]][7:0];
    wire [7:0]  pd_n1 = pl_names[pd_k[4:0]][15:8];
    wire [7:0]  pd_n2 = pl_names[pd_k[4:0]][23:16];
    wire [7:0]  pd_n3 = pl_names[pd_k[4:0]][31:24];
    wire [7:0]  pd_n4 = pl_names[pd_k[4:0]][39:32];
    wire [7:0]  pd_n5 = pl_names[pd_k[4:0]][47:40];
    wire [7:0]  pd_n6 = pl_names[pd_k[4:0]][55:48];
    wire [7:0]  pd_n7 = pl_names[pd_k[4:0]][63:56];
    wire [5:0]  pd_nxt = bmp_nxt_map[6*pd_k[4:0] +: 6];
    wire [5:0]  pd_prv = bmp_prv_map[6*pd_k[4:0] +: 6];
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            pd_st <= 2'd0; pd_k <= 6'd0; pd_wait <= 16'd0;
            pd_pkt <= 64'd0; pd_v <= 1'b0;
        end
        else begin
            pd_v <= 1'b0;
            if (i_pl_dump_start && pd_st == 2'd0 && !load_busy) begin
                pd_st <= 2'd1; pd_k <= 6'd0; pd_wait <= 16'd0;
            end
            else if (pd_st != 2'd0) begin
                if (pd_wait != 16'd0) begin
                    pd_wait <= pd_wait - 1'b1;
                end
                else if (pd_st == 2'd1) begin
                    pd_pkt <= {8'h00, pl_iswav_map[pd_k[4:0]], pd_n4, pd_n3,
                               pd_n2, pd_n1, pd_n0, 8'h5C};
                    pd_v   <= 1'b1;
                    pd_st  <= 2'd2;
                    pd_wait<= 16'd20000;
                end
                else if (pd_st == 2'd2) begin
                    pd_pkt <= {8'h00, 8'h00, pd_nxt, pd_prv, pd_n7, pd_n6,
                               pd_n5, 8'h5D};
                    pd_v   <= 1'b1;
                    pd_k   <= pd_k + 1'b1;
                    pd_st  <= (pd_k + 1'b1 >= file_cnt) ? 2'd3 : 2'd1;
                    pd_wait<= 16'd20000;
                end
                else begin // 2'd3 汇总包
                    pd_pkt <= {8'h00, 8'h00, 8'h00, wav_cnt, bmp_cnt,
                               file_cnt, first_bmp_w, 8'h5E};
                    pd_v   <= 1'b1;
                    pd_st  <= 2'd0;
                end
            end
        end
    end
    assign o_pl_dump_pkt = pd_pkt;
    assign o_pl_dump_val = pd_v;
"""
    c = c.replace(m2.group(1), fsm + m2.group(1), 1)
    open(path, 'w', encoding='utf-8').write(c)
    print(path, 'ok')
