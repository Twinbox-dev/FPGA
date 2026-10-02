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

    auto_on = (fb >> 4) & 1              # flagB 字节空出的 bit4 = 自动轮播开关

    return (f"state=0x{state:X} fat=0x{fat:02X} buf={fb & 3} img={img & 0x1F}"
            f"{'+wav' if wav & 1 else ''} | "
            f"自动轮播={'开' if auto_on else '关'} | "
            f"OK: {fa_s or '-'} {fb_s or '-'} | 异常: {und_s or '无'}")


def decode_ack(pkt: bytes) -> str:
    """ACK 应答包（5A）：5A | cmd回显 | vol | period_s | img | wav | bri | flags
    flags bit0 = 自动轮播开关当前状态（板端 sd_card_bmp 遥测，ctrl_core 打包）

    显示策略：板子照旧回**全量** 8 字节（协议不变），但这里**只显示这条命令
    相关的那一项**——调音量就只报音量、调亮度就只报亮度，不然每条 ACK 都吐
    一大串，操作起来很乱。想要全景请按 'S'（状态包，显示全部）。"""
    _, cmd, vol, per, img, wav, bri, flags = pkt[:8]
    name = {0x4E: "下一张", 0x50: "上一张", 0x41: "自动轮播",
            0x2B: "音量+", 0x2D: "音量-", 0x3E: "周期+", 0x3C: "周期-",
            0x5D: "亮度+", 0x5B: "亮度-"}.get(cmd, f"0x{cmd:02X}")
    img_s = f"img={img & 0x1F}{'+wav' if wav & 1 else ''}"
    if   cmd in (0x2B, 0x2D): detail = f"音量={vol}/8"
    elif cmd in (0x3E, 0x3C): detail = f"周期={per}s"
    elif cmd in (0x5D, 0x5B): detail = f"亮度={bri}/8"
    elif cmd == 0x41:         detail = f"自动轮播={'开' if flags & 1 else '关'}"
    elif cmd in (0x4E, 0x50): detail = img_s
    else:                     detail = (f"音量={vol}/8 周期={per}s 亮度={bri}/8 "
                                        f"{img_s} 自动轮播={'开' if flags & 1 else '关'}")
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

    mode = "serial"

    def __init__(self, subs=None):
        self.vol, self.per, self.bri = 8, 1, 4
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


class EthTransport:
    """以太网传输：UDP socket 直连板卡（板载官方 UDP 栈，无连接、无握手）。

    板卡侧（eth_subsys.v）：本地 192.168.137.2:1，回包固定发 PC 192.168.137.1:2
    （目的端口/IP 在 FPGA 里写死，不做动态学习）。
    PC 侧：bind :2 收包，发往板卡 :1。命令帧与串口同款 [CMD,~CMD]，
    UDP 载荷 = 8 字节应用头 [AA BB CC DD type length] + 数据（APUG013）。

    注意：Windows 防火墙首次会弹窗询问是否放行 python 监听 UDP，需允许；
    本机须有 192.168.137.1/24 地址（与板卡同网段），否则回包出不去。
    """

    mode = "eth"
    BOARD_DEFAULT = os.environ.get("WEB_ETH_BOARD", "192.168.137.2")
    BOARD_PORT = int(os.environ.get("WEB_ETH_PORT", "1"))
    LOCAL_PORT = int(os.environ.get("WEB_ETH_LOCAL_PORT", "2"))

    @staticmethod
    def _hdr(type_hi, type_lo, len_hi, len_lo):
        return bytes([0xAA, 0xBB, 0xCC, 0xDD, type_hi, type_lo, len_hi, len_lo])

    def __init__(self, subs=None):
        self.sock = None
        self.board = self.BOARD_DEFAULT
        self.subs = subs if subs is not None else []
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
                "serial": connected,              # 兼容旧前端字段名
                "port": f"{self.board}:{self.LOCAL_PORT}"}

    # ---- 开关 ----
    def open(self, board: str = "", _baud=None) -> str:
        import socket
        with self.lock:
            if self.sock is not None:
                return "以太网已连接，请先断开"
            self.board = (board or "").strip() or self.BOARD_DEFAULT
            try:
                s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
                s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
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
            self.sock.sendto(payload, (self.board, self.BOARD_PORT))
        except Exception as e:
            return f"UDP 发送到 {self.board}:{self.BOARD_PORT} 失败: {e}"
        return ""

    # ---- 读线程：UDP 报文 → 剥 8 字节头 → 解码包 → 广播 ----
    def _reader(self):
        while self.sock is not None:
            try:
                data, _ = self.sock.recvfrom(2048)
            except Exception:
                continue                          # 超时/关闭 → 回到 while 判据
            if len(data) >= 16 and data[:4] == b"\xAA\xBB\xCC\xDD":
                pkt = bytes(data[8:16])           # 应用头 + 8 字节包
            elif len(data) >= 8:
                pkt = bytes(data[:8])
            else:
                continue
            if pkt[0] not in (0xA5, 0x5A):
                continue
            msg = {"type": "pkt",
                   "kind": "status" if pkt[0] == 0xA5 else "ack",
                   "text": decode_pkt(pkt) if pkt[0] == 0xA5 else decode_ack(pkt),
                   "ts": time.strftime("%H:%M:%S")}
            self.broadcast(msg)
        self.broadcast(self.link_msg(False))


# 两条链路共享同一份 SSE 订阅表：任一链路广播都推给所有订阅者，
# 前端不需要知道后端有几个传输（切模式只是换发送路径）。
SUBS = []
link = (LoopbackLink(SUBS) if os.environ.get("WEB_LOOPBACK") else SerialLink(SUBS))
eth_link = EthTransport(SUBS)


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


@app.route("/api/eth/connect", methods=["POST"])
def api_eth_connect():
    d = request.get_json(force=True, silent=True) or {}
    err = eth_link.open(d.get("board", ""))
    return (jsonify({"ok": False, "error": err}), 400) if err else jsonify({"ok": True})


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
