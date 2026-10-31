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
import atexit
import json
import os
import queue
import shutil
import signal
import struct
import subprocess
import sys
import tempfile
import threading
import time
from pathlib import Path

from flask import Flask, Response, jsonify, render_template, request
from media_upload import (AUDIO_PACKET_SAMPLES, IMAGE_PACKET_WORDS, MAX_HEIGHT, MAX_WIDTH,
                          PC_AUDIO_MAX_SAMPLES, control_packet, image_packet, load_pcm_wav,
                          resolve_ffmpeg, rgb24_to_native_words, transcode_audio_stream, unpack_display_packet)

app = Flask(__name__)
app.config["MAX_CONTENT_LENGTH"] = 1024 * 1024 * 1024
VIDEO_LOCK = threading.Lock()
VIDEO_PROCESS = None
VIDEO_PATH = None
VIDEO_NAME = ""
VIDEO_LAST_EXIT = None
VIDEO_STATUS_PATH = None
VIDEO_LOG_PATH = None
VIDEO_USER_STOPPED = False
VIDEO_RELEASE_PENDING = False
VIDEO_IMAGE_REQUEST_ACTIVE = False
VIDEO_CAPTURE_DIR = Path(__file__).resolve().parents[2] / "boardtest" / "captures" / "video"
VIDEO_SCRIPT = Path(__file__).resolve().parents[1] / "direct_video_sender.py"
PRODUCT_PROFILE = json.loads(VIDEO_SCRIPT.with_name("direct_video_profile.json").read_text(encoding="utf-8"))
PRODUCT_CAPABILITIES = {"cv": PRODUCT_PROFILE.get("cv_enabled", True),
                        "cv_neighborhood": PRODUCT_PROFILE.get("cv_neighborhood_enabled", True),
                        "spectrum": PRODUCT_PROFILE.get("spectrum_enabled", True)}
UNAVAILABLE_KEYS = set()
if not PRODUCT_CAPABILITIES["cv"]:
    UNAVAILABLE_KEYS.update(("g", "b", "e", "h", "w"))
elif not PRODUCT_CAPABILITIES["cv_neighborhood"]:
    UNAVAILABLE_KEYS.update(("e", "h"))
if not PRODUCT_CAPABILITIES["spectrum"]:
    UNAVAILABLE_KEYS.update(("q", ";", "'"))


def _video_status_locked():
    global VIDEO_PROCESS, VIDEO_PATH, VIDEO_NAME, VIDEO_LAST_EXIT, VIDEO_RELEASE_PENDING
    progress = {}
    if VIDEO_STATUS_PATH:
        try:
            progress = json.loads(Path(VIDEO_STATUS_PATH).read_text(encoding="utf-8"))
        except (OSError, ValueError):
            pass
    if VIDEO_PROCESS is not None:
        exit_code = VIDEO_PROCESS.poll()
        if exit_code is None:
            return {**progress, "active": True, "name": VIDEO_NAME,
                    "state": progress.get("state", "starting"), "pid": VIDEO_PROCESS.pid}
        VIDEO_LAST_EXIT = exit_code
        VIDEO_PROCESS = None
        VIDEO_RELEASE_PENDING = True
        if VIDEO_PATH:
            try:
                Path(VIDEO_PATH).unlink(missing_ok=True)
            except OSError:
                pass
        VIDEO_PATH = None
        VIDEO_NAME = ""
    state = "idle" if VIDEO_LAST_EXIT is None else (
        "stopped" if VIDEO_USER_STOPPED or VIDEO_LAST_EXIT == 0 else "error")
    result = {**progress, "active": VIDEO_RELEASE_PENDING, "name": "",
              "state": "releasing" if VIDEO_RELEASE_PENDING else state,
              "exit_code": VIDEO_LAST_EXIT}
    if state == "error" and VIDEO_LOG_PATH:
        try:
            with open(VIDEO_LOG_PATH, "rb") as log:
                log.seek(0, os.SEEK_END)
                log.seek(max(0, log.tell() - 4096))
                result["details"] = log.read().decode("utf-8", errors="replace").strip()
        except OSError:
            pass
        if "error" not in result:
            sender_error = next((line.split("direct_video_sender:", 1)[1].strip()
                                 for line in reversed(result.get("details", "").splitlines())
                                 if "direct_video_sender:" in line), None)
            result["error"] = sender_error or "Video sender exited before completing playback"
    return result


def stop_video_sender():
    global VIDEO_PROCESS, VIDEO_PATH, VIDEO_NAME, VIDEO_LAST_EXIT, VIDEO_USER_STOPPED, VIDEO_RELEASE_PENDING
    with VIDEO_LOCK:
        process = VIDEO_PROCESS
        if process is not None:
            VIDEO_USER_STOPPED = True
            VIDEO_RELEASE_PENDING = True
        if process is not None and process.poll() is None:
            if os.name == "nt":
                subprocess.run(["taskkill", "/PID", str(process.pid), "/T", "/F"],
                               stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                               check=False)
            else:
                try:
                    os.killpg(process.pid, signal.SIGTERM)
                except ProcessLookupError:
                    pass
            try:
                process.wait(timeout=4)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait(timeout=2)
            VIDEO_LAST_EXIT = process.returncode
        elif process is not None:
            VIDEO_LAST_EXIT = process.returncode
        VIDEO_PROCESS = None
        if VIDEO_PATH:
            try:
                Path(VIDEO_PATH).unlink(missing_ok=True)
            except OSError:
                pass
        VIDEO_PATH = None
        VIDEO_NAME = ""


