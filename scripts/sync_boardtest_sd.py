#!/usr/bin/env python3
"""从 board 副本重建 boardtest 的 sd_card_bmp.v 副本。
boardtest 副本 = board 副本 + SIM_FAST 增量（端口/SD 层二选一/1ms 去抖）
                           + DIAG 探针 public_flat_rd 标注。
用法: python3 scripts/sync_boardtest_sd.py   （在仓库根目录跑）
"""
import re, sys

BOARD = 'board/user_source/hdl_source/SD/sd_card_bmp.v'
BT    = 'boardtest/vsrc/sd_card_bmp.v'

src = open(BOARD, newline='').read()
crlf = '\r\n' in src
nl = '\r\n' if crlf else '\n'
s = src.replace('\r\n', '\n')

# ---- 1. SIM_FAST 端口（SD_MISO 是端口列表最后一项）----
old = "    input                       SD_MISO\n);"
assert old in s, "SD_MISO 端口锚点未找到"
s = s.replace(old, (
    "    input                       SD_MISO,\n"
    "\n"
    "    // ---- SIM_FAST 直连扇区服务器（fast_en=1 选中，见 stub_sd_card_top.v）----\n"
    "    input                       fast_en,\n"
    "    input                [7:0]  fast_byte,\n"
    "    input                       fast_val,\n"
    "    output               [31:0] fast_lba,\n"
    "    output                [9:0] fast_idx,\n"
    "    output                      fast_serving\n"
    ");"))

# ---- 2. SD 层二选一（直连扇区服务器 / 引脚级 SPI）----
old = ("    // SD SPI 层（板上已验证，原样保留）\n"
       "    sd_card_top sd_card_top_m0 (\n"
       "        .clk                    (clk),\n"
       "        .rst                    (rst),\n"
       "        .SD_nCS                 (SD_nCS),\n"
       "        .SD_DCLK                (SD_DCLK),\n"
       "        .SD_MOSI                (SD_MOSI),\n"
       "        .SD_MISO                (SD_MISO),\n"
       "        .sd_init_done           (sd_init_done),\n"
       "        .sd_sec_read            (sd_sec_read),\n"
       "        .sd_sec_read_addr       (sd_sec_read_addr),\n"
       "        .sd_sec_read_data       (sd_sec_read_data),\n"
       "        .sd_sec_read_data_valid (sd_sec_read_data_valid),\n"
       "        .sd_sec_read_end        (sd_sec_read_end),\n"
       "        .sd_sec_write           (1'b0),\n"
       "        .sd_sec_write_addr      (32'd0),\n"
       "        .sd_sec_write_data      (8'd0),\n"
       "        .sd_sec_write_data_req  (),\n"
       "        .sd_sec_write_end       ()\n"
       "    );\n")
assert old in s, "sd_card_top 实例锚点未找到"
new = ("    // SD 层二选一：默认引脚级（stub_sd_card_top：协议翻译 + sd_spi + 卡模型，\n"
       "    // 板上已验证原样保留）；fast_en=1（SIM_FAST）走直连扇区服务器，\n"
       "    // SPI 栈退出仿真覆盖（排查可疑 bug 时先用默认档排除 SPI 因素）\n"
       "    wire        sd_init_slow, sec_dval_slow, sec_end_slow, sd_init_fast;\n"
       "    wire        sec_dval_fast, sec_end_fast;\n"
       "    wire [7:0]  sec_data_slow, sec_data_fast;\n"
       "    wire        sec_read_slow = sd_sec_read & ~fast_en;\n"
       "    wire        sec_read_fast = sd_sec_read &  fast_en;\n"
       "\n"
       "    sd_card_top sd_card_top_m0 (\n"
       "        .clk                    (clk),\n"
       "        .rst                    (rst),\n"
       "        .SD_nCS                 (SD_nCS),\n"
       "        .SD_DCLK                (SD_DCLK),\n"
       "        .SD_MOSI                (SD_MOSI),\n"
       "        .SD_MISO                (SD_MISO),\n"
       "        .sd_init_done           (sd_init_slow),\n"
       "        .sd_sec_read            (sec_read_slow),\n"
       "        .sd_sec_read_addr       (sd_sec_read_addr),\n"
       "        .sd_sec_read_data       (sec_data_slow),\n"
       "        .sd_sec_read_data_valid (sec_dval_slow),\n"
       "        .sd_sec_read_end        (sec_end_slow),\n"
       "        .sd_sec_write           (1'b0),\n"
       "        .sd_sec_write_addr      (32'd0),\n"
       "        .sd_sec_write_data      (8'd0),\n"
       "        .sd_sec_write_data_req  (),\n"
       "        .sd_sec_write_end       ()\n"
       "    );\n"
       "\n"
       "    fast_sd_stub u_fast_sd (\n"
       "        .clk                    (clk),\n"
       "        .rst                    (rst),\n"
       "        .sd_init_done           (sd_init_fast),\n"
       "        .fast_byte              (fast_byte),\n"
       "        .fast_val               (fast_val),\n"
       "        .fast_lba               (fast_lba),\n"
       "        .fast_idx               (fast_idx),\n"
       "        .fast_serving           (fast_serving),\n"
       "        .sd_sec_read            (sec_read_fast),\n"
       "        .sd_sec_read_addr       (sd_sec_read_addr),\n"
       "        .sd_sec_read_data       (sec_data_fast),\n"
       "        .sd_sec_read_data_valid (sec_dval_fast),\n"
       "        .sd_sec_read_end        (sec_end_fast)\n"
       "    );\n"
       "\n"
       "    assign sd_init_done           = fast_en ? sd_init_fast  : sd_init_slow;\n"
       "    assign sd_sec_read_data       = fast_en ? sec_data_fast : sec_data_slow;\n"
       "    assign sd_sec_read_data_valid = fast_en ? sec_dval_fast : sec_dval_slow;\n"
       "    assign sd_sec_read_end        = fast_en ? sec_end_fast  : sec_end_slow;\n")
