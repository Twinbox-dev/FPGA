#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
eth_probe.py — 板卡以太网通道"绕过 ARP"的连通性探针（调试用）

背景：ping/UDP 单播都要先 ARP 解析板卡 MAC，ARP 一失败整条路就试不出来。
本脚本改用**广播**发命令帧——广播帧目的 MAC 是 FF:FF:FF:FF:FF:FF，
不需要 ARP，帧直接上线路，板卡必定收到（如果物理链路正常）。

观察方法：一边跑脚本，一边看板卡七段数码管（当前固件已带诊断显示）：
    dig0 = 栈交付给 app 层的字节数（低 4 位）
    dig3 = 栈发给 MAC 的字节数（低 4 位）
脚本本身也会监听 UDP :2 收板卡回包。

用法：
    # ⚠ 先关掉 Web 控制台（它占用了 UDP :2）
    python scripts/eth_probe.py            # 50 条状态回读命令(S)
    python scripts/eth_probe.py 200        # 条数可改

判读：
    数码管 dig0 变化      → 广播包成功到达板卡 app 层（IP/端口/整条接收链 OK）
    脚本打印"收到回包"    → 板卡发送链 + 本机接收都 OK
    两者都没有            → 包没进栈（栈的 IP/端口没装载成功）
"""
import socket
import sys
import time

BOARD_IP   = "192.168.137.2"
SUBNET_BCAST = "192.168.137.255"     # 受限网段广播（走以太网口，最确定）
LIMITED_BCAST = "255.255.255.255"    # 受限广播（兜底，会走所有网口）
BOARD_PORT = 1                       # 板卡命令端口
LOCAL_PORT = 2                       # 板卡固定回包到 PC 的这个端口

HDR = bytes([0xAA, 0xBB, 0xCC, 0xDD, 0x00, 0x01, 0x00, 0x02])   # 应用头(type=1, len=2)
CMD = bytes([0x53, 0xAC])            # 'S'=状态回读，第二字节是取反校验


def main():
    n = int(sys.argv[1]) if len(sys.argv) > 1 else 50

    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
    s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    try:
        s.bind(("", LOCAL_PORT))
    except OSError as e:
        print(f"绑定 UDP :{LOCAL_PORT} 失败: {e}")
        print("→ 是不是 Web 控制台还开着？先关掉它再跑本脚本。")
        return
    s.settimeout(0.3)

    print(f"广播发送 {n} 条命令到 {SUBNET_BCAST}:{BOARD_PORT} / {LIMITED_BCAST}:{BOARD_PORT}")
    print("（同时监听回包；请留意板卡数码管 dig0 / dig3 是否变化）\n")

    got = 0
    for i in range(n):
        # 交替发给网段广播和受限广播，两条路都试
        dst = SUBNET_BCAST if (i % 2 == 0) else LIMITED_BCAST
        try:
            s.sendto(HDR + CMD, (dst, BOARD_PORT))
        except OSError as e:
            print(f"  第{i}条发送失败: {e}")
        try:
            data, addr = s.recvfrom(2048)
            got += 1
            print(f"  ← 收到回包 #{got}  来自 {addr}  {data.hex()}")
        except socket.timeout:
            pass
        time.sleep(0.05)

    print(f"\n发送完毕：共 {n} 条，收到回包 {got} 条")
    if got == 0:
        print("没收到回包。请看数码管：dig0 变了说明包进了 app 层（问题在发送链）；"
              "dig0 没变说明包根本没进栈。")
    s.close()


if __name__ == "__main__":
    main()
