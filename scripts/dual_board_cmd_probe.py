#!/usr/bin/env python3
"""Probe PC -> media board -> display board -> PC command forwarding.

Run after burning the media board's command-relay bit.  The display board keeps
its stable single-board bit.  Stop the Web console before binding UDP port 2.
"""

import argparse
import socket
import time


PC_PORT = 2
MEDIA_IP = "192.168.137.3"
DISPLAY_IP = "192.168.137.2"
HEADER = bytes.fromhex("aa bb cc dd 00 01 00 02")
REPLY_HEADER = bytes.fromhex("aa bb cc dd 00 02 00 08")
STATUS_CMD = ord("S")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--count", type=int, default=3)
    parser.add_argument("--chunks", type=int, default=0,
                        help="also send this many synthetic media chunks")
    args = parser.parse_args()
    if args.count < 1 or args.chunks < 0:
        parser.error("count must be positive and chunks nonnegative")

    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as sock:
        sock.bind(("", PC_PORT))
        for index in range(args.count):
            sock.sendto(HEADER + bytes((STATUS_CMD, STATUS_CMD ^ 0xFF)),
                        (MEDIA_IP, 1))
            deadline = time.monotonic() + 1.5
            while True:
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    print(f"{index + 1}: timeout")
                    break
                sock.settimeout(remaining)
                try:
                    data, address = sock.recvfrom(2048)
                except socket.timeout:
                    print(f"{index + 1}: timeout")
                    break
                if (address[0] == DISPLAY_IP and len(data) == 16
                        and data.startswith(REPLY_HEADER + b"\xa5")):
                    print(f"{index + 1}: display status via media OK "
                          f"({address[0]}, {data.hex()})")
                    break
                print(f"{index + 1}: ignored {address[0]}:{address[1]} {data.hex()}")
            time.sleep(0.2)

        for index in range(args.chunks):
            command = ord("M")
            sock.sendto(HEADER + bytes((command, command ^ 0xFF)),
                        (MEDIA_IP, 1))
            print(f"chunk {index + 1}: trigger sent; check display-board 7-segment count")
            time.sleep(0.3)


if __name__ == "__main__":
    main()