s = s.replace(old, new)

# ---- 3. 仿真 1ms 去抖（boardtest 专属 ifdef）----
for k in ('next', 'auto', 'prev'):
    old = (f"    key_press_debounce #(.CLK_FREQ_HZ(CLK_FREQ_HZ), .DEBOUNCE_MS(50)) "
           f"u_key_{k} (")
    assert old in s, f"去抖锚点 u_key_{k} 未找到"
    cmt = ("   // 仿真加速：1ms 去抖（板级 50ms；去抖逻辑本身仍被完整遍历）"
           if k == 'next' else "")
    s = s.replace(old,
                  "`ifdef VERILATOR" + cmt + "\n"
                  "    key_press_debounce #(.CLK_FREQ_HZ(CLK_FREQ_HZ), .DEBOUNCE_MS(1)) "
                  f"u_key_{k} (\n"
                  "`else\n" + old + "\n`endif")

# ---- 4. DIAG 探针 public_flat_rd 标注 ----
NAMES = ['load_idx', 'aud_req_idx', 'pstate', 'plstate', 'pb_len',
         'ch_open', 'ch_closed', 'rd_outst', 'have_cur', 'have_nxt',
         'cur_word', 'nxt_word', 'byte_pos', 'phase', 'pair_valid', 'pair_wav',
         'ald_active', 'ald_wav_idx', 'aud_cmt_valid', 'aud_cmt_taken',
         'ald_boot_done', 'aud_scan_active', 'aud_scan_done_r', 'fat_err',
         'fill_active', 'first_bmp_w', 'first_idx_captured', 'ld_state',
         'load_busy', 'next_req_pending', 'prev_req_pending',
         'write_req_r', 'aud_wr_req', 'img_w_dec', 'img_h_dec', 'img_hdr_ok_dec',
         'img_err', 'img_ok', 'file_idx', 'ald_active']
lines = s.split('\n')
done_stmt = set()
n_ann = 0
for i, ln in enumerate(lines):
    if 'public_flat_rd' in ln or re.match(r'\s*(reg|wire)\b', ln) is None:
        continue
    for nm in NAMES:
        if re.search(r'\b' + nm + r'\b', ln) and ';' in ln \
                and '=' not in ln[:ln.index(';')] \
                and id(ln) not in done_stmt:
            j = ln.index(';')
            lines[i] = ln[:j] + ' /*verilator public_flat_rd*/' + ln[j:]
            done_stmt.add(id(lines[i]))
            n_ann += 1
            break
s = '\n'.join(lines)

missing = [nm for nm in NAMES
           if not any(nm in l and 'public_flat_rd' in l for l in lines)]
if missing:
    print('警告：未标注的探针信号：', missing)

out = s.replace('\n', nl) if crlf else s
open(BT, 'w', newline='').write(out)
print(f'OK: 写出 {BT}（CRLF={crlf}，标注 {n_ann} 处）')
