#!/usr/bin/env python3
"""播放列表转储（'L' 调试命令）PC 端解码器。

用法:
  python3 scripts/pl_dump.py COM7 1000000      # 串口模式
  python3 scripts/pl_dump.py --udp [本机IP]    # 以太网模式（控制台 :5000 的同款通道）
发送 'L' 后收 N+1 个 8 字节包，解码打印播放列表跳表/配对表/光标快照。
用于排查环缺图、单向切图、切图失效类板级问题（详见 docs/uart_link.md）。
"""
import socket, struct, sys, time

TAG_ENTRY, TAG_SUM, TAG_SNAP = 0b01, 0b10, 0b11


def decode_entry(pkt):
    idx = (pkt >> 57) & 0x1F
    isbmp = (pkt >> 56) & 1
    pv = (pkt >> 55) & 1
    pw = (pkt >> 49) & 0x3F
    nx = (pkt >> 43) & 0x3F
    pr = (pkt >> 37) & 0x3F
    return idx, isbmp, pv, pw, nx, pr


def decode_sum(pkt):
    return dict(fc=(pkt >> 56) & 0x3F, bc=(pkt >> 50) & 0x3F,
                wc=(pkt >> 44) & 0x3F, fb=(pkt >> 38) & 0x3F,
                ii=(pkt >> 33) & 0x1F, fir=(pkt >> 28) & 0x1F,
                lb=(pkt >> 27) & 1, sa=(pkt >> 26) & 1,
                ld=(pkt >> 23) & 0x7)


def decode_snap(v):
    """tag 11 装载快照包：{11, result[1:0], ld[2:0], words[20:0], pix[19:0], h[11:0]}"""
    res, ld = (v >> 60) & 3, (v >> 57) & 0x7
    wc = (v >> 36) & 0x1FFFFF
    pc = (v >> 16) & 0xFFFFF
    h = (v >> 4) & 0xFFF
    rn = {0: '进行中', 1: 'img_err', 2: '超时', 3: '成功'}.get(res, res)
    return dict(res=rn, ld=ld, wc=wc, pc=pc, h=h)


def print_dump(entries, s):
    print(f"file_cnt={s['fc']} bmp_cnt={s['bc']} wav_cnt={s['wc']} "
          f"first_bmp={s['fb']} | 光标 img_idx={s['ii']} "
          f"load_busy={s['lb']} scan_active={s['sa']} ld_state={s['ld']}")
    print(f"{'idx':>3} {'类型':<4} {'配对WAV':>7} {'nxt':>4} {'prv':>4}")
    for e in entries:
        idx, isbmp, pv, pw, nx, pr = e
        typ = 'BMP' if isbmp else 'WAV'
        pair = str(pw) if pv else '-'
        nxt = str(nx) if isbmp else '-'
        prv = str(pr) if isbmp else '-'
        print(f"{idx:>3} {typ:<4} {pair:>7} {nxt:>4} {prv:>4}")
    # 环完整性自检：从 first_bmp 沿 nxt 走，应恰好经所有 BMP 回到起点
    bmps = [e[0] for e in entries if e[1]]
    if s['bc'] >= 2 and len(bmps) == s['bc'] and s['fb'] in bmps:
        seq, cur, broken = [s['fb']], s['fb'], False
        for _ in range(len(bmps)):
            nxt = entries[cur][4]
            if nxt not in bmps:
                seq.append(nxt)
                broken = True
                break
            if nxt == s['fb']:
                break
            seq.append(nxt)
            cur = nxt
        ok = (not broken and len(seq) == len(bmps)
              and entries[s['fb']][5] == seq[-1])
        print(f"nxt 环序列: {seq}{'…' if broken else ''}  →  "
              f"{'完整' if ok else '断裂！'}")
    if s['fc'] != len(entries):
        print(f"⚠ 条目包数 {len(entries)} ≠ file_cnt {s['fc']}（丢包？）")


def main():
    args = sys.argv[1:]
    udp = '--udp' in args
    entries, summary, snap = [], None, None

    def feed(data):
        nonlocal entries, summary, snap
        for k in range(0, len(data) - 7, 8):
            pkt = struct.unpack_from('>Q', data, k)[0]   # 线序 MSB 先行（与 A5 首字节一致）
            if pkt >> 56 in (0xA5, 0x5A):
                continue          # 'L' 自身的 ACK 回执（5A|4C|...），不是转储包
            tag = (pkt >> 62) & 0x3
            if tag == TAG_ENTRY:
                entries.append(decode_entry(pkt))
            elif tag == TAG_SUM:
                summary = decode_sum(pkt)
            elif tag == TAG_SNAP:
                snap = decode_snap(pkt)

    if udp:
        host = args[args.index('--udp') + 1] if len(args) > args.index('--udp') + 1 else '0.0.0.0'
        # 与 Web 控制台 EthTransport 同款：PC:2 → 板:1，板回 PC:2
        sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        sock.bind(('', 2))
        board_ip = None
        print('等待板卡 ARP…（打开控制台发一次任意命令即可让板学到 PC 的 IP）')
        sock.settimeout(30)
        t0 = time.time()
        # 应用头与控制台 EthTransport 同款：AABBCCDD + type/len，再接 [CMD,~CMD]
        hdr = bytes([0xAA, 0xBB, 0xCC, 0xDD, 0x00, 0x01, 0x00, 0x02])
        sock.sendto(hdr + b'\x4c\xb3',
                    (host if host != '0.0.0.0' else '192.168.137.2', 1))
        while summary is None and time.time() - t0 < 30:
            try:
                data, addr = sock.recvfrom(2048)
            except socket.timeout:
                break
            board_ip = addr[0]
            if len(data) >= 16 and data[:4] == b"\xAA\xBB\xCC\xDD":
                data = data[8:16]     # 板卡回包剥 8 字节应用头
            elif len(data) >= 8:
                data = data[:8]
            else:
                continue
            feed(data)
        print(f'板卡: {board_ip}' if board_ip else '超时未收到数据')
    else:
        if len(args) < 2:
            sys.exit(__doc__)
        try:
            import serial
        except ImportError:
            sys.exit('缺 pyserial：pip install pyserial')
        port, baud = args[0], int(args[1])
        ser = serial.Serial(port, baud, timeout=0.5)
        ser.write(b'\x4c\xb3')        # [CMD,~CMD]：'L'=0x4C，~CMD=0xB3
        t0 = time.time()
        buf = b''
        while summary is None and time.time() - t0 < 15:
            buf += ser.read(256)
            feed(buf)
            buf = buf[-(8 * (len(buf) // 8)):]
            time.sleep(0.05)

    if summary is None:
        print('未收到收口包（丢包/板卡未挂载？）')
        return
    if snap:
        print(f"装载快照: 结果={snap['res']} 终态ld={snap['ld']} "
              f"已发射={snap['wc']}字 解码像素={snap['pc']} 锁存高度={snap['h']}")
    entries = entries[:summary['fc']]
    print_dump(entries, summary)


if __name__ == '__main__':
    main()
