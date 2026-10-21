#!/usr/bin/env python3
"""Send paced N commands to a media board while pc_media_display_stub is listening."""
from __future__ import annotations

import argparse
import socket
import struct
import time

MAGIC = b"\xaa\xbb\xcc\xdd"
MEDIA_IP = "192.168.137.3"
PC_IP = "192.168.137.1"


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--count", type=int, default=5,
                        help="number of next-image commands after the stub's automatic first frame")
    parser.add_argument("--interval", type=float, default=4.0,
                        help="seconds between N commands; allow one image/audio transaction to finish")
    parser.add_argument("--first-delay", type=float, default=4.0,
                        help="seconds to let the automatic first frame finish before the first N")
    parser.add_argument("--timeout", type=float, default=2.0,
                        help="wait for each immediate V1 command ACK")
    parser.add_argument("--pc-ip", default=PC_IP)
    parser.add_argument("--board-ip", default=MEDIA_IP)
    args = parser.parse_args()
    if args.count < 1 or args.interval < 0 or args.first_delay < 0 or args.timeout <= 0:
        parser.error("count must be positive; intervals nonnegative; timeout positive")

    request = MAGIC + struct.pack(">HH", 1, 2) + bytes((ord("N"), ord("N") ^ 0xFF))
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as sock:
        sock.bind((args.pc_ip, 2))
        for index in range(args.count):
            time.sleep(args.first_delay if index == 0 else args.interval)
            sock.sendto(request, (args.board_ip, 1))
            deadline = time.monotonic() + args.timeout
            ack = None
            while time.monotonic() < deadline:
                sock.settimeout(max(0.01, deadline - time.monotonic()))
                try:
                    data, peer = sock.recvfrom(2048)
                except socket.timeout:
                    break
                if (peer[0] == args.board_ip and len(data) == 16 and data[:8] ==
                        MAGIC + struct.pack(">HH", 2, 8) and data[8:10] == b"\x5a\x4e"):
                    ack = data[8:]
                    break
            if ack is None:
                print(f"N {index + 1}: no immediate V1 ACK; command still sent", flush=True)
            else:
                print(f"N {index + 1}: ACK payload={ack.hex()} img={ack[4] & 0x1f} wav={bool(ack[5] & 1)}",
                      flush=True)


if __name__ == "__main__":
    main()
