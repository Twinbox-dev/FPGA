#!/usr/bin/env python3
"""Smoke-test PC -> media -> display absolute-volume control and ACK.

The media board is the PC-facing endpoint. It forwards volume changes to the
display board and returns the display-applied value to PC UDP port 2. Close the
Web console before running because it owns that port.
"""

from __future__ import annotations

import argparse
import socket
import struct
import time

MAGIC = b"\xaa\xbb\xcc\xdd"
MEDIA_IP = "192.168.137.3"
MEDIA_PORT = 1
PC_PORT = 2


def packet(kind: int, payload: bytes) -> bytes:
    return MAGIC + struct.pack(">HH", kind, len(payload)) + payload


def send_key(sock: socket.socket, key: str, timeout: float) -> tuple[int, bytes]:
    command = ord(key)
    sock.sendto(packet(0x0001, bytes((command, command ^ 0xFF))),
                (MEDIA_IP, MEDIA_PORT))
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        sock.settimeout(max(0.01, deadline - time.monotonic()))
        try:
            data, address = sock.recvfrom(2048)
        except socket.timeout:
            break
        if (address[0] != MEDIA_IP or len(data) != 16 or data[:4] != MAGIC
                or data[4:8] != b"\x00\x02\x00\x08"):
            continue
        payload = data[8:]
        if payload[0] == 0x5A and payload[1] == command:
            return payload[2], data
    raise TimeoutError(f"no matching ACK for key {key!r} within {timeout:g}s")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--pc-ip", default="192.168.137.1")
    parser.add_argument("--count", type=int, default=1,
                        help="number of volume change/restore cycles")
    parser.add_argument("--timeout", type=float, default=5.0,
                        help="seconds to wait for each board ACK")
    args = parser.parse_args()
    if args.count < 1 or args.timeout <= 0:
        parser.error("count and timeout must be positive")

    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as sock:
        sock.bind((args.pc_ip, PC_PORT))
        for index in range(args.count):
            current, status = send_key(sock, "S", args.timeout)
            if not 0 <= current <= 8:
                raise RuntimeError(f"invalid volume in status: {current}")

            if current > 0:
                changed, changed_key, restored_key = current - 1, "-", "+"
            else:
                changed, changed_key, restored_key = current + 1, "+", "-"
            actual, change_ack = send_key(sock, changed_key, args.timeout)
            if actual != changed:
                raise RuntimeError(
                    f"display did not apply volume {changed}: ACK reported {actual}"
                )
            restored, restore_ack = send_key(sock, restored_key, args.timeout)
            if restored != current:
                raise RuntimeError(
                    f"volume restore failed: expected {current}, ACK reported {restored}"
                )
            print(
                f"{index + 1}: status={current}/8; display ACK {changed_key}="
                f"{actual}/8; restore ACK {restored_key}={restored}/8"
            )
            print(f"   status {status.hex()} | change {change_ack.hex()} | restore {restore_ack.hex()}")

    print("PASS: media forwarded each volume setting to the display; original value restored.")


if __name__ == "__main__":
    main()