atexit.register(stop_video_sender)
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
        "z": 0x5A,
        "0": 0x30, "1": 0x31, "2": 0x32,
        "3": 0x33, "4": 0x34, "5": 0x35,
        "6": 0x36, "7": 0x37, "8": 0x38,
        "r": 0x52, "g": 0x47, "b": 0x42,
        "e": 0x45, "h": 0x48, "w": 0x57}
HELP = {"n": "下一张", "a": "自动轮播", "s": "状态回读", "p": "上一张",
        "+": "音量+", "-": "音量-", ">": "周期+1s", "<": "周期-1s",
        "]": "亮度+", "[": "亮度-", ".": "对比度+", ",": "对比度-",
        "q": "频谱开关", "'": "频谱灵敏度+", ";": "频谱灵敏度-", "l": "播放列表转储(调试)", "d": "当前显示图片快照",
        "0": "直接切", "1": "淡入淡出", "2": "滑动转场",
        "3": "面板关闭", "4": "面板调节后 3 秒", "5": "面板始终显示",
        "i": "SD 卡状态诊断", "z": "读取传感器原始数据"}

HELP.update({"r": "\u539f\u56fe\u76f4\u901a", "g": "\u7070\u5ea6", "b": "\u4e8c\u503c\u5316",
             "e": "Sobel \u68af\u5ea6", "h": "\u56fe\u50cf\u9510\u5316", "w": "\u96ea\u82b1"})
CV_MODE_NAMES = {0: "raw", 1: "gray", 2: "binary", 3: "sobel", 4: "sharpen", 5: "snow"}
HELP.update({"6": "单图直显", "7": "左右双图", "8": "四宫格"})
VIEW_LOCK = threading.Lock()
VIEW_STATE = None
VIEW_RESYNC = False


def decode_view(body):
    """VIEW_STATUS v1: fixed 16 bytes; shared by UDP and USB A7 framing."""
    if len(body) != 16:
        raise ValueError("VIEW_STATUS must have 16 bytes")
    sequence, generation, layout, busy, focus, mask = struct.unpack_from("<BHBBBB", body)
    indices = list(body[7:11])
    width, height = struct.unpack_from("<HH", body, 11)
    if (layout > 2 or busy > 1 or focus >= (1 if layout == 0 else 2 if layout == 1 else 4)
            or mask & ~(1 if layout == 0 else 3 if layout == 1 else 15)
            or any(index > 31 for index in indices) or width > 1280 or height > 720):
        raise ValueError("invalid VIEW_STATUS fields")
    return {"type": "view", "sequence": sequence, "generation": generation,
            "layout": layout, "busy": bool(busy), "focus": focus, "valid_mask": mask,
            "indices": indices, "width": width, "height": height, "result": body[15]}


