#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
uart_console.py — PC ↔ FPGA 串口交互控制台（配板端 uart_link.v）

用法:
    python uart_console.py COM5            # Windows
    python uart_console.py /dev/ttyUSB0    # Linux/WSL
    python uart_console.py COM5 -b 1000000 # 波特率默认 1M

交互键（回车不必，单键即发）:
    n  下一张        p  上一张
    a  自动轮播开关
    +  音量+1        -  音量-1（8 档，上电=8 原始，0=静音）
    >  轮播周期+1s   <  轮播周期-1s（1..10s，上电=1s）
    ]  亮度+1        [  亮度-1（9 档，上电=4 原始 0 偏移）
    s  回读一包状态
    q  退出

状态包 8 字节: A5 | state | fat_state | flagA | flagB | underrun | img_idx | wav_flag
    flagA    = {video_pll_lock, sys_pll_lock, sdr_init_done, display_valid}
    flagB    = {hdmi_locked, fat_err, disp_buf[1:0]}
    underrun = {vid_stick, aud_stick, 2'b00}
    img_idx  = 当前图索引（5bit），wav_flag = 该图是否配同名 WAV

    vid_stick/aud_stick = 视频/音频 FIFO 欠载"历史"粘滞位（1=曾发生过）：
      * 置位条件：自复位以来，显示活动期间读 FIFO 被读空过一拍（该出像素
        的那拍没数据）。一旦置 1 保持到复位，不反映当前状态。
      * 常见误报来源：①开机首帧过渡（display_valid 刚拉高时读引擎首笔
        SDRAM 突发未落地，首帧第 2 行起短暂空一次）——已加前 4 帧稳态
        窗口屏蔽；②切图瞬间缓冲源切换的短暂停顿。
      * 真正的持续欠载才会伴随画面撕裂/花屏。画面正常 + 仅 vidUND 亮 =
        历史误报，不用管；与画面异常同时出现才是带宽问题。
依赖: pyserial（pip install pyserial）
"""
import argparse
import sys
import threading
import time

try:
    import serial
except ImportError:
    sys.exit("需要 pyserial: pip install pyserial")

# 键为小写，与 read_key() 返回的小写字符匹配
CMDS = {b"n": 0x4E, b"a": 0x41, b"s": 0x53, b"p": 0x50,
        b"+": 0x2B, b"-": 0x2D, b">": 0x3E, b"<": 0x3C,
        b"]": 0x5D, b"[": 0x5B}
HELP = {"n": "下一张", "a": "自动轮播", "s": "状态回读", "p": "上一张",
        "+": "音量+", "-": "音量-", ">": "周期+1s", "<": "周期-1s",
        "]": "亮度+", "[": "亮度-"}

running = True


def send_cmd(ser, key: bytes):
    c = CMDS[key]
    ser.write(bytes([c, c ^ 0xFF]))          # [CMD, ~CMD] 成对校验


def decode_pkt(pkt: bytes) -> str:
    _, state, fat, fa, fb, und, img, wav = pkt[:8]

    # flagA: {video_pll_lock, sys_pll_lock, sdr_init_done, display_valid}
    flags_a = ["vidPLL", "sysPLL", "SDR", "disp"]
    bits_a = [(fa >> 3) & 1, (fa >> 2) & 1, (fa >> 1) & 1, fa & 1]
    fa_s = " ".join(flags_a[i] for i in range(4) if bits_a[i])

    # flagB: {hdmi_locked, fat_err, disp_buf[1:0]}
    flags_b = ["hdmi", "fatERR"]
    bits_b = [(fb >> 3) & 1, (fb >> 2) & 1]
    fb_s = " ".join(flags_b[i] for i in range(2) if bits_b[i])

    # underrun: {vid_stick, aud_stick, 2'b00} —— 历史粘滞位，1=曾欠载过
    # （见文件头注释：开机首帧/切图瞬间的短暂空拍也会钉住，画面正常即误报，
    #  不反映当前状态，复位才清）
    flags_und = ["vidUND", "audUND"]
    bits_und = [(und >> 3) & 1, (und >> 2) & 1]
    und_s = " ".join(flags_und[i] for i in range(2) if bits_und[i])

    return (f"state=0x{state:X} fat=0x{fat:02X} buf={fb & 3} img={img & 0x1F}"
            f"{'+wav' if wav & 1 else ''} | "
            f"OK: {fa_s or '-'} {fb_s or '-'} | 异常: {und_s or '无'}")


def decode_ack(pkt: bytes) -> str:
    """ACK 应答包（5A 开头）：5A | cmd回显 | vol | period_s | img | wav | bri | 00"""
    _, cmd, vol, per, img, wav, bri = pkt[:7]
    c = {0x4E: "下一张", 0x50: "上一张", 0x41: "自动轮播",
         0x2B: "音量+", 0x2D: "音量-", 0x3E: "周期+", 0x3C: "周期-",
         0x5D: "亮度+", 0x5B: "亮度-"}.get(cmd, f"0x{cmd:02X}")
    return (f"ACK {c} | 音量={vol}/8 周期={per}s 亮度={bri}/8 "
            f"img={img & 0x1F}{'+wav' if wav & 1 else ''}")


def reader_loop(ser):
    """后台线程：持续收包（A5 状态包 / 5A ACK 应答包，各 8 字节）并解码打印。"""
    buf = bytearray()
    while running:
        try:
            chunk = ser.read(64)
        except (serial.SerialException, OSError):
            break
        if not chunk:
            continue
        buf.extend(chunk)
        while True:
            ia = buf.find(b"\xA5")
            ib = buf.find(b"\x5A")
            if ia < 0 and ib < 0:
                buf.clear()
                break
            if ia < 0:
                i = ib
            elif ib < 0:
                i = ia
            else:
                i = min(ia, ib)
            del buf[:i]
            if len(buf) < 8:
                break
            pkt = bytes(buf[:8])
            del buf[:8]
            msg = decode_pkt(pkt) if pkt[0] == 0xA5 else decode_ack(pkt)
            print(f"\r[{time.strftime('%H:%M:%S')}] {msg}\n> ", end="", flush=True)


def read_key() -> str:
    """单键即读（免回车）：Windows 用 msvcrt，POSIX 切 raw 模式。"""
    if sys.platform == "win32":
        import msvcrt
        return msvcrt.getwche().lower()
    import termios, tty
    fd = sys.stdin.fileno()
    old = termios.tcgetattr(fd)
    try:
        tty.setraw(fd)
        return sys.stdin.read(1).lower()
    finally:
        termios.tcsetattr(fd, termios.TCSADRAIN, old)


def main():
    global running
    ap = argparse.ArgumentParser(description="FPGA UART 控制台")
    ap.add_argument("port", help="串口号，如 COM5 或 /dev/ttyUSB0")
    ap.add_argument("-b", "--baud", type=int, default=1_000_000)
    args = ap.parse_args()

    ser = serial.Serial(args.port, args.baud, timeout=0.2)
    print(f"已连接 {args.port} @ {args.baud}bps（8N1）。"
          f"按键: {'/'.join(HELP)}，q 退出")
    print("提示: 按 s 回读状态\n> ", end="", flush=True)

    t = threading.Thread(target=reader_loop, args=(ser,), daemon=True)
    t.start()

    try:
        while True:
            k = read_key()
            if k in ("q", "\x03"):
                break
            if k in HELP:
                send_cmd(ser, k.encode())
                print(f"\n已发送 {k}（{HELP[k]}）\n> ", end="", flush=True)
    except KeyboardInterrupt:
        pass
    finally:
        running = False
        ser.close()
        print("\n已断开")


if __name__ == "__main__":
    main()