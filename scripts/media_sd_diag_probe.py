#!/usr/bin/env python3
"""Query media-board SD mode and latest read timing over UDP.

The probe sends the existing two-byte command frame `I,~I` inside the V1
control datagram. The media board replies with UDP type 0x0047, 8-byte payload:
`A6 | flags | image-read cycles (u32 LE) | last-sector cycles (u16 LE)`.
If initialization fails with a CMD response-start timeout, the last field is
repurposed as the first TX mismatch bit position/values and the last eight CMD
input samples.
Flags are bit7 initialized, bit6 SDHC, bit5 High Speed supported, bit4 active,
bit3 marks a live debug word, and bits2:0 hold the low host-state bits. The
debug word packs the host-state high bits, CMD state, error code and response tail.
"""

from __future__ import annotations

import argparse
import socket
import struct
import time


MAGIC = b"\xAA\xBB\xCC\xDD"
MEDIA_IP = "192.168.137.3"
MEDIA_PORT = 1
PC_PORT = 2
REQUEST = MAGIC + struct.pack(">HH", 1, 2) + bytes((ord("I"), ord("I") ^ 0xFF))
REPLY_PREFIX = MAGIC + struct.pack(">HH", 0x0047, 8)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--pc-ip", default="192.168.137.1")
    parser.add_argument("--board-ip", default=MEDIA_IP)
    parser.add_argument("--timeout", type=float, default=3.0)
    args = parser.parse_args()
    if args.timeout <= 0:
        parser.error("timeout must be positive")

    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as sock:
        sock.bind((args.pc_ip, PC_PORT))
        sock.settimeout(args.timeout)
        sock.sendto(REQUEST, (args.board_ip, MEDIA_PORT))
        deadline = time.monotonic() + args.timeout
        while True:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise TimeoutError("media board did not return SD diagnostic type 0x0047")
            sock.settimeout(remaining)
            data, address = sock.recvfrom(2048)
            if address[0] != args.board_ip or len(data) < 16 or data[:8] != REPLY_PREFIX:
                continue
            payload = data[8:16]
            if payload[0] != 0xA6:
                continue
            flags = payload[1]
            print(f"diagnostic payload={payload.hex()}")
            image_cycles = int.from_bytes(payload[2:6], "little")
            sector_cycles = int.from_bytes(payload[6:8], "little")
            initialized = bool(flags & 0x80)
            high_capacity = bool(flags & 0x40)
            supported = bool(flags & 0x20)
            active = bool(flags & 0x10)
            debug_active = bool(flags & 0x08)
            state = flags & 0x07
            failure = {
                1: "response start timeout",
                2: "R2 frame/reserved bits",
                3: "R2 CRC7",
                4: "R1 frame/command index",
                5: "R1 CRC7",
                6: "CMD55 did not set APP_CMD",
            }.get(state, "")
            print(f"media={address[0]} initialized={initialized} SDHC={high_capacity}")
            print(f"High Speed supported={supported} active={active} host-state-low={state}")
            if failure and not initialized:
                print(f"initialization failure: {failure}")
            print(f"latest image-source time={image_cycles / 50_000_000:.6f}s")
            if not initialized and state == 1:
                mismatch_position = (sector_cycles >> 10) & 0x3F
                expected_bit = (sector_cycles >> 9) & 1
                sampled_bit = (sector_cycles >> 8) & 1
                response_tail = sector_cycles & 0xFF
                mismatch = "none" if mismatch_position == 0x3F else (
                    f"bit{mismatch_position} expected={expected_bit} sampled={sampled_bit}")
                print(f"timeout command=CMD55 tx_mismatch={mismatch} response_tail=0x{response_tail:02X}")
            elif initialized and debug_active:
                live_host_state = (((sector_cycles >> 13) & 0x7) << 3) | state
                cmd_state=(sector_cycles >> 10) & 0x7
                cmd_error=(sector_cycles >> 7) & 0x7
                response_tail=sector_cycles & 0x7F
                cmd_states={0:"IDLE",1:"PREPARE",2:"SEND",3:"RELEASE",
                            4:"WAIT_REPLY",5:"READ_REPLY",6:"GAP",7:"FINISH"}
                print(f"live host-state={live_host_state} CMD state={cmd_states[cmd_state]} "
                      f"error_code={cmd_error} response_tail=0x{response_tail:02X}")
            elif initialized:
                if sector_cycles != 0:
                    print(f"latest successful sector transaction={sector_cycles / 100:.2f}us (u16 counter)")
                else:
                    print("no completed sector yet")
            if not initialized:
                raise RuntimeError("SD host is not initialized")
            if supported and not active:
                raise RuntimeError("card supports High Speed but the host did not switch to it")
            if not supported:
                print("NOTE: card is operating in native 25 MHz mode; High Speed is not validated")
            return


if __name__ == "__main__":
    main()
