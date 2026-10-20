#!/usr/bin/env python3
"""Ask the media FPGA for its V1 D probe stream and compare with golden BMPs."""
from __future__ import annotations

import argparse
import socket
import struct
import time
from pathlib import Path

MAGIC = b"\xaa\xbb\xcc\xdd"


def bmp_source_words(path: Path) -> tuple[int, int, bytes]:
    data = path.read_bytes()
    if data[:2] != b"BM" or len(data) < 54:
        raise ValueError(f"not a BMP: {path}")
    offset = struct.unpack_from("<I", data, 10)[0]
    width, signed_height = struct.unpack_from("<ii", data, 18)
    planes, bpp = struct.unpack_from("<HH", data, 26)
    compression = struct.unpack_from("<I", data, 30)[0]
    if width <= 0 or signed_height <= 0 or planes != 1 or bpp != 24 or compression != 0:
        raise ValueError(f"unsupported BMP: {path} ({width}x{signed_height}, {bpp}bpp)")
    height = signed_height
    stride = (width * 3 + 3) & ~3
    pixels = bytearray()
    half: int | None = None
    for row in range(height):
        base = offset + row * stride
        for x in range(width):
            b, g, r = data[base + x * 3:base + x * 3 + 3]
            rgb565 = ((r >> 3) << 11) | ((g >> 2) << 5) | (b >> 3)
            if half is None:
                half = rgb565
            else:
                pixels.extend(struct.pack("<HH", half, rgb565))
                half = None
    if half is not None:
        pixels.extend(struct.pack("<HH", half, 0))
    return width, height, bytes(pixels)


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--board-ip", default="192.168.137.3")
    ap.add_argument("--pc-ip", default="192.168.137.1")
    ap.add_argument("--port", type=int, default=2)
    ap.add_argument("--golden-dir", type=Path, default=Path("img/golden"))
    ap.add_argument("--output", type=Path, default=Path("boardtest/captures/media_d_probe.rgb565le"))
    ap.add_argument("--idle-seconds", type=float, default=1.5)
    ap.add_argument("--timeout-seconds", type=float, default=30.0)
    ap.add_argument("--attempts", type=int, default=3)
    args = ap.parse_args()

    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    if hasattr(socket, "SO_EXCLUSIVEADDRUSE"):
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_EXCLUSIVEADDRUSE, 1)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 16 * 1024 * 1024)
    sock.bind((args.pc_ip, args.port))
    try:
        for attempt in range(1, args.attempts + 1):
            sock.setblocking(False)
            while True:
                try:
                    sock.recvfrom(2048)
                except BlockingIOError:
                    break
            sock.setblocking(True)
            # V1 command envelope: big endian type/length and [D, ~D].
            req = MAGIC + struct.pack(">HH", 1, 2) + b"D\xbb"
            sock.sendto(req, (args.board_ip, 1))
            print(f"D probe request {attempt}/{args.attempts} -> {args.board_ip}:1", flush=True)
            chunks: dict[int, bytes] = {}
            malformed = 0
            deadline = time.monotonic() + args.timeout_seconds
            last_data = time.monotonic()
            while time.monotonic() < deadline:
                remaining = min(0.25, deadline - time.monotonic())
                sock.settimeout(max(0.01, remaining))
                try:
                    packet, _ = sock.recvfrom(2048)
                except socket.timeout:
                    if chunks and time.monotonic() - last_data >= args.idle_seconds:
                        break
                    continue
                if len(packet) >= 8 and packet[:4] == MAGIC and packet[4:6] != b"\x03\x00":
                    print(f"RX other type=0x{int.from_bytes(packet[4:6], 'little'):04x} "
                          f"len={len(packet)}", flush=True)
                    continue
                if len(packet) < 10 or packet[:6] != MAGIC + b"\x03\x00":
                    continue
                declared = int.from_bytes(packet[6:8], "little")
                payload = packet[8:]
                if declared != len(payload) or len(payload) < 6 or (len(payload) - 2) % 4:
                    malformed += 1
                    continue
                seq = int.from_bytes(payload[:2], "little")
                chunks[seq] = payload[2:]
                last_data = time.monotonic()

            if not chunks:
                print(f"attempt {attempt}: no type 0x0003 data", flush=True)
                continue
            max_seq = max(chunks)
            missing = [seq for seq in range(max_seq + 1) if seq not in chunks]
            captured = b"".join(chunks[seq] for seq in range(max_seq + 1) if seq in chunks)
            print(f"attempt {attempt}: packets={len(chunks)} words={len(captured)//4} "
                  f"max_seq={max_seq} missing={len(missing)} malformed={malformed}", flush=True)
            if missing:
                continue

            args.output.parent.mkdir(parents=True, exist_ok=True)
            args.output.write_bytes(captured)
            for bmp in sorted(args.golden_dir.glob("*.BMP")):
                try:
                    width, height, expected = bmp_source_words(bmp)
                except ValueError:
                    continue
                if captured == expected:
                    print(f"PASS: exact D probe match: {bmp.name} {width}x{height}; "
                          f"raw={args.output}", flush=True)
                    return
            print("captured stream did not exactly match a golden BMP; raw saved for inspection", flush=True)
            raise SystemExit(1)
        raise SystemExit("D probe did not return a complete frame")
    finally:
        sock.close()


if __name__ == "__main__":
    main()
