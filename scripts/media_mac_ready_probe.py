#!/usr/bin/env python3
"""Inspect the latest READY request in an enabled media MAC capture build.

The current product top uses MAC_CAPTURE=0. This diagnostic requires a matching
MAC_CAPTURE=1 isolated bit; the product bit will not return capture data. Close
the Web console first because this tool owns its UDP receive port.
"""
from __future__ import annotations

import argparse
import queue
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts" / "web_console"))

from app import ETH_FRAME_LOCK, ETH_FRAME_RB, EthTransport  # noqa: E402


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--timeout", type=float, default=5.0)
    parser.add_argument("--output", type=Path, default=ROOT / "boardtest" / "captures" / "media_mac_ready.bin")
    args = parser.parse_args()
    events: queue.Queue = queue.Queue()
    link = EthTransport([events])
    error = link.open()
    if error:
        raise RuntimeError(error)
    try:
        with ETH_FRAME_LOCK:
            previous_id = ETH_FRAME_RB["id"]
        # X freezes and dumps the existing 128-byte probe-B packet capture.
        payload = link._hdr(0, 1, 0, 2) + bytes((0x58, 0xA7))
        link.sock.sendto(payload, (link.board, link.BOARD_PORT))
        deadline = time.monotonic() + args.timeout + 0.6
        while time.monotonic() < deadline:
            try:
                event = events.get(timeout=min(0.5, deadline - time.monotonic()))
            except queue.Empty:
                continue
            if (event.get("type") == "frame" and event.get("kind") == "rb" and
                    event.get("source") == "probe" and event.get("id", 0) > previous_id):
                with ETH_FRAME_LOCK:
                    frame = bytes(ETH_FRAME_RB["data"])
                    words = ETH_FRAME_RB["words"]
                    gaps = ETH_FRAME_RB["gaps"]
                args.output.parent.mkdir(parents=True, exist_ok=True)
                args.output.write_bytes(frame)
                print(f"probe words={words} gaps={gaps} bytes={len(frame)} output={args.output}")
                print("first words:", " ".join(frame[i:i + 4].hex() for i in range(0, min(len(frame), 64), 4)))
                return
        raise TimeoutError("media MAC probe did not return a captured packet")
    finally:
        link.close()


if __name__ == "__main__":
    main()
