#!/usr/bin/env python3
"""Verify the independent media-board Ethernet endpoint on UDP port 1.

The board always sends its response to 192.168.137.1:2. Stop the existing Web
console before running this probe because it also binds UDP port 2.
"""

import argparse
import socket
import time


BOARD_IP = "192.168.137.3"
PC_PORT = 2
BOARD_PORT = 1
HEADER = bytes.fromhex("aa bb cc dd 00 01 00 02")
REPLY_HEADER = bytes.fromhex("aa bb cc dd 00 02 00 08")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--count", type=int, default=3)
    parser.add_argument("--interval", type=float, default=0.2)
    args = parser.parse_args()

    if args.count < 1 or args.interval < 0:
        parser.error("count must be positive and interval nonnegative")

    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as sock:
        sock.bind(("", PC_PORT))
        sock.settimeout(1.0)
        for sequence in range(args.count):
            command = ord("S")
            sock.sendto(HEADER + bytes((command, command ^ 0xFF)),
                        (BOARD_IP, BOARD_PORT))
            deadline = time.monotonic() + 1.0
            while True:
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    print(f"{sequence + 1}: timeout")
                    break
                sock.settimeout(remaining)
                try:
                    data, address = sock.recvfrom(2048)
                except socket.timeout:
                    print(f"{sequence + 1}: timeout")
                    break
                expected = REPLY_HEADER + bytes.fromhex("e1 53 45 4d 00 00 00 00")
                if address[0] == BOARD_IP and data == expected:
                    print(f"{sequence + 1}: media board reply OK ({address[0]})")
                    break
                print(f"{sequence + 1}: ignored {address[0]}:{address[1]} {data.hex()}")
            time.sleep(args.interval)


if __name__ == "__main__":
    main()