def publish_view(body, broadcast):
    global VIEW_STATE, VIEW_RESYNC
    try:
        state = decode_view(body)
    except ValueError:
        return False
    with VIEW_LOCK:
        if VIEW_STATE is not None:
            delta = (state["sequence"] - VIEW_STATE["sequence"]) & 255
            if delta == 0 and state == VIEW_STATE:
                return False
            if delta >= 128 and not VIEW_RESYNC:
                return False
        VIEW_RESYNC = False
        VIEW_STATE = state
    broadcast(state)
    return True


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
    effect_s = {0: "直接切", 1: "淡入淡出", 2: "滑动转场"}.get(effect, "未知")
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
        reject_names = {2: "image source/SD/FIFO error or stalled read",
                        6: "audio result timeout/invalid",
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

    cv_mode = (img >> 5) & 7
    cv_text = CV_MODE_NAMES.get(cv_mode, "unknown") if not (und & 1) else "n/a"
    return (f"{source}buf={fb & 3} img={img & 0x1F}"
            f"{'+wav' if wav & 1 else ''} | "
            f"CV={cv_text} | "
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
            0x51: "频谱", 0x3B: "灵敏度-", 0x27: "灵敏度+",
            0x30: "直接切", 0x31: "淡入淡出", 0x32: "滑动转场",
            0x33: "面板关闭", 0x34: "面板调节后 3 秒", 0x35: "面板始终显示",
            0x54: "字幕上传"}.get(cmd, f"0x{cmd:02X}")
    if cmd in (0x52, 0x47, 0x42, 0x45, 0x48, 0x57):
        name = f"CV {CV_MODE_NAMES.get((img >> 5) & 7, 'unknown')}"
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
    effect_s = {0: "直接切", 1: "淡入淡出", 2: "滑动转场"}.get(effect, "未知")
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
        if subtitle_error == 2:
            reject_code = raw_bri & 0x7F
            reject_reason = {1: "BEGIN 未活动", 2: "END 长度错误", 3: "序号不匹配",
                             4: "声明长度不匹配", 5: "END 校验字段不匹配",
                             6: "DATA 字符未收全", 7: "显示端 XOR 校验不符",
                             8: "此前收到非法 DATA", 15: "未分类的 END 拒绝"}.get(
                                 reject_code, "显示端返回长度不符")
            diag_kind = "DISPLAY_REJECT" if raw_bri & 0x80 else "DISPLAY_VALUE"
            detail = (f"FPGA_TAG={subtitle_tag} FPGA_ERR={subtitle_error} SUB_LEN={per} RX_COUNT={img} "
                      f"WIRE={vol:02X} {diag_kind}=0x{raw_bri:02X} ({reject_reason}) COMMIT=NO")
        else:
            detail = f"FPGA_TAG={subtitle_tag} FPGA_ERR={subtitle_error} SUB_LEN={per} RX_COUNT={img} WIRE={vol:02X} CALC={raw_bri:02X} " + ("COMMIT=OK" if flags & 0x80 else "COMMIT=NO")
    elif cmd in (0x4E, 0x50): detail = f"{img_s} | {diag}"
    elif cmd == 0x4C:         detail = diag
    else:                     detail = (f"音量={vol}/8 周期={per}s 亮度={bri}/8 "
                                        f"对比度={ct}/6 {bar_s} {img_s} "
                                        f"自动轮播={'开' if flags & 1 else '关'} | {diag}")
    cv_text = "" if cmd == 0x54 else f" | CV={CV_MODE_NAMES.get((img >> 5) & 7, 'unknown')}"
    return f"ACK {name} | {detail}{cv_text}"


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
                ia, ib, ic, iv = buf.find(b"\xA5"), buf.find(b"\x5A"), buf.find(b"\xA6"), buf.find(b"\xA7")
                cand = [x for x in (ia, ib, ic, iv) if x >= 0]
                if not cand:
                    buf.clear()
                    break
                i = min(cand)
                del buf[:i]
                if buf[0] == 0xA7:
                    if len(buf) < 17:
                        break
                    publish_view(bytes(buf[1:17]), self.broadcast)
                    del buf[:17]
                    continue
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
    DISPLAY_IP = "192.168.137.2"
    DISPLAY_PORT = 1
    LOCAL_IP = "192.168.137.1"
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
        self.sensor_query_lock = threading.Lock()
        self.sensor_condition = threading.Condition()
        self.sensor_waiting = False
        self.sensor_active_sequence = None
        self.sensor_chunks = {}
        self.sensor_result = None
        self.image_upload_lock = threading.Lock()
        self.image_upload_active = False
        self.upload_sock = None
        self.display_frame_id = 0x7000
        self.display_sequence = 0x80
        self.image_packet_gap_s = 0.004
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
                sock = None
            else:
                sock = self.sock
                self.sock = None
            if sock is not None:
                try:
                    sock.close()
                except Exception:
                    pass
        upload_sock = self.upload_sock
        self.upload_sock = None
        if upload_sock is not None:
            try:
                upload_sock.close()
            except Exception:
                pass
        self.broadcast(self.link_msg(False))

    def is_open(self) -> bool:
        return self.sock is not None

    # ---- 命令：应用头 + [CMD,~CMD] → 板卡 :1 ----
    def send_key(self, key: str):
        if key not in CMDS:
            return f"未知命令键 {key!r}"
        if self.sock is None:
            return "以太网未连接"
        if self.image_upload_active and key != "s":
            return "PC 图像上传中，请等待当前帧提交后再操作"
        payload = self._hdr(0x00, 0x01, 0x00, 0x02) + send_bytes(key)
        try:
            with self.send_lock:
                self.sock.sendto(payload, (self.board, self.BOARD_PORT))
        except Exception as e:
            return f"UDP 发送到 {self.board}:{self.BOARD_PORT} 失败: {e}"
        return ""

    def read_sensor_snapshot(self, timeout: float = 4.0):
        """Query the media board for raw BMP280/AHT10 bytes; no conversion."""
        if self.sock is None:
            return None, "Ethernet is disconnected"
        if not self.sensor_query_lock.acquire(blocking=False):
            return None, "A sensor query is already in progress"
        try:
            with self.sensor_condition:
                self.sensor_waiting = True
                self.sensor_active_sequence = None
                self.sensor_chunks = {}
                self.sensor_result = None
            error = self.send_key("z")
            if error:
                with self.sensor_condition:
                    self.sensor_waiting = False
                return None, error
            deadline = time.monotonic() + timeout
            with self.sensor_condition:
                while self.sensor_result is None:
                    remaining = deadline - time.monotonic()
                    if remaining <= 0:
                        self.sensor_waiting = False
                        self.sensor_active_sequence = None
                        self.sensor_chunks = {}
                        return None, "Timed out waiting for seven sensor data packets"
                    self.sensor_condition.wait(remaining)
                raw, sequence = self.sensor_result
                self.sensor_waiting = False
                self.sensor_active_sequence = None
                self.sensor_chunks = {}
            flags = raw[2]
            return {
                "sequence": sequence,
                "bmp_address": f"0x{raw[0] & 0x7F:02X}",
                "bmp_id": f"0x{raw[1]:02X}",
                "flags": {
                    "initialized": bool(flags & 0x80),
                    "bmp_present": bool(flags & 0x40),
                    "bmp_sample_valid": bool(flags & 0x20),
                    "aht_initialized": bool(flags & 0x10),
                    "aht_sample_valid": bool(flags & 0x08),
                    "busy_timeout": bool(flags & 0x04),
                    "i2c_timeout": bool(flags & 0x02),
                    "init_error": bool(flags & 0x01),
                },
                "bmp_calibration_raw": raw[3:27].hex(" "),
                "bmp_sample_raw": raw[27:33].hex(" "),
                "aht_sample_raw": raw[33:39].hex(" "),
            }, None
        finally:
            self.sensor_query_lock.release()

    def _capture_sensor_chunk(self, packet: bytes):
        if len(packet) != 8:
            return
        sequence, index = packet[0], packet[1]
        if index >= 7:
            return
        with self.sensor_condition:
            if not self.sensor_waiting:
                return
            if self.sensor_active_sequence is None:
                self.sensor_active_sequence = sequence
            elif sequence != self.sensor_active_sequence:
                return
            self.sensor_chunks[index] = packet[2:8]
            if all(chunk in self.sensor_chunks for chunk in range(7)):
                payload = b"".join(self.sensor_chunks[chunk] for chunk in range(7))
                self.sensor_result = (payload, sequence)
                self.sensor_waiting = False
                self.sensor_condition.notify_all()

    def send_subtitle(self, value: str):
        if self.sock is None:
            return "以太网未连接"
        if self.image_upload_active:
            return "PC 图像上传中，暂不能修改字幕"
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

    @staticmethod
    def _display_kind(data: bytes):
        decoded = unpack_display_packet(data)
        return decoded[0] if decoded else None

    def _send_display(self, data: bytes):
        sock = self.upload_sock or self.sock
        if sock is None:
            raise RuntimeError("以太网已断开")
        with self.send_lock:
            sock.sendto(data, (self.DISPLAY_IP, self.DISPLAY_PORT))

    def _wait_display(self, kind: int, timeout: float, predicate=None) -> bytes:
        deadline = time.monotonic() + timeout
        while True:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise TimeoutError(f"display board response 0x{kind:04X} timed out")
            if self.upload_sock is None:
                raise RuntimeError("PC image return socket is not open")
            try:
                self.upload_sock.settimeout(remaining)
                data, sender = self.upload_sock.recvfrom(2048)
            except OSError as exc:
                raise TimeoutError(f"display board response 0x{kind:04X} timed out") from exc
            if sender[0] != self.DISPLAY_IP:
                continue
            decoded = unpack_display_packet(data)
            if decoded is not None and decoded[0] == 0x48:
                publish_view(decoded[1], self.broadcast)
            if decoded is None or decoded[0] != kind:
                continue
            payload = decoded[1]
            if predicate is None or predicate(payload):
                return payload

    def _next_display_sequence(self) -> int:
        self.display_sequence = (self.display_sequence + 1) & 0xFF
        return self.display_sequence

    def _refresh_display_view(self, timeout: float = 2.0) -> bytes:
        """Query authoritative display state and allow sequence resynchronization."""
        global VIEW_RESYNC
        with VIEW_LOCK:
            VIEW_RESYNC = True
        sequence = self._next_display_sequence()
        self._send_display(control_packet(0x0048, bytes((sequence,))))
        return self._wait_display(0x0048, timeout, lambda body: len(body) == 16)

    def query_display_idle(self) -> bool:
        """Ask the display directly; serialize with PC image transactions."""
        if not self.is_open() or not self.image_upload_lock.acquire(blocking=False):
            return False
        try:
            import socket
            self.upload_sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
            self.upload_sock.bind((self.LOCAL_IP, 0))
            body = self._refresh_display_view(0.8)
            return not decode_view(body)["busy"]
        except (OSError, TimeoutError, RuntimeError, ValueError):
            return False
        finally:
            if self.upload_sock is not None:
                self.upload_sock.close()
                self.upload_sock = None
            self.image_upload_lock.release()

    def upload_image(self, rgb_top_down: bytes, width: int, height: int,
                     pcm: bytes = b"") -> dict:
        """Send a PC-decoded image through the display board's normal frame writer."""
        if self.sock is None:
            raise RuntimeError("请先连接以太网")
        if not self.image_upload_lock.acquire(blocking=False):
            raise RuntimeError("已有一帧 PC 图像正在传输")
        self.image_upload_active = True
        try:
            if self.upload_sock is None:
                import socket
                self.upload_sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
                self.upload_sock.bind((self.LOCAL_IP, 0))
            words, checksum = rgb24_to_native_words(rgb_top_down, width, height)

            # Establish that the display is alive, then acquire the same view
            # transaction lock used by media-board image loads.
            ready_deadline = time.monotonic() + 4.0
            while True:
                self._send_display(image_packet(0x20))
                try:
                    self._wait_display(0x20, 0.8, lambda body: body == b"\x01")
                    break
                except TimeoutError:
                    if time.monotonic() >= ready_deadline:
                        raise
            # VIEW_STATUS carries an event sequence, not the request sequence.
            status = self._refresh_display_view(3.0)
            if status[4] != 0:
                raise RuntimeError("显示板正在处理另一项图像事务，请稍后重试")
            generation = struct.unpack_from("<H", status, 1)[0]
            current_layout = status[3] & 0x03
            if current_layout != 0 and pcm:
                raise RuntimeError("PC audio upload is supported only in single-image layout")

            sequence = self._next_display_sequence()
            # Follow the active layout and lock the HDMI cursor's current
            # window, like a media-board image switch.
            prepare = struct.pack("<BBBBHH", sequence, 0, current_layout, 0xFE, generation, 0)
            self._send_display(control_packet(0x0049, prepare))
            reply = self._wait_display(0x004A, 5.0,
                                       lambda body: len(body) == 8 and body[0] == sequence)
            if reply[1] != 0:
                reason = {1: "显示板忙", 2: "不支持的布局请求", 3: "布局状态已变化"}.get(reply[1], reply[1])
                raise RuntimeError(f"显示板未接受图像准备请求：{reason}")
            target_window = reply[2] & 0x03
            target_layout = reply[3] & 0x03
            generation = struct.unpack_from("<H", reply, 4)[0]
            if target_layout != 0 and pcm:
                raise RuntimeError("PC audio upload is supported only in single-image layout")
            # The PC image is temporary content. Keep the SD index returned
            # by PREPARE so later N/P actions continue from this window's
            # previous SD selection rather than treating the PC image as a
            # directory entry.
            sd_base_index = reply[6] & 0x1F

            frame_id = self.display_frame_id
            self.display_frame_id = (self.display_frame_id + 1) & 0xFFFF
            if self.display_frame_id == 0:
                self.display_frame_id = 0x7000
            total_words = len(words) // 4
            flags = 0x08 if pcm else 0
            begin = struct.pack("<HBBIHHBBH", frame_id, sd_base_index, flags, total_words,
                                width, height, target_layout, target_window, generation)
            for attempt in range(1, 4):
                self._send_display(image_packet(0x21, begin))
                for seq, offset in enumerate(range(0, total_words, IMAGE_PACKET_WORDS)):
                    chunk = words[offset * 4:min(total_words, offset + IMAGE_PACKET_WORDS) * 4]
                    payload = struct.pack("<HH", frame_id, seq) + chunk
                    self._send_display(image_packet(0x22, payload))
                    time.sleep(self.image_packet_gap_s)
                time.sleep(0.001)
                self._send_display(image_packet(0x23, struct.pack("<HIH", frame_id, checksum, 0)))
                result = self._wait_display(
                    0x24, max(12.0, total_words / IMAGE_PACKET_WORDS * 0.01),
                    lambda body: len(body) == 3 and int.from_bytes(body[:2], "little") == frame_id
                    and (body[2] != 2 if target_layout == 0 else
                         body[2] in (1, 2) or 0x10 <= body[2] <= 0x1F))
                if (target_layout == 0 and result[2] == 0) or (target_layout != 0 and result[2] == 2):
                    break
                if result[2] != 1 and not 0x10 <= result[2] <= 0x1F:
                    raise RuntimeError(f"显示板拒绝图像事务，错误码 0x{result[2]:02X}")
                if attempt == 3:
                    raise RuntimeError("显示板连续三次拒绝图像帧校验")
            if target_layout == 0:
                self._send_display(image_packet(0x30, struct.pack("<HIH", frame_id, len(pcm), 0)))
                for seq, offset in enumerate(range(0, len(pcm), AUDIO_PACKET_SAMPLES)):
                    chunk = pcm[offset:offset + AUDIO_PACKET_SAMPLES]
                    self._send_display(image_packet(0x31, struct.pack("<HH", frame_id, seq) + chunk))
                    time.sleep(0.0005)
                time.sleep(0.001)
                self._send_display(image_packet(0x32, struct.pack("<HIH", frame_id, sum(pcm) & 0xFFFFFFFF, 0)))
                audio_result = self._wait_display(
                    0x33, max(10.0, len(pcm) / AUDIO_PACKET_SAMPLES * 0.01),
                    lambda body: len(body) == 3 and int.from_bytes(body[:2], "little") == frame_id)
                if audio_result[2] != 0:
                    raise RuntimeError("显示板未接受音频/静音事务")
                commit = self._wait_display(
                    0x24, 10.0,
                    lambda body: len(body) == 3 and int.from_bytes(body[:2], "little") == frame_id
                    and body[2] == 2)
            else:
                # Multi-view commits report RESULT=2 without a preceding 0.
                commit = result
            try:
                self._refresh_display_view()
            except Exception:
                pass
            self.broadcast({"type": "pkt", "kind": "upload",
                            "text": f"PC 图像已提交：{width}×{height}，音频样本 {len(pcm)}",
                            "ts": time.strftime("%H:%M:%S")})
            return {"frame_id": frame_id, "width": width, "height": height,
                    "words": total_words, "audio_samples": len(pcm),
                    "result": commit[2], "layout": target_layout,
                    "window": target_window, "sd_index": sd_base_index}
        except Exception:
            # A timed-out upload must not leave the web controls locked to a
            # stale busy bit after the display has already committed or aborted.
            try:
                self._refresh_display_view()
            except Exception:
                pass
            raise
        finally:
            self.image_upload_active = False
            if self.upload_sock is not None:
                try:
                    self.upload_sock.close()
                finally:
                    self.upload_sock = None
            self.image_upload_lock.release()

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
        if kind == 0x21 and length == 16:
            width = int.from_bytes(payload[8:10], "little")
            height = int.from_bytes(payload[10:12], "little")
            total_words = int.from_bytes(payload[4:8], "little")
            pixel_count = width * height
            if (width < 1 or width > 1280 or height < 1 or height > 720 or
                    total_words != (pixel_count + 1) // 2 or
                    total_words > 1280 * 720 // 2 or payload[12] != 0 or
                    payload[13] != 0 or payload[14:16] != b"\x00\x00"):
                self.snapshot = None
                self._send_snapshot_reply(0x24, struct.pack(
                    "<HB", int.from_bytes(payload[:2], "little"), 1))
                self.broadcast({"type": "pkt", "kind": "dump",
                                "text": f"PC snapshot BEGIN rejected: {width}x{height}, words={total_words}",
                                "ts": time.strftime("%H:%M:%S")})
                return
            self.snapshot = {
                "frame": int.from_bytes(payload[:2], "little"),
                "total": total_words, "width": width, "height": height,
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
            good = (got_frame == frame_id and
                    len(words) == state["total"] * 4 and state["gaps"] == 0 and
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
                    ETH_FRAME_SNAPSHOT["width"] = state["width"]
                    ETH_FRAME_SNAPSHOT["height"] = state["height"]
                    ETH_FRAME_SNAPSHOT["ts"] = ts
                    ETH_FRAME_SNAPSHOT["stride"] = 1
                    fid = ETH_FRAME_SNAPSHOT["id"]
                self.broadcast({"type": "frame", "kind": "rb", "source": "snapshot", "id": fid,
                                "words": len(state["words"]) // 4,
                                "w": state["width"], "h": state["height"],
                                "gaps": 0, "ts": ts})
            self.snapshot = None

    def _reader(self):
        buf = bytearray(2048)
        view = memoryview(buf)
        while self.sock is not None:
            try:
                n, sender = self.sock.recvfrom_into(buf)   # Preserve source board for direct replies.
                data = view[:n]
            except Exception:
                self._stream_poll()            # 超时窗口顺带查会话收口
                continue                       # 超时/关闭 → 回到 while 判据
            if sender[0] == self.DISPLAY_IP:
                decoded_display = unpack_display_packet(bytes(data))
                if decoded_display is not None:
                    kind, body = decoded_display
                    if kind == 0x48:
                        publish_view(body, self.broadcast)
                    continue
            if (n == 16 and data[:4] == b"\xAA\xBB\xCC\xDD" and
                    data[4:8] == b"\x00\x4D\x00\x08"):
                self._capture_sensor_chunk(bytes(data[8:16]))
                continue
            if n == 24 and data[:8] == b"\xAA\xBB\xCC\xDD\x00\x03\x00\x10":
                publish_view(bytes(data[8:24]), self.broadcast)
                continue
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
ETH_FRAME = {"id": 0, "data": b"", "gaps": 0, "words": 0, "ts": "", "stride": 1,
             "width": 1280, "height": 720}
ETH_FRAME_RB = {"id": 0, "data": b"", "gaps": 0, "words": 0, "ts": "", "stride": 3,
                "width": 1280, "height": 720}
ETH_FRAME_SNAPSHOT = {"id": 0, "data": b"", "gaps": 0, "words": 0, "ts": "", "stride": 1,
                      "width": 1280, "height": 720}
ETH_FRAME_LOCK = threading.Lock()


# ---------------------------------------------------------------------------
# Flask 路由
# ---------------------------------------------------------------------------
@app.route("/")
def index():
    return render_template("index.html", capabilities=PRODUCT_CAPABILITIES,
                           unavailable_keys=sorted(UNAVAILABLE_KEYS))


@app.route("/api/status")
def api_status():
    with VIDEO_LOCK:
        video_status = _video_status_locked()
    return jsonify({"serial_open": link.is_open(),
                    "serial_port": getattr(link, "port", ""),
                    "eth_available": True,
                    "eth_open": eth_link.is_open(),
                    "eth_board": eth_link.board,
                    "eth_local_port": EthTransport.LOCAL_PORT,
                    "video": video_status,
                    "loopback": isinstance(link, LoopbackLink),
                    "auto_connect": AUTO_CONNECT,
                    "baud": DEFAULT_BAUD, "view": VIEW_STATE})


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
    order = ["p", "n", "a", "s", "0", "1", "2", "3", "4", "5", "6", "7", "8", "r", "g", "b", "e", "h", "w", "-", "+", "<", ">", "[", "]",
             ",", ".", ";", "'", "q", "i", "l", "d"]
    groups = [("播放", ["p", "n", "a", "s"]),
               ("切换特效", ["0", "1", "2"]),
               ("OSD 面板", ["3", "4", "5"]),
              ("音量", ["-", "+"]),
              ("轮播周期", ["<", ">"]),
              ("亮度 / 对比度", ["[", "]", ",", "."]),
              ("音频频谱", [";", "'", "q"]),
              ("调试", ["i", "l"])]
    groups.insert(2, ("\u56fe\u50cf\u6548\u679c", ["r", "g", "b", "e", "h", "w"]))
    groups.insert(1, ("画面布局", ["6", "7", "8"]))
    return jsonify({"keys": [{"key": k, "label": HELP[k], "available": k not in UNAVAILABLE_KEYS} for k in order],
                    "capabilities": PRODUCT_CAPABILITIES,
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
    stop_video_sender()
    eth_link.close()
    return jsonify({"ok": True})


@app.route("/api/cmd", methods=["POST"])
def api_cmd():
    global VIEW_RESYNC
    d = request.get_json(force=True, silent=True) or {}
    mode = d.get("mode", "serial")
    key = d.get("key", "")
    if key in UNAVAILABLE_KEYS:
        return jsonify({"ok": False, "error": "首轮视频基线暂不支持 CV 与频谱；后续恢复"}), 409
    with VIDEO_LOCK:
        if _video_status_locked()["active"] and key not in ("s", "+", "-"):
            return jsonify({"ok": False, "error": "视频播放期间仅支持状态和音量；请先停止视频"}), 409
    with VIEW_LOCK:
        state = VIEW_STATE
        if key == "s":
            VIEW_RESYNC = True
    if state and key in ("n", "p", "d", "6", "7", "8"):
        if state["busy"]:
            return jsonify({"ok": False, "error": "板卡正在装载，请等待完成；S 可查询恢复状态"}), 409
        target = {"6": 0, "7": 1, "8": 2}.get(key)
        if target is not None and state["layout"] and target and target != state["layout"]:
            return jsonify({"ok": False, "error": "请先返回单图，再选择另一种多窗口布局"}), 409
    err = (eth_link if mode == "eth" else link).send_key(key)
    if err:
        return jsonify({"ok": False, "error": err}), 400
    return jsonify({"ok": True})


@app.route("/api/sensor/raw", methods=["POST"])
def api_sensor_raw():
    """Read a coherent raw BMP280/AHT10 snapshot from the media board."""
    with VIDEO_LOCK:
        if _video_status_locked()["active"]:
            return jsonify({"ok": False, "error": "Sensor query is unavailable while video owns the media link"}), 409
    result, error = eth_link.read_sensor_snapshot()
    if error:
        status = 503 if not eth_link.is_open() else 504 if "Timed out" in error else 409
        return jsonify({"ok": False, "error": error}), status
    return jsonify({"ok": True, "raw": result})


@app.route("/api/subtitle", methods=["POST"])
def api_subtitle():
    with VIDEO_LOCK:
        if _video_status_locked()["active"]:
            return jsonify({"ok": False, "error": "首轮视频播放期间不更新字幕；请先停止视频"}), 409
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


@app.route("/api/eth/upload-image", methods=["POST"])
def api_eth_upload_image():
    global VIDEO_IMAGE_REQUEST_ACTIVE
    with VIDEO_LOCK:
        if VIDEO_IMAGE_REQUEST_ACTIVE or _video_status_locked()["active"]:
            return jsonify({"ok": False, "error": "Another image/video transaction is active"}), 409
        VIDEO_IMAGE_REQUEST_ACTIVE = True
    try:
        return _upload_image_request()
    finally:
        with VIDEO_LOCK:
            VIDEO_IMAGE_REQUEST_ACTIVE = False


def _upload_image_request():
    with VIDEO_LOCK:
        if _video_status_locked()["active"]:
            return jsonify({"ok": False, "error": "video is active; stop video before sending a still image"}), 409
    """Convert browser-decoded RGB and send a normal 0x21..0x33 frame to .2."""
    if not eth_link.is_open():
        return jsonify({"ok": False, "error": "请先连接以太网"}), 400
    try:
        width = int(request.form.get("width", "0"))
        height = int(request.form.get("height", "0"))
        pixels_file = request.files.get("pixels")
        if pixels_file is None:
            raise ValueError("缺少图像像素数据")
        rgb = pixels_file.stream.read(1280 * 720 * 3 + 1)
        if not (1 <= width <= MAX_WIDTH and 1 <= height <= MAX_HEIGHT):
            raise ValueError("image dimensions must be within 1..1280 × 1..720")
        if len(rgb) != width * height * 3:
            raise ValueError("RGB data length does not match image dimensions")
        include_audio = request.form.get("include_audio") == "1"
        pcm = b""
        if include_audio:
            audio_file = request.files.get("audio")
            if audio_file is None or not audio_file.filename:
                raise ValueError("\u8bf7\u9009\u62e9 WAV \u6216\u542b\u97f3\u8f68\u7684 MP4\uff1b\u5173\u95ed\u97f3\u9891\u9009\u9879\u5219\u65e0\u9700\u4e0a\u4f20\u97f3\u9891")
            if audio_file.filename.lower().endswith(".wav"):
                wav_data = audio_file.stream.read(32 * 1024 * 1024 + 1)
                if len(wav_data) > 32 * 1024 * 1024:
                    raise ValueError("WAV 文件超过 32 MB")
                pcm = load_pcm_wav(wav_data, max_samples=PC_AUDIO_MAX_SAMPLES)
            else:
                pcm = transcode_audio_stream(audio_file.stream, audio_file.filename)
        result = eth_link.upload_image(rgb, width, height, pcm)
        return jsonify({"ok": True, **result})
    except ValueError as exc:
        return jsonify({"ok": False, "error": str(exc)}), 400
    except TimeoutError as exc:
        return jsonify({"ok": False, "error": str(exc)}), 504
    except RuntimeError as exc:
        return jsonify({"ok": False, "error": str(exc)}), 409
    except OSError as exc:
        return jsonify({"ok": False, "error": f"以太网图像发送失败：{exc}"}), 502


@app.route("/api/eth/video/status")
def api_eth_video_status():
    global VIDEO_RELEASE_PENDING
    with VIDEO_LOCK:
        status = _video_status_locked()
        pending = VIDEO_RELEASE_PENDING
    if pending and eth_link.query_display_idle():
        with VIDEO_LOCK:
            if VIDEO_PROCESS is None:
                VIDEO_RELEASE_PENDING = False
            status = _video_status_locked()
    return jsonify(status)


@app.route("/api/eth/video/start", methods=["POST"])
def api_eth_video_start():
    global VIDEO_PROCESS, VIDEO_PATH, VIDEO_NAME, VIDEO_LAST_EXIT
    global VIDEO_STATUS_PATH, VIDEO_LOG_PATH, VIDEO_USER_STOPPED
    if not eth_link.is_open():
        return jsonify({"ok": False, "error": "Ethernet is not connected"}), 400
    if eth_link.image_upload_active:
        return jsonify({"ok": False, "error": "An image upload is still active"}), 409
    video_file = request.files.get("video")
    if video_file is None or not video_file.filename:
        return jsonify({"ok": False, "error": "Choose a video file first"}), 400
    safe_name = os.path.basename(video_file.filename.replace("\\", "/"))
    suffix = Path(safe_name).suffix.lower()
    if suffix not in {".mp4", ".m4v", ".mov", ".mkv", ".avi", ".webm", ".wmv"}:
        return jsonify({"ok": False, "error": "Supported: MP4, MOV, MKV, AVI, WebM, WMV"}), 400
    try:
        video_width=int(os.environ.get("VIDEO_WIDTH", str(PRODUCT_PROFILE.get("width", 640))))
        video_height=int(os.environ.get("VIDEO_HEIGHT", str(PRODUCT_PROFILE.get("height", 360))))
        video_window=int(os.environ.get("VIDEO_WINDOW", str(PRODUCT_PROFILE.get("window", 512))))
        video_prefetch=int(os.environ.get("VIDEO_PREFETCH", "16"))
        if not (2<=video_width<=720 and video_width%2==0 and 1<=video_height<=360 and video_window in (32,64,128,256,512) and video_window>=video_height and 0<=video_prefetch<=16):
            raise ValueError("invalid video profile")
    except ValueError:
        return jsonify({"ok":False,"error":"Invalid VIDEO_WIDTH/VIDEO_HEIGHT/VIDEO_WINDOW; must match display bit"}),400
    ffmpeg_setting = os.environ.get("VIDEO_FFMPEG")
    try:
        ffmpeg = ((shutil.which(ffmpeg_setting) or
                   (ffmpeg_setting if Path(ffmpeg_setting).is_file() else None))
                  if ffmpeg_setting else resolve_ffmpeg())
        if not ffmpeg:
            raise ValueError(f"ffmpeg not found: {ffmpeg_setting}")
    except ValueError as exc:
        return jsonify({"ok": False, "error": str(exc)}), 400
    if not VIDEO_SCRIPT.is_file():
        return jsonify({"ok": False, "error": "scripts/direct_video_sender.py is missing"}), 500

    with VIDEO_LOCK:
        if _video_status_locked()["active"] or VIDEO_IMAGE_REQUEST_ACTIVE or eth_link.image_upload_active:
            return jsonify({"ok": False, "error": "An image/video transaction is already active"}), 409
        VIDEO_CAPTURE_DIR.mkdir(parents=True, exist_ok=True)
        fd, temp_name = tempfile.mkstemp(prefix="video_", suffix=suffix, dir=VIDEO_CAPTURE_DIR)
        os.close(fd)
        try:
            video_file.save(temp_name)
            VIDEO_STATUS_PATH = temp_name + ".status.json"
            VIDEO_LOG_PATH = temp_name + ".log"
            VIDEO_USER_STOPPED = False
            # Decode ahead off the time-critical UDP send loop. At 640x360
            # RGB565, 16 queued frames use about 7 MiB of PC RAM.
            command = [sys.executable, str(VIDEO_SCRIPT), "--input", temp_name,
                       "--frames", "0", "--once", "--quiet", "--ffmpeg", ffmpeg,
                       "--prefetch", str(video_prefetch),
                       "--status-file", VIDEO_STATUS_PATH,
                       "--width", str(video_width), "--height", str(video_height),"--window",str(video_window),"--require-ready"]
            if request.form.get("audio", "1").lower() not in ("0","false","off"):
                command.append("--audio")
            creationflags = getattr(subprocess, "CREATE_NO_WINDOW", 0) if os.name == "nt" else 0
            with open(VIDEO_LOG_PATH, "wb") as log:
                VIDEO_PROCESS = subprocess.Popen(command, cwd=VIDEO_SCRIPT.parents[1],
                                                 stdin=subprocess.DEVNULL,
                                                 stdout=log, stderr=subprocess.STDOUT,
                                                 creationflags=creationflags,
                                                 start_new_session=(os.name != "nt"))
            VIDEO_PATH = temp_name
            VIDEO_NAME = safe_name
            VIDEO_LAST_EXIT = None
        except Exception as exc:
            try:
                Path(temp_name).unlink(missing_ok=True)
            except OSError:
                pass
            VIDEO_PROCESS = None
            VIDEO_PATH = None
            VIDEO_NAME = ""
            return jsonify({"ok": False, "error": f"Could not start video sender: {exc}"}), 502
        return jsonify({"ok": True, "active": True, "state": "starting", "name": VIDEO_NAME,
                        "target": "192.168.137.2:1", "format": f"{video_width}x{video_height} RGB565 (target 2000/33 fps)"})


@app.route("/api/eth/video/stop", methods=["POST"])
def api_eth_video_stop():
    stop_video_sender()
    return jsonify({"ok": True, "active": VIDEO_RELEASE_PENDING, "state": "releasing" if VIDEO_RELEASE_PENDING else "idle"})


@app.route("/api/stream")
def api_stream():
    q = link.subscribe()

    def gen():
        try:
            # 开流先各推一条链路状态（前端据此恢复两个传输的连接态）
            for lk in (link, eth_link):
                yield f"data: {json.dumps(lk.link_msg(lk.is_open()))}\n\n"
            if VIEW_STATE is not None:
                yield f"data: {json.dumps(VIEW_STATE)}\n\n"
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
        width, height = slot.get("width", 1280), slot.get("height", 720)
    resp = Response(data, mimetype="application/octet-stream")
    resp.headers["X-Frame-Id"] = str(frame_id)
    resp.headers["X-Frame-Words"] = str(words)
    resp.headers["X-Frame-Gaps"] = str(gaps)
    resp.headers["X-Frame-Stride"] = str(stride)
    resp.headers["X-Frame-Width"] = str(width)
    resp.headers["X-Frame-Height"] = str(height)
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
