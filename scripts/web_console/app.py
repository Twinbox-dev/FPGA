#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
web_console/app.py — 板卡控制 Web 控制台（串口双控，以太网占位）

用法:
    python app.py                    # 启动服务，串口自动识别（唯一串口直接连上）
    WEB_LOOPBACK=1 python app.py     # 无板卡开发档（命令回环成假 ACK）
    WEB_NOAUTO=1 python app.py       # 关掉「唯一串口自动连接」，只自动选中不连
    浏览器打开 http://127.0.0.1:5000

架构（与 FPGA 侧 ctrl_core 分层呼应）:
    浏览器 ──HTTP POST /api/cmd──► Flask ── Transport ──► 板卡
             ◄──SSE /api/stream── │   serial: pyserial（现） │
                                  │   eth:   占位（将来）    │
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
import threading
import time

from flask import Flask, Response, jsonify, render_template, request

app = Flask(__name__)

DEFAULT_BAUD = int(os.environ.get("WEB_BAUD", "1000000"))   # 默认波特率
AUTO_CONNECT = not os.environ.get("WEB_NOAUTO")             # 唯一串口是否自动连

# ---------------------------------------------------------------------------
# 协议（原 uart_console.py 并入）：命令表 + 两类包解码
# ---------------------------------------------------------------------------
CMDS = {"n": 0x4E, "a": 0x41, "s": 0x53, "p": 0x50,
        "+": 0x2B, "-": 0x2D, ">": 0x3E, "<": 0x3C,
        "]": 0x5D, "[": 0x5B}
HELP = {"n": "下一张", "a": "自动轮播", "s": "状态回读", "p": "上一张",
        "+": "音量+", "-": "音量-", ">": "周期+1s", "<": "周期-1s",
        "]": "亮度+", "[": "亮度-"}


def send_bytes(key: str) -> bytes:
    """命令 → [CMD, ~CMD] 成对校验字节。"""
    c = CMDS[key]
    return bytes([c, c ^ 0xFF])


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

    return (f"state=0x{state:X} fat=0x{fat:02X} buf={fb & 3} img={img & 0x1F}"
            f"{'+wav' if wav & 1 else ''} | "
            f"OK: {fa_s or '-'} {fb_s or '-'} | 异常: {und_s or '无'}")


def decode_ack(pkt: bytes) -> str:
    """ACK 应答包（5A）：5A | cmd回显 | vol | period_s | img | wav | bri | 00"""
    _, cmd, vol, per, img, wav, bri = pkt[:7]
    name = {0x4E: "下一张", 0x50: "上一张", 0x41: "自动轮播",
            0x2B: "音量+", 0x2D: "音量-", 0x3E: "周期+", 0x3C: "周期-",
            0x5D: "亮度+", 0x5B: "亮度-"}.get(cmd, f"0x{cmd:02X}")
    return (f"ACK {name} | 音量={vol}/8 周期={per}s 亮度={bri}/8 "
            f"img={img & 0x1F}{'+wav' if wav & 1 else ''}")


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
# 传输抽象：serial（现）/ eth（占位）。前端只需换 mode，后端按 mode 路由。
# ---------------------------------------------------------------------------
class SerialLink:
    """pyserial 独占管理 + 读线程解码 + SSE 订阅广播。"""

    def __init__(self):
        self.ser = None
        self.port = None
        self.baud = None
        self.buf = bytearray()
        self.subs = []                       # 每个订阅者一个 queue
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
        return {"type": "link", "serial": connected, "port": self.port}

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
            self.ser.write(send_bytes(key))          # [CMD, ~CMD] 成对校验
        except Exception as e:
            self.close()
            return f"串口写入失败: {e}"
        return ""

    # ---- 读线程：字节流 → 解码包 → 广播 ----
    def _reader(self):
        buf = bytearray()
        while self.ser is not None:
            try:
                chunk = self.ser.read(64)
            except Exception:
                break
            if not chunk:
                continue
            buf.extend(chunk)
            while True:
                ia, ib = buf.find(b"\xA5"), buf.find(b"\x5A")
                cand = [x for x in (ia, ib) if x >= 0]
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
                       "kind": "status" if pkt[0] == 0xA5 else "ack",
                       "text": decode_pkt(pkt) if pkt[0] == 0xA5 else decode_ack(pkt),
                       "ts": time.strftime("%H:%M:%S")}
                self.broadcast(msg)
        self.broadcast(self.link_msg(False))


class LoopbackLink:
    """无板卡开发档：命令回环成假 ACK 包，验证 UI/SSE 全链路。"""

    def __init__(self):
        self.vol, self.per, self.bri = 8, 1, 4
        self.subs = []
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
        return {"type": "link", "serial": connected, "port": self.port}

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

        def fake():
            time.sleep(0.02)
            if key == "s":
                pkt = bytes([0xA5, 0x01, 0x08, 0x0F, 0x08, 0x00, 0x03, 0x01])
                kind = "status"
            else:
                pkt = bytes([0x5A, CMDS[key], self.vol, self.per,
                             0x03, 0x01, self.bri, 0x00])
                kind = "ack"
            self.broadcast({"type": "pkt", "kind": kind,
                            "text": decode_pkt(pkt) if kind == "status" else decode_ack(pkt),
                            "ts": time.strftime("%H:%M:%S")})
        threading.Thread(target=fake, daemon=True).start()
        return ""


link = (LoopbackLink() if os.environ.get("WEB_LOOPBACK") else SerialLink())


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
                    "eth_available": False,
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
    order = ["p", "n", "a", "s", "-", "+", "<", ">", "[", "]"]
    groups = [("播放", ["p", "n", "a", "s"]),
              ("音量", ["-", "+"]),
              ("轮播周期", ["<", ">"]),
              ("亮度", ["[", "]"])]
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


@app.route("/api/cmd", methods=["POST"])
def api_cmd():
    d = request.get_json(force=True, silent=True) or {}
    mode = d.get("mode", "serial")
    key = d.get("key", "")
    if mode == "eth":
        # 以太网占位：FPGA 侧 eth 前端落地后，在这里接 EthTransport
        return jsonify({"ok": False,
                        "error": "以太网通道尚未实现（FPGA 侧 eth 前端待开发）"}), 501
    err = link.send_key(key)
    if err:
        return jsonify({"ok": False, "error": err}), 400
    return jsonify({"ok": True})


@app.route("/api/stream")
def api_stream():
    q = link.subscribe()

    def gen():
        try:
            yield f"data: {json.dumps(link.link_msg(link.is_open()))}\n\n"
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
    app.run(host="127.0.0.1", port=5000, threaded=True)


if __name__ == "__main__":
    main()
