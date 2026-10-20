"""Protocol unit test for the Web console's formal PC snapshot receiver."""
from __future__ import annotations

import queue
import struct

from app import ETH_FRAME_LOCK, ETH_FRAME_RB, EthTransport


class FakeSocket:
    def __init__(self):
        self.sent: list[tuple[bytes, tuple[str, int]]] = []

    def sendto(self, data: bytes, addr: tuple[str, int]):
        self.sent.append((data, addr))


def packet(kind: int, payload: bytes) -> bytes:
    return b"\xaa\xbb\xcc\xdd" + struct.pack("<HH", kind, len(payload)) + payload


def main():
    events = queue.Queue()
    link = EthTransport([events])
    fake = FakeSocket()
    link.sock = fake  # type: ignore[assignment]
    link.board = "192.168.137.3"
    old_slot = dict(ETH_FRAME_RB)
    frame_id = 0x4242
    total_words = 1280 * 720 // 2

    try:
        begin = struct.pack("<HBBI", frame_id, 4, 0x10, total_words)
        link._on_snapshot(packet(0x21, begin))
        seq = 0
        for first in range(0, total_words, 253):
            count = min(253, total_words - first)
            payload = struct.pack("<HH", frame_id, seq) + bytes(count * 4)
            link._on_snapshot(packet(0x22, payload))
            seq += 1
        link._on_snapshot(packet(0x23, struct.pack("<HIH", frame_id, 0, 0)))
        if fake.sent[-1][0][4:8] != bytes((0x24, 0, 3, 0)) or fake.sent[-1][0][10] != 0:
            raise AssertionError("image RESULT=0 was not sent")

        link._on_snapshot(packet(0x30, struct.pack("<HIH", frame_id, 0, 0)))
        link._on_snapshot(packet(0x32, struct.pack("<HIH", frame_id, 0, 0)))
        replies = [(p[0][4], p[0][10]) for p in fake.sent]
        if replies[-2:] != [(0x33, 0), (0x24, 2)]:
            raise AssertionError(f"audio/commit replies incorrect: {replies[-2:]}")
        with ETH_FRAME_LOCK:
            if (ETH_FRAME_RB["words"] != total_words or ETH_FRAME_RB["gaps"] != 0 or
                    ETH_FRAME_RB["stride"] != 1 or len(ETH_FRAME_RB["data"]) != total_words * 4):
                raise AssertionError("committed frame metadata incorrect")
        event = events.get_nowait()
        if event["type"] != "frame" or event["kind"] != "rb" or event["gaps"] != 0:
            raise AssertionError(f"snapshot event incorrect: {event}")
        print("PASS: PC snapshot image/audio/commit replies and full-frame canvas metadata")
    finally:
        with ETH_FRAME_LOCK:
            ETH_FRAME_RB.clear()
            ETH_FRAME_RB.update(old_slot)


if __name__ == "__main__":
    main()
