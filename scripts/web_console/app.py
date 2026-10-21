#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
web_console/app.py — 板卡控制 Web 控制台（串口 / 以太网双控）

用法:
    python app.py                    # 启动服务，串口自动识别（唯一串口直接连上）
    WEB_LOOPBACK=1 python app.py     # 无板卡开发档（命令回环成假 ACK）
    WEB_NOAUTO=1 python app.py       # 关掉「唯一串口自动连接」，只自动选中不连
    浏览器打开 http://127.0.0.1:5000

架构（与 FPGA 侧 ctrl_core 分层呼应）:
    浏览器 ──HTTP POST /api/cmd──► Flask ── Transport ──► 板卡
             ◄──SSE /api/stream── │   serial: pyserial（现） │
                                  │   eth:   UDP socket       │
    传输只认「协议字节」；协议解码在本文件内（原 uart_console.py 已并入并删除，
    本控制台是唯一的 PC 端工具）。

串口选择策略（新增）:
    1. 启动时 / 点刷新时枚举串口（serial.tools.list_ports）；
    2. 只有一个 → 自动选中并自动连接（WEB_NOAUTO=1 可只选中不连）；
    3. 多个     → 自动选中第一个（USB 串口优先），其余在下拉里手动切。

注意: 串口独占——打开本控制台前请关掉其他占用串口的程序。
依赖: pip install flask pyserial
"""
import json
import os
import queue
import struct
import sys
import threading
import time

from flask import Flask, Response, jsonify, render_template, request

app = Flask(__name__)
sys.setswitchinterval(0.0005)   # GIL 快速切换：流帧突发期读线程不容许毫秒级停顿（默认 5ms > 64KB 内核缓冲的 1.7ms 吸收窗）

DEFAULT_BAUD = int(os.environ.get("WEB_BAUD", "1000000"))   # 默认波特率
AUTO_CONNECT = not os.environ.get("WEB_NOAUTO")             # 唯一串口是否自动连

# ---------------------------------------------------------------------------
# 协议（原 uart_console.py 并入）：命令表 + 两类包解码
# ---------------------------------------------------------------------------
CMDS = {"n": 0x4E, "a": 0x41, "s": 0x53, "p": 0x50,
        "+": 0x2B, "-": 0x2D, ">": 0x3E, "<": 0x3C,
        "]": 0x5D, "[": 0x5B, ".": 0x2E, ",": 0x2C,
        "q": 0x51, ";": 0x3B, "'": 0x27, "l": 0x4C, "d": 0x44, "i": 0x49,
        "0": 0x30, "1": 0x31, "2": 0x32,
        "3": 0x33, "4": 0x34, "5": 0x35}
HELP = {"n": "下一张", "a": "自动轮播", "s": "状态回读", "p": "上一张",
        "+": "音量+", "-": "音量-", ">": "周期+1s", "<": "周期-1s",
        "]": "亮度+", "[": "亮度-", ".": "对比度+", ",": "对比度-",
        "q": "频谱开关", "'": "频谱灵敏度+", ";": "频谱灵敏度-", "l": "播放列表转储(调试)", "d": "当前显示图片快照",
        "0": "直接切", "1": "交叉溶解", "2": "柔边滑动",
        "3": "面板关闭", "4": "面板调节后 3 秒", "5": "面板始终显示",
        "i": "SD 卡状态诊断"}


def decode_dump(pkt: bytes) -> str:
    """转储包（'L'）：高 2 位 01=条目 / 10=收口 / 11=装载快照，见 docs/uart_link.md。"""
    if len(pkt) >= 8 and pkt[0] == 0xA6:
        flags = pkt[1]
        initialized = bool(flags & 0x80)
        sd_type = "SDHC/SDXC" if flags & 0x40 else "SDSC 或未识别"
        hs_supported, hs_active = bool(flags & 0x20), bool(flags & 0x10)
        debug_active = bool(flags & 0x08)
        state = flags & 0x07
        fail = {1: "命令响应起始超时", 2: "R2 帧格式错误", 3: "R2 CRC7 错误",
                4: "R1 帧/命令号错误", 5: "R1 CRC7 错误", 6: "CMD55 未置 APP_CMD"}.get(state, "")
        image_s = int.from_bytes(pkt[2:6], "little") / 50_000_000
        sector_us = int.from_bytes(pkt[6:8], "little") / 100
        text = (f"SD 卡：初始化={'完成' if initialized else '失败'}，类型={sd_type}，"
                f"High Speed={'已启用' if hs_active else '支持' if hs_supported else '未支持/未协商'}，"
                f"host-state={state}")
        if fail:
            text += f"，原因={fail}"
        last_field = int.from_bytes(pkt[6:8], "little")
        live_host_state = (((last_field >> 13) & 0x7) << 3) | state
        if initialized and debug_active:
            cmd_state = (last_field >> 10) & 7
            cmd_error = (last_field >> 7) & 7
            response_tail = last_field & 0x7F
            cmd_states = {0: "IDLE", 1: "PREPARE", 2: "SEND", 3: "RELEASE",
                          4: "WAIT_REPLY", 5: "READ_REPLY", 6: "GAP", 7: "FINISH"}
            text += (f"；host-state={live_host_state} CMD={cmd_states[cmd_state]} "
                     f"error={cmd_error} response-tail=0x{response_tail:02X}")
        elif initialized:
            text += f"，最近图片读卡 {image_s:.3f}s，扇区事务 {sector_us:.2f}us"
        elif state == 1:
            last_field = int.from_bytes(pkt[6:8], "little")
            mismatch_position = (last_field >> 10) & 0x3F
            expected_bit = (last_field >> 9) & 1
            sampled_bit = (last_field >> 8) & 1
            response_tail = last_field & 0xFF
            mismatch_text = "无" if mismatch_position == 0x3F else (
                f"bit{mismatch_position} 期望{expected_bit}/采样{sampled_bit}")
            text += f"，CMD55 发送线首个不匹配={mismatch_text}，响应末八次采样=0x{response_tail:02X}"
        return text
    v = int.from_bytes(pkt, "big")
    tag = v >> 62
    if tag == 0b01:
        idx, bmp = (v >> 57) & 0x1F, (v >> 56) & 1
        pv, pw = (v >> 55) & 1, (v >> 49) & 0x3F
        nx, pr = (v >> 43) & 0x3F, (v >> 37) & 0x3F
        line = f"列表[{idx:2d}] {'BMP' if bmp else 'WAV'}"
        if bmp:
            line += f" 配对={'WAV'+str(pw) if pv else '无'} nxt={nx} prv={pr}"
        elif pv:
            line += f" 配对WAV={pw}"
        return line
    if tag == 0b10:
        fc, bc, wc = (v >> 56) & 0x3F, (v >> 50) & 0x3F, (v >> 44) & 0x3F
        fb, ii = (v >> 38) & 0x3F, (v >> 33) & 0x1F
        lb, sa, ld = (v >> 27) & 1, (v >> 26) & 1, (v >> 23) & 0x7
        return (f"转储收口: 文件{fc} BMP{bc} WAV{wc} 首图{fb} | "
                f"光标={ii} 装载中={lb} 扫描中={sa} ld={ld}")
    if tag == 0b11:
        res = (v >> 60) & 3
        ld = (v >> 57) & 0x7
        wc = (v >> 36) & 0x1FFFFF
        pc = (v >> 16) & 0xFFFFF
        h = (v >> 4) & 0xFFF
        rn = {0: '进行中', 1: 'img_err', 2: '超时', 3: '成功'}.get(res, res)
        return (f"装载快照: 结果={rn} 终态ld={ld} 已发射={wc}字 "
                f"解码像素={pc} 锁存高度={h}")
    return f"转储未知包 {pkt.hex()}"


def send_bytes(key: str) -> bytes:
    """命令 → [CMD, ~CMD] 成对校验字节。"""
    c = CMDS[key]
    return bytes([c, c ^ 0xFF])


def subtitle_bytes(value: str) -> bytes:
    """Build one atomic 0..160 character upload from printable ASCII text."""
    if not isinstance(value, str) or len(value) > 160 or any(not 32 <= ord(c) <= 126 for c in value):
        raise ValueError("字幕仅支持最多 160 个可打印 ASCII 字符")
    raw = value.encode("ascii")
    checksum = len(raw)
    for byte in raw:
        checksum ^= byte
    return (bytes([0x54, len(raw) ^ 0x80]) +
            bytes(byte | 0x80 for byte in raw) +
            bytes([0x80 | (checksum >> 4), 0x80 | (checksum & 0x0F)]))


def decode_pkt(pkt: bytes) -> str:
    """状态包（A5）：A5 | state | fat | flagA | flagB | underrun | img | wav"""
    _, state, fat, fa, fb, und, img, wav = pkt[:8]

    # flagA: {video_pll_lock, sys_pll_lock, sdr_init_done, display_valid}
    flags_a = ["vidPLL", "sysPLL", "SDR", "disp"]
    bits_a = [(fa >> 3) & 1, (fa >> 2) & 1, (fa >> 1) & 1, fa & 1]
    fa_s = " ".join(flags_a[i] for i in range(4) if bits_a[i])

    # flagB: {hdmi_locked, fat_err, disp_buf[1:0]}
    flags_b = ["hdmi", "fatERR"]
    bits_b = [(fb >> 3) & 1, (fb >> 2) & 1]
    fb_s = " ".join(flags_b[i] for i in range(2) if bits_b[i])

    # underrun: 历史粘滞位（开机首帧/切图瞬间的短暂空拍也会钉住；画面正常即误报）
    flags_und = ["vidUND", "audUND"]
    bits_und = [(und >> 3) & 1, (und >> 2) & 1]
    und_s = " ".join(flags_und[i] for i in range(2) if bits_und[i])

    auto_on = (fb >> 4) & 1              # flagB 字节空出的 bit4 = 自动轮播开关
    effect = (fb >> 5) & 0x3             # flagB bits[6:5] = 切换效果
    effect_s = {0: "直接切", 1: "交叉溶解", 2: "柔边滑动"}.get(effect, "未知")
    osd_s = {0: "关闭", 1: "调节后 3 秒", 2: "始终显示"}.get((und >> 4) & 3, "未知")
    ct      = (fa >> 4) & 0xF            # flagA 字节空出的高 4 位 = 对比度档位

    if und & 1:
        source_state = (f"源帧={'就绪' if state & 0x80 else '未就绪'} "
                        f"源音频={'播放' if und & 0x80 else '静音'} "
                        f"发送={'已完成' if state & 0x40 else '未完成'} "
                        f"显示接收={'进行中' if state & 0x20 else '空闲'} "
                        f"写入={'进行中' if und & 2 else '空闲'} "
                        f"包校验={'曾出错' if und & 0x40 else '无记录'}")
        if state & 0x10:
            recv_detail = (f"期望分片={((img >> 5) & 7) << 8 | fat} "
                           f"最近收到分片低8位={wav:02X}")
        else:
            recv_detail = (f"FAT=0x{fat:02X} 源图={(wav >> 3) & 0x1F} "
                           f"音频序列={'异常' if wav & 4 else '正常'} "
                           f"发送计数低位={(wav >> 1) & 1}")
        source = (f"媒体: 装载状态={state & 0xF} {recv_detail} | "
                  f"{source_state} | ")
    else:
        media_tx_state = state & 0x0F
        media_tx_error = (state >> 4) & 0x0F
        tx_names = {0: "receiver-ready", 1: "read-bmp-header", 2: "load-image-chunk",
                    3: "wait-udp", 4: "send-udp", 5: "wait-bmp-source",
                    6: "image-end-gap", 7: "wait-image-result", 8: "wait-commit",
                    9: "idle", 10: "read-wav-header", 11: "load-audio-chunk",
                    12: "wait-wav-source", 13: "audio-end-gap", 14: "wait-audio-result"}
        reject_names = {6: "audio result timeout/invalid",
                        9: "frame-id/state", 10: "END length/reserved",
                        11: "word-count", 12: "checksum", 13: "earlier packet",
                        14: "receiver still draining previous packet"}
        audio_reasons = {1: "receiver not in audio transaction", 2: "frame id mismatch",
                         3: "END length/reserved", 4: "sample count mismatch",
                         5: "PCM checksum mismatch", 6: "bad audio DATA packet",
                         7: "previous packet still draining"}
        error_text = (f"audio rejected: {audio_reasons.get(media_tx_state, 'unknown reason')}"
                      if media_tx_error == 7 else reject_names.get(media_tx_error, str(media_tx_error)))
        source = (f"media-TX={tx_names.get(media_tx_state, str(media_tx_state))} "
                  f"error={error_text}({media_tx_error}) FAT=0x{fat:02X} | ")

    return (f"{source}buf={fb & 3} img={img & 0x1F}"
            f"{'+wav' if wav & 1 else ''} | "
            f"对比度={ct}/6 特效={effect_s} 面板={osd_s} 自动轮播={'开' if auto_on else '关'} | "
            f"OK: {fa_s or '-'} {fb_s or '-'} | 异常: {und_s or '无'}")


def decode_ack(pkt: bytes) -> str:
    """ACK 应答包（5A）：5A | cmd回显 | vol | period_s | img | wav | bri | flags
    flags bit0 = 自动轮播开关当前状态（板端 sd_card_bmp 遥测，ctrl_core 打包）

    显示策略：板子照旧回**全量** 8 字节（协议不变），但这里**只显示这条命令
    相关的那一项**——调音量就只报音量、调亮度就只报亮度，不然每条 ACK 都吐
    一大串，操作起来很乱。想要全景请按 'S'（状态包，显示全部）。"""
    _, cmd, vol, per, img, wav, bri, flags = pkt[:8]
    raw_bri = bri
    name = {0x4E: "下一张", 0x50: "上一张", 0x41: "自动轮播",
            0x2B: "音量+", 0x2D: "音量-", 0x3E: "周期+", 0x3C: "周期-",
            0x5D: "亮度+", 0x5B: "亮度-",
            0x2E: "对比度+", 0x2C: "对比度-",
            0x51: "频谱", 0x3B: "灵敏度+", 0x27: "灵敏度-",
            0x30: "直接切", 0x31: "交叉溶解", 0x32: "柔边滑动",
            0x33: "面板关闭", 0x34: "面板调节后 3 秒", 0x35: "面板始终显示",
            0x54: "字幕上传"}.get(cmd, f"0x{cmd:02X}")
    img_s = f"img={img & 0x1F}{'+wav' if wav & 1 else ''}"
    RESULT = {0: '进行中', 1: 'img_err', 2: '超时', 3: '成功'}
    LDNAME = {0: 'IDLE', 1: 'FILL_REQ', 2: 'FILL_RUN', 3: 'FILE',
              4: 'IMG_WAIT', 5: 'IMG_ACK', 6: 'STREAM', 7: '音频段'}
    diag = (f"上次装载={RESULT.get((wav >> 5) & 3)}/{LDNAME.get((wav >> 2) & 7)}"
            f"{' 装载中' if (wav >> 1) & 1 else ''}")
    ct    = (flags >> 1) & 0x7           # flags bit[3:1] = 对比度档位
    bar   = (flags >> 4) & 1             # flags bit4 = 频谱开关
    sens  = (flags >> 5) & 0x3           # flags bit[6:5] = 频谱灵敏度
    effect = (bri >> 4) & 0x3            # brightness byte bits[5:4]
    osd = (bri >> 6) & 0x3
    bri &= 0xF
    effect_s = {0: "直接切", 1: "交叉溶解", 2: "柔边滑动"}.get(effect, "未知")
    osd_s = {0: "关闭", 1: "调节后 3 秒", 2: "始终显示"}.get(osd, "未知")
    bar_s = f"频谱={'开' if bar else '关'} 灵敏度={sens}/3"
    if   cmd in (0x2B, 0x2D): detail = f"音量={vol}/8"
    elif cmd in (0x3E, 0x3C): detail = f"周期={per}s"
    elif cmd in (0x5D, 0x5B): detail = f"亮度={bri}/8"
    elif cmd in (0x2E, 0x2C): detail = f"对比度={ct}/6"
    elif cmd == 0x51:         detail = bar_s
    elif cmd in (0x3B, 0x27): detail = bar_s
    elif cmd == 0x41:         detail = f"自动轮播={'开' if flags & 1 else '关'}"
    elif cmd in (0x30, 0x31, 0x32): detail = f"切换特效={effect_s}"
    elif cmd in (0x33, 0x34, 0x35): detail = f"面板={osd_s}"
    elif cmd == 0x54:
        subtitle_error = (wav >> 1) & 0x0F
        subtitle_tag = (wav >> 5) & 0x07
        detail = f"FPGA_TAG={subtitle_tag} FPGA_ERR={subtitle_error} SUB_LEN={per} RX_COUNT={img} WIRE={vol:02X} CALC={raw_bri:02X} " + ("COMMIT=OK" if flags & 0x80 else "COMMIT=NO")
    elif cmd in (0x4E, 0x50): detail = f"{img_s} | {diag}"
    elif cmd == 0x4C:         detail = diag
    else:                     detail = (f"音量={vol}/8 周期={per}s 亮度={bri}/8 "
                                        f"对比度={ct}/6 {bar_s} {img_s} "
                                        f"自动轮播={'开' if flags & 1 else '关'} | {diag}")
    return f"ACK {name} | {detail}"


# ---------------------------------------------------------------------------
# 串口枚举（新增）：给前端下拉框 + 自动选中
# ---------------------------------------------------------------------------
def list_serial_ports() -> list:
    """枚举可用串口，USB 转串口排前面，返回 [{device, desc, hwid}]。"""
    try:
        from serial.tools import list_ports
    except Exception:
        return []
    out = []
    try:
        for p in list_ports.comports():
            desc = (p.description or "").strip()
            hwid = (p.hwid or "").strip()
            out.append({"device": p.device, "desc": desc, "hwid": hwid})
    except Exception:
        return []
    # USB 类优先（多数板卡走 USB-UART），其余按设备名稳定排序
    def score(x):
        s = f"{x['desc']} {x['hwid']}".upper()
        return (0 if ("USB" in s or "SERIAL" in s or "CH34" in s or "FTDI" in s
                      or "CP210" in s) else 1, x["device"])
    out.sort(key=score)
    return out


def suggest_port(ports: list) -> str:
    """自动选中：唯一串口直接用；多个取排序后的第一个。"""
    return ports[0]["device"] if ports else ""


# ---------------------------------------------------------------------------
# 传输抽象：serial / eth / loopback 三实现同一套接口。
# ---------------------------------------------------------------------------
class SerialLink:
    """pyserial 独占管理 + 读线程解码 + SSE 订阅广播。"""

    mode = "serial"

    def __init__(self, subs=None):
        self.ser = None
        self.port = None
        self.baud = None
        self.send_lock = threading.Lock()
        self.buf = bytearray()
        self.subs = subs if subs is not None else []   # 每个订阅者一个 queue
        self.lock = threading.Lock()

    # ---- 订阅（SSE） ----
    def subscribe(self):
        q = queue.Queue()
        with self.lock:
            self.subs.append(q)
        return q

    def unsubscribe(self, q):
        with self.lock:
            if q in self.subs:
                self.subs.remove(q)

    def broadcast(self, msg: dict):
        with self.lock:
            for q in list(self.subs):
                q.put(msg)

    def link_msg(self, connected: bool):
        return {"type": "link", "mode": self.mode, "connected": connected,
                "serial": connected,          # 兼容旧前端字段名
                "port": self.port}

    # ---- 开关 ----
    def open(self, port: str, baud: int) -> str:
        with self.lock:
            if self.ser is not None:
                return "串口已打开，请先断开"
            if not port:
                return "未指定串口"
            try:
                import serial as pyserial
                self.ser = pyserial.Serial(port, baud, timeout=0.2)
                self.port, self.baud = port, baud
            except Exception as e:
                return f"打开 {port} 失败: {e}"
        self.broadcast(self.link_msg(True))
        threading.Thread(target=self._reader, daemon=True).start()
        return ""

    def close(self):
        with self.lock:
            if self.ser is None:
                return
            try:
                self.ser.close()
            except Exception:
                pass
            self.ser = None
        self.broadcast(self.link_msg(False))

    def is_open(self) -> bool:
        return self.ser is not None

    # ---- 命令 ----
    def send_key(self, key: str):
        if key not in CMDS:
            return f"未知命令键 {key!r}"
        if self.ser is None:
            return "串口未连接"
        try:
            with self.send_lock:
                self.ser.write(send_bytes(key))          # [CMD, ~CMD] 成对校验
        except Exception as e:
            self.close()
            return f"串口写入失败: {e}"
        if key == "l":
            # 'L' 后板卡回 N+2 个 8 字节包：读线程切换到定长分帧
            self.dump_left = 64
            self.dump_anchored = False
            self.dump_swap = None
        return ""

    # ---- 读线程：字节流 → 解码包 → 广播 ----
    def send_subtitle(self, value: str):
        if self.ser is None:
            return "串口未连接"
        pairs = bytearray()
        for byte in subtitle_bytes(value):
            pairs.extend((byte, byte ^ 0xFF))
        try:
            with self.send_lock:
                self.ser.write(pairs)
        except Exception as e:
            self.close()
            return f"串口字幕发送失败: {e}"
        return ""

    def _reader(self):
        buf = bytearray()
        self.dump_left, self.dump_anchored, self.dump_swap = 0, False, None
        while self.ser is not None:
            try:
                chunk = self.ser.read(64)
            except Exception:
                break
            if not chunk:
                continue
            buf.extend(chunk)
            while True:
                if self.dump_left > 0:           # 转储流：先锚定 L 的 ACK(5A 4C)，再 8 字节定长分帧
                    if not self.dump_anchored:
                        if len(buf) < 2:
                            break
                        if buf[0] == 0x5A and buf[1] == 0x4C:
                            self.dump_anchored = True
                        else:
                            del buf[:1]          # 丢掉 pre-L 残留（被吞的 ACK 等）
                            continue
                    if len(buf) < 8:
                        break
                    pkt = bytes(buf[:8])
                    del buf[:8]
                    if pkt[0] in (0xA5, 0x5A):   # ACK/状态：原序（ctrl_core 本就 LSB 组包）
                        text = decode_pkt(pkt) if pkt[0] == 0xA5 else decode_ack(pkt)
                        kind = "status" if pkt[0] == 0xA5 else "ack"
                    else:
                        # 字节序自适应：首条目组 byte0=0x00 → 旧 bit 流（MSB-first 组包
                        # 被 LSB 先行线上整包颠倒）；tag 01 开头 → 新 bit 流（已 RTL 修正）
                        if self.dump_swap is None:
                            self.dump_swap = (pkt[0] == 0x00)
                        if self.dump_swap:
                            pkt = pkt[::-1]
                        tag = pkt[0] >> 6
                        if tag == 0b11:
                            self.dump_left = 0   # 装载快照（最后一包）→ 回常规分帧
                        else:
                            self.dump_left -= 1
                        text, kind = decode_dump(pkt), "dump"
                    self.broadcast({"type": "pkt", "kind": kind,
                                    "text": text,
                                    "ts": time.strftime("%H:%M:%S")})
                    continue
                ia, ib, ic = buf.find(b"\xA5"), buf.find(b"\x5A"), buf.find(b"\xA6")
                cand = [x for x in (ia, ib, ic) if x >= 0]
                if not cand:
                    buf.clear()
                    break
                i = min(cand)
                del buf[:i]
                if len(buf) < 8:
                    break
                pkt = bytes(buf[:8])
                del buf[:8]
                msg = {"type": "pkt",
                       "kind": "status" if pkt[0] == 0xA5 else "diag" if pkt[0] == 0xA6 else "ack",
                       "text": decode_pkt(pkt) if pkt[0] == 0xA5 else decode_dump(pkt) if pkt[0] == 0xA6 else decode_ack(pkt),
                       "ts": time.strftime("%H:%M:%S")}
                self.broadcast(msg)
        self.broadcast(self.link_msg(False))


class LoopbackLink:
    """无板卡开发档：命令回环成假 ACK 包，验证 UI/SSE 全链路。"""

    mode = "serial"

    def __init__(self, subs=None):
        self.vol, self.per, self.bri, self.effect = 8, 1, 4, 0
        self.osd_mode = 1
        self.subtitle = ""
        self.subs = subs if subs is not None else []
        self.lock = threading.Lock()
        self.port = "loopback"
        self.is_open_ret = True

    def is_open(self):
        return True

    def subscribe(self):
        q = queue.Queue()
        with self.lock:
            self.subs.append(q)
        return q

    def unsubscribe(self, q):
        with self.lock:
            if q in self.subs:
                self.subs.remove(q)

    def broadcast(self, msg):
        with self.lock:
            for q in list(self.subs):
                q.put(msg)

    def open(self, port, baud):
        self.port = port or "loopback"
        self.baud = baud
        self.broadcast(self.link_msg(True))
        return ""

    def close(self):
        pass

    def link_msg(self, connected):
        return {"type": "link", "mode": self.mode, "connected": connected,
                "serial": connected, "port": self.port}

    def send_key(self, key: str):
        if key not in CMDS:
            return f"未知命令键 {key!r}"
        if key == "+":
            self.vol = min(8, self.vol + 1)
        elif key == "-":
            self.vol = max(0, self.vol - 1)
        elif key == ">":
            self.per = min(10, self.per + 1)
        elif key == "<":
            self.per = max(1, self.per - 1)
        elif key == "]":
            self.bri = min(8, self.bri + 1)
        elif key == "[":
            self.bri = max(0, self.bri - 1)
        elif key in ("0", "1", "2"):
            self.effect = int(key)
        elif key in ("3", "4", "5"):
            self.osd_mode = int(key) - 3

        def fake():
            time.sleep(0.02)
            if key == "s":
                pkt = bytes([0xA5, 0x01, 0x08, 0x0F,
                             0x08 | (self.effect << 5), self.osd_mode << 4, 0x03, 0x01])
                kind = "status"
            else:
                pkt = bytes([0x5A, CMDS[key], self.vol, self.per,
                              0x03, 0x01, self.bri | (self.effect << 4) | (self.osd_mode << 6), 0x00])
                kind = "ack"
            self.broadcast({"type": "pkt", "kind": kind,
                            "text": decode_pkt(pkt) if kind == "status" else decode_ack(pkt),
                            "ts": time.strftime("%H:%M:%S")})
        threading.Thread(target=fake, daemon=True).start()
        return ""

    def send_subtitle(self, value: str):
        subtitle_bytes(value)
        self.subtitle = value
        pkt = bytes([0x5A, 0x54, self.vol, self.per, 0x03, 0x01,
                     self.bri | (self.effect << 4) | (self.osd_mode << 6), 0x80])
        self.broadcast({"type": "pkt", "kind": "ack", "text": decode_ack(pkt),
                        "ts": time.strftime("%H:%M:%S")})
        return ""


class EthTransport:
    """以太网传输：UDP socket 直连板卡（板载官方 UDP 栈，无连接、无握手）。

    双板控制入口为媒体板 192.168.137.3:1；显示板 192.168.137.2:1
    负责最终 ACK/状态回包，固定发 PC 192.168.137.1:2。
    （目的端口/IP 在 FPGA 里写死，不做动态学习）。
    PC 侧：bind :2 收包，发往板卡 :1。命令帧与串口同款 [CMD,~CMD]，
    UDP 载荷 = 8 字节应用头 [AA BB CC DD type length] + 数据（APUG013）。

    注意：Windows 防火墙首次会弹窗询问是否放行 python 监听 UDP，需允许；
    本机须有 192.168.137.1/24 地址（与板卡同网段），否则回包出不去。
    """

    mode = "eth"
    # Fixed dual-board topology: PC .1, display .2, media/control .3.
    # The browser and environment cannot redirect control traffic elsewhere.
    BOARD_DEFAULT = "192.168.137.3"
    BOARD_PORT = 1
    LOCAL_PORT = 2
    # The media RTL can wait 2 s and retry three times before its final ACK.
    SUBTITLE_ACK_TIMEOUT = 9.0

    @staticmethod
    def _hdr(type_hi, type_lo, len_hi, len_lo):
        return bytes([0xAA, 0xBB, 0xCC, 0xDD, type_hi, type_lo, len_hi, len_lo])

    def __init__(self, subs=None):
        self.sock = None
        self.board = self.BOARD_DEFAULT
        self.send_lock = threading.Lock()
        self.subs = subs if subs is not None else []
        self.lock = threading.Lock()
        self.subtitle_lock = threading.Lock()
        self.subtitle_condition = threading.Condition()
        self.subtitle_waiting = False
        self.subtitle_result = None
        self.subtitle_result_code = 0
        self.subtitle_result_tag = 0
        # ---- 流会话重组状态（写侧 wr / 读回 rb 各一套，仅读线程访问）----
        self.str = {"wr": self._new_sess(), "rb": self._new_sess()}
        self.snapshot = None

    @staticmethod
    def _new_sess():
        return {"buf": bytearray(), "next_seq": 0, "gaps": 0,
                "last": 0.0, "active": False}

    # ---- 订阅（SSE） ----
    def subscribe(self):
        q = queue.Queue()
        with self.lock:
            self.subs.append(q)
        return q

    def unsubscribe(self, q):
        with self.lock:
            if q in self.subs:
                self.subs.remove(q)

    def broadcast(self, msg: dict):
        with self.lock:
            for q in list(self.subs):
                q.put(msg)

    def link_msg(self, connected: bool):
        return {"type": "link", "mode": self.mode, "connected": connected,
                "serial": connected,              # 兼容旧前端字段名
                "port": f"{self.board}:{self.BOARD_PORT}",
                "local_port": self.LOCAL_PORT}

    # ---- 开关 ----
    def open(self, _baud=None) -> str:
        import socket
        with self.lock:
            if self.sock is not None:
                return "以太网已连接，请先断开"
            self.board = self.BOARD_DEFAULT
            try:
                s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
                s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
                # 流帧突发 ~1.9MB/20ms：默认 64KB 内核缓冲必溢出（整帧只剩尾包
                # 的根因），必须把接收缓冲扩到能整口吞下一次捕获
                try:
                    s.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 8 * 1024 * 1024)
                except OSError:
                    pass
                s.bind(("", self.LOCAL_PORT))     # 收板卡回包（目的端口 2）
                s.settimeout(0.3)                 # 让读线程能定期看到关闭
            except Exception as e:
                return f"打开 UDP :{self.LOCAL_PORT} 失败: {e}"
            self.sock = s
        self.broadcast(self.link_msg(True))
        threading.Thread(target=self._reader, daemon=True).start()
        return ""

    def close(self):
        with self.lock:
            if self.sock is None:
                return
            try:
                self.sock.close()
            except Exception:
                pass
            self.sock = None
        self.broadcast(self.link_msg(False))

    def is_open(self) -> bool:
        return self.sock is not None

    # ---- 命令：应用头 + [CMD,~CMD] → 板卡 :1 ----
    def send_key(self, key: str):
        if key not in CMDS:
            return f"未知命令键 {key!r}"
        if self.sock is None:
            return "以太网未连接"
        payload = self._hdr(0x00, 0x01, 0x00, 0x02) + send_bytes(key)
        try:
            with self.send_lock:
                self.sock.sendto(payload, (self.board, self.BOARD_PORT))
        except Exception as e:
            return f"UDP 发送到 {self.board}:{self.BOARD_PORT} 失败: {e}"
        return ""

    def send_subtitle(self, value: str):
        if self.sock is None:
            return "以太网未连接"
        try:
            encoded = subtitle_bytes(value)
            # V1 subtitle ACK has no transaction sequence, so serialize uploads
            # and report success only after the display board confirms commit.
            with self.subtitle_lock:
                with self.subtitle_condition:
                    self.subtitle_waiting = True
                    self.subtitle_result = None
                    self.subtitle_result_code = 0
                    self.subtitle_result_tag = 0
                with self.send_lock:
                    for byte in encoded:
                        payload = self._hdr(0, 1, 0, 2) + bytes((byte, byte ^ 0xFF))
                        self.sock.sendto(payload, (self.board, self.BOARD_PORT))
                        # eth_front accepts one verified byte per datagram.
                        time.sleep(0.002)
                deadline = time.monotonic() + self.SUBTITLE_ACK_TIMEOUT
                with self.subtitle_condition:
                    while self.subtitle_result is None:
                        remaining = deadline - time.monotonic()
                        if remaining <= 0:
                            self.subtitle_waiting = False
                            return f"字幕已发出，但 {self.SUBTITLE_ACK_TIMEOUT:g} 秒内没有收到显示板确认"
                        self.subtitle_condition.wait(remaining)
                    success = self.subtitle_result
                    self.subtitle_waiting = False
                if not success:
                    code = self.subtitle_result_code
                    tag = self.subtitle_result_tag
                    reason = {1: "PC subtitle checksum", 2: "display BEGIN/DATA/END validation",
                              4: "PC subtitle length mismatch",
                              3: "display ACK timeout", 5: "subtitle stream started",
                              6: "PC checksum passed; display transaction started"}.get(code, "unknown stage")
                    return f"\u663e\u793a\u677f\u62d2\u7edd\u6216\u672a\u63d0\u4ea4\u5b57\u5e55\uff0c\u65e7\u5b57\u5e55\u4fdd\u6301\u4e0d\u53d8 | FPGA_TAG={tag} FPGA_ERR={code} ({reason})"
        except Exception as e:
            with self.subtitle_condition:
                self.subtitle_waiting = False
            return f"以太网字幕发送失败: {e}"
        return ""

    def _capture_subtitle_ack(self, pkt: bytes):
        if len(pkt) < 8 or pkt[0] != 0x5A or pkt[1] != 0x54:
            return
        with self.subtitle_condition:
            if self.subtitle_waiting:
                self.subtitle_result = bool(pkt[7] & 0x80)
                self.subtitle_result_code = (pkt[5] >> 1) & 0x0F
                self.subtitle_result_tag = (pkt[5] >> 5) & 0x07
                self.subtitle_condition.notify_all()

    # ---- 流包（type=0x0003）：seq 重组 + 静默收口 ----
    STR_TIMEOUT = 0.4                  # 流包静默判会话结束（整帧空口时间 ~20ms）

    def _on_stream(self, data: bytes):
        typ = "rb" if data[4:6] == bytes([0x04, 0x00]) else "wr"   # 0x0004=读回
        st = self.str[typ]
        seq = data[8] | (data[9] << 8)
        if seq == 0:                   # RTL 冲洗收口后 seq 归零 = 新会话
            st.update(self._new_sess(), active=True)
        elif not st["active"]:
            return                     # 残尾：会话主体一个包都没收到的孤儿尾包
        elif seq != st["next_seq"]:
            st["gaps"] += (seq - st["next_seq"]) & 0xFFFF
        st["next_seq"] = (seq + 1) & 0xFFFF
        st["buf"] += bytes(data[10:])  # 尾包 len 对齐 4 字节，余数忽略
        st["last"] = time.time()

    def _stream_poll(self):
        """读线程每次循环调用：会话静默超时 → 收口整帧入库 + 通知前端。"""
        for typ in ("wr", "rb"):
            st = self.str[typ]
            if not st["active"] or (time.time() - st["last"]) <= self.STR_TIMEOUT:
                continue
            st["active"] = False
            words = len(st["buf"]) // 4
            h = words // 640           # 整行才收（发射行恒 1280 宽 = 640 字）
            ts = time.strftime("%H:%M:%S")
            slot = ETH_FRAME if typ == "wr" else ETH_FRAME_RB
            with ETH_FRAME_LOCK:
                slot["id"] += 1
                # 写侧只展示完整行；读回是 3:1 稀疏字流，保留末行的抽样字。
                slot["data"] = bytes(st["buf"] if typ == "rb"
                                     else st["buf"][: h * 640 * 4])
                slot["gaps"] = st["gaps"]
                slot["words"] = words
                slot["ts"] = ts
                slot["stride"] = 3 if typ == "rb" else 1
                fid = slot["id"]
            self.broadcast({"type": "frame", "kind": typ, "source": "probe", "id": fid,
                            "words": words, "h": h,
                            "gaps": st["gaps"], "ts": ts})

    # ---- 读线程：UDP 报文 → 剥 8 字节头 → 解码包 → 广播 ----
    def _send_snapshot_reply(self, kind: int, payload: bytes):
        sock = self.sock
        if sock is None:
            return
        packet = self._hdr(kind & 0xFF, (kind >> 8) & 0xFF,
                           len(payload) & 0xFF, (len(payload) >> 8) & 0xFF) + payload
        try:
            with self.send_lock:
                sock.sendto(packet, (self.board, self.BOARD_PORT))
        except Exception as exc:
            self.broadcast({"type": "pkt", "kind": "dump",
                            "text": f"PC snapshot reply failed: {exc}",
                            "ts": time.strftime("%H:%M:%S")})

    def _on_snapshot(self, data: bytes):
        """Receive a media-side D snapshot and complete its image/audio replies."""
        kind = int.from_bytes(data[4:6], "little")
        length = int.from_bytes(data[6:8], "little")
        payload = data[8:]
        if len(payload) != length:
            return
        if kind == 0x21 and length == 8:
            self.snapshot = {
                "frame": int.from_bytes(payload[:2], "little"),
                "total": int.from_bytes(payload[4:8], "little"),
                "words": bytearray(), "next_seq": 0, "gaps": 0,
                "image_ok": False, "audio_frame": None, "audio_count": 0,
                "audio": bytearray(), "audio_next_seq": 0, "audio_gaps": 0,
            }
            return
        state = self.snapshot
        if state is None:
            return
        frame_id = state["frame"]
        if kind == 0x22 and length >= 8:
            got_frame = int.from_bytes(payload[:2], "little")
            seq = int.from_bytes(payload[2:4], "little")
            if got_frame != frame_id or seq != state["next_seq"] or (length - 4) % 4:
                state["gaps"] += max(1, (seq - state["next_seq"]) & 0xFFFF)
            state["next_seq"] = (seq + 1) & 0xFFFF
            state["words"].extend(payload[4:])
            return
        if kind == 0x23 and length == 8:
            got_frame = int.from_bytes(payload[:2], "little")
            checksum = int.from_bytes(payload[2:6], "little")
            words = state["words"]
            actual_sum = sum(word[0] for word in struct.iter_unpack("<I", words)) & 0xFFFFFFFF
            good = (got_frame == frame_id and state["total"] == 460800 and
                    len(words) == 460800 * 4 and state["gaps"] == 0 and
                    actual_sum == checksum)
            state["image_ok"] = good
            self._send_snapshot_reply(0x24, struct.pack("<HB", frame_id, 0 if good else 1))
            if not good:
                self.broadcast({"type": "pkt", "kind": "dump",
                                "text": f"PC snapshot {frame_id:04X} rejected: "
                                        f"words={len(words)//4} gaps={state['gaps']} "
                                        f"sum={'ok' if actual_sum == checksum else 'bad'}",
                                "ts": time.strftime("%H:%M:%S")})
            return
        if kind == 0x30 and length == 8:
            state["audio_frame"] = int.from_bytes(payload[:2], "little")
            state["audio_count"] = int.from_bytes(payload[2:6], "little")
            state["audio"] = bytearray()
            state["audio_next_seq"] = 0
            state["audio_gaps"] = 0
            return
        if kind == 0x31 and length >= 4:
            audio_id = int.from_bytes(payload[:2], "little")
            seq = int.from_bytes(payload[2:4], "little")
            if audio_id != state["audio_frame"] or seq != state["audio_next_seq"]:
                state["audio_gaps"] += max(1, (seq - state["audio_next_seq"]) & 0xFFFF)
            state["audio_next_seq"] = (seq + 1) & 0xFFFF
            state["audio"].extend(payload[4:])
            return
        if kind == 0x32 and length == 8:
            audio_id = int.from_bytes(payload[:2], "little")
            checksum = int.from_bytes(payload[2:6], "little")
            audio = state["audio"]
            good = (audio_id == frame_id and state["audio_gaps"] == 0 and
                    len(audio) == state["audio_count"] and (sum(audio) & 0xFFFFFFFF) == checksum)
            self._send_snapshot_reply(0x33, struct.pack("<HB", frame_id, 0 if good else 1))
            if good and state["image_ok"]:
                self._send_snapshot_reply(0x24, struct.pack("<HB", frame_id, 2))
                ts = time.strftime("%H:%M:%S")
                with ETH_FRAME_LOCK:
                    ETH_FRAME_SNAPSHOT["id"] += 1
                    ETH_FRAME_SNAPSHOT["data"] = bytes(state["words"])
                    ETH_FRAME_SNAPSHOT["gaps"] = 0
                    ETH_FRAME_SNAPSHOT["words"] = len(state["words"]) // 4
                    ETH_FRAME_SNAPSHOT["ts"] = ts
                    ETH_FRAME_SNAPSHOT["stride"] = 1
                    fid = ETH_FRAME_SNAPSHOT["id"]
                self.broadcast({"type": "frame", "kind": "rb", "source": "snapshot", "id": fid,
                                "words": 460800, "h": 720, "gaps": 0, "ts": ts})
            self.snapshot = None

    def _reader(self):
        buf = bytearray(2048)
        view = memoryview(buf)
        while self.sock is not None:
            try:
                n = self.sock.recv_into(buf)   # 热路径：零拷贝收包，解码按需
                data = view[:n]
            except Exception:
                self._stream_poll()            # 超时窗口顺带查会话收口
                continue                       # 超时/关闭 → 回到 while 判据
            if (n >= 8 and data[:4] == b"\xAA\xBB\xCC\xDD" and
                    data[5] == 0 and data[4] in (0x21, 0x22, 0x23, 0x30, 0x31, 0x32)):
                self._on_snapshot(bytes(data[:n]))
                continue
            if (n >= 10 and data[:4] == b"\xAA\xBB\xCC\xDD"
                    and data[4] in (0x03, 0x04) and data[5] == 0x00):
                self._on_stream(data)          # 流包（03=写侧/04=读回）：重组不进日志
                continue
            if n >= 16 and data[:4] == b"\xAA\xBB\xCC\xDD":
                pkt = bytes(data[8:16])           # 应用头 + 8 字节包
            elif n >= 8:
                pkt = bytes(data[:8])
            else:
                continue
            if pkt[0] not in (0xA5, 0x5A):
                if pkt[0] == 0xA6:
                    self.broadcast({"type": "pkt", "kind": "diag",
                                    "text": decode_dump(pkt),
                                    "ts": time.strftime("%H:%M:%S")})
                    continue
                if (pkt[0] >> 6) in (0b01, 0b10, 0b11):   # 转储包
                    self.broadcast({"type": "pkt", "kind": "dump",
                                    "text": decode_dump(pkt),
                                    "ts": time.strftime("%H:%M:%S")})
                continue
            self._capture_subtitle_ack(pkt)
            msg = {"type": "pkt",
                   "kind": "status" if pkt[0] == 0xA5 else "ack",
                   "text": decode_pkt(pkt) if pkt[0] == 0xA5 else decode_ack(pkt),
                   "ts": time.strftime("%H:%M:%S")}
            self.broadcast(msg)
            self._stream_poll()
        self.broadcast(self.link_msg(False))


# 两条链路共享同一份 SSE 订阅表：任一链路广播都推给所有订阅者，
# 前端不需要知道后端有几个传输（切模式只是换发送路径）。
SUBS = []
link = (LoopbackLink(SUBS) if os.environ.get("WEB_LOOPBACK") else SerialLink(SUBS))
eth_link = EthTransport(SUBS)

# ---------------------------------------------------------------------------
# 以太网流帧（写侧分叉，type=0x0003）：EthTransport 在读线程里就地重组整帧，
# 完整帧存在这里，SSE 只推「有新帧」的通知；前端经 /api/frame 拉原始字节渲染
#（一帧 ~1.8MB，不适合塞 SSE 文本流）。
# 字序与 RTL 线序一致：每字 4 字节 LSB 先（=小端），字低 16bit=左像素 RGB565。
# ---------------------------------------------------------------------------
ETH_FRAME = {"id": 0, "data": b"", "gaps": 0, "words": 0, "ts": "", "stride": 1}
ETH_FRAME_RB = {"id": 0, "data": b"", "gaps": 0, "words": 0, "ts": "", "stride": 3}
ETH_FRAME_SNAPSHOT = {"id": 0, "data": b"", "gaps": 0, "words": 0, "ts": "", "stride": 1}
ETH_FRAME_LOCK = threading.Lock()


# ---------------------------------------------------------------------------
# Flask 路由
# ---------------------------------------------------------------------------
@app.route("/")
def index():
    return render_template("index.html")


@app.route("/api/status")
def api_status():
    return jsonify({"serial_open": link.is_open(),
                    "serial_port": getattr(link, "port", ""),
                    "eth_available": True,
                    "eth_open": eth_link.is_open(),
                    "eth_board": eth_link.board,
                    "eth_local_port": EthTransport.LOCAL_PORT,
                    "loopback": isinstance(link, LoopbackLink),
                    "auto_connect": AUTO_CONNECT,
                    "baud": DEFAULT_BAUD})


@app.route("/api/ports")
def api_ports():
    """枚举串口 + 给出自动选中项（唯一串口时前端直接连）。"""
    if isinstance(link, LoopbackLink):
        return jsonify({"ports": [{"device": "loopback",
                                   "desc": "开发回环档（无板卡）",
                                   "hwid": ""}],
                        "suggested": "loopback",
                        "count": 1,
                        "baud": DEFAULT_BAUD})
    ports = list_serial_ports()
    return jsonify({"ports": ports,
                    "suggested": suggest_port(ports),
                    "count": len(ports),
                    "baud": DEFAULT_BAUD})


@app.route("/api/keys")
def api_keys():
    """命令表下发给前端，前端按分组渲染按钮（避免两处硬编码漂移）。"""
    order = ["p", "n", "a", "s", "0", "1", "2", "3", "4", "5", "-", "+", "<", ">", "[", "]",
             ",", ".", ";", "'", "q", "i", "l", "d"]
    groups = [("播放", ["p", "n", "a", "s"]),
               ("切换特效", ["0", "1", "2"]),
               ("OSD 面板", ["3", "4", "5"]),
              ("音量", ["-", "+"]),
              ("轮播周期", ["<", ">"]),
              ("亮度 / 对比度", ["[", "]", ",", "."]),
              ("音频频谱", [";", "'", "q"]),
              ("SD 卡诊断", ["i"]),
              ("调试", ["l"])]
    return jsonify({"keys": [{"key": k, "label": HELP[k]} for k in order],
                    "groups": [{"name": n, "keys": ks} for n, ks in groups]})


@app.route("/api/serial/connect", methods=["POST"])
def api_connect():
    d = request.get_json(force=True, silent=True) or {}
    port = d.get("port", "")
    baud = int(d.get("baud", DEFAULT_BAUD) or DEFAULT_BAUD)
    if not port:                                   # 不传就自动选
        port = suggest_port(list_serial_ports())
    err = link.open(port, baud)
    return (jsonify({"ok": False, "error": err}), 400) if err else jsonify({"ok": True})


@app.route("/api/serial/disconnect", methods=["POST"])
def api_disconnect():
    link.close()
    return jsonify({"ok": True})


@app.route("/api/eth/connect", methods=["POST"])
def api_eth_connect():
    err = eth_link.open()
    if err:
        return jsonify({"ok": False, "error": err}), 400
    return jsonify({"ok": True, "target": f"{eth_link.BOARD_DEFAULT}:{eth_link.BOARD_PORT}"})


@app.route("/api/eth/disconnect", methods=["POST"])
def api_eth_disconnect():
    eth_link.close()
    return jsonify({"ok": True})


@app.route("/api/cmd", methods=["POST"])
def api_cmd():
    d = request.get_json(force=True, silent=True) or {}
    mode = d.get("mode", "serial")
    key = d.get("key", "")
    err = (eth_link if mode == "eth" else link).send_key(key)
    if err:
        return jsonify({"ok": False, "error": err}), 400
    return jsonify({"ok": True})


@app.route("/api/subtitle", methods=["POST"])
def api_subtitle():
    d = request.get_json(force=True, silent=True) or {}
    mode = d.get("mode", "serial")
    try:
        value = d.get("text", "")
        subtitle_bytes(value)
    except ValueError as e:
        return jsonify({"ok": False, "error": str(e)}), 400
    err = (eth_link if mode == "eth" else link).send_subtitle(value)
    if err:
        return jsonify({"ok": False, "error": err}), 504 if mode == "eth" and "确认" in err else 400
    return jsonify({"ok": True, "length": len(value), "acknowledged": mode == "eth"})


@app.route("/api/stream")
def api_stream():
    q = link.subscribe()

    def gen():
        try:
            # 开流先各推一条链路状态（前端据此恢复两个传输的连接态）
            for lk in (link, eth_link):
                yield f"data: {json.dumps(lk.link_msg(lk.is_open()))}\n\n"
            while True:
                try:
                    msg = q.get(timeout=15)
                    yield f"data: {json.dumps(msg, ensure_ascii=False)}\n\n"
                except queue.Empty:
                    yield ": keepalive\n\n"          # SSE 心跳，防连接超时
        finally:
            link.unsubscribe(q)

    return Response(gen(), mimetype="text/event-stream",
                    headers={"Cache-Control": "no-cache"})


@app.route("/api/frame")
def api_frame():
    """最新重组帧：原始字流（每字 4 字节小端，RGB565×2/字）+ 元数据头。
    ?slot=wr（写侧发射流，默认）/ rb（显存读回）。"""
    slot_name = request.args.get("slot", "wr")
    slots = {"wr": ETH_FRAME, "rb": ETH_FRAME_RB, "snapshot": ETH_FRAME_SNAPSHOT}
    slot = slots.get(slot_name)
    if slot is None:
        return jsonify({"ok": False, "error": "unknown frame slot"}), 404
    with ETH_FRAME_LOCK:
        data = slot["data"]
        frame_id = slot["id"]
        gaps, words, ts = slot["gaps"], slot["words"], slot["ts"]
        stride = slot.get("stride", 3 if slot_name == "rb" else 1)
    resp = Response(data, mimetype="application/octet-stream")
    resp.headers["X-Frame-Id"] = str(frame_id)
    resp.headers["X-Frame-Words"] = str(words)
    resp.headers["X-Frame-Gaps"] = str(gaps)
    resp.headers["X-Frame-Stride"] = str(stride)
    resp.headers["X-Frame-Ts"] = ts
    resp.headers["Cache-Control"] = "no-store"
    return resp


def main():
    global link
    if os.environ.get("WEB_LOOPBACK"):
        link = LoopbackLink()
        print("[loopback] 开发档：命令将回环成假 ACK 包")
    else:
        ports = list_serial_ports()
        if ports:
            names = ", ".join(p["device"] for p in ports)
            print(f"[serial] 检测到 {len(ports)} 个串口: {names}"
                  f" → 默认 {suggest_port(ports)}")
            if len(ports) == 1 and AUTO_CONNECT:
                print("[serial] 唯一串口，页面加载后会自动连接")
        else:
            print("[serial] 未检测到串口，插上板卡后点页面上的刷新")
    # 串口不在启动时打开——由页面自动选端口后连接（WEB_NOAUTO=1 则只选中）
    print("Web 控制台: http://127.0.0.1:5000")
    if not os.environ.get("WEB_LOOPBACK"):
        eth_error = eth_link.open()
        if eth_error:
            print(f"[eth] automatic UDP setup failed: {eth_error}")
        else:
            print(f"[eth] UDP control ready: {eth_link.BOARD_DEFAULT}:{eth_link.BOARD_PORT} "
                  f"via local port {eth_link.LOCAL_PORT}")
    app.run(host="127.0.0.1", port=5000, threaded=True)


if __name__ == "__main__":
    main()
