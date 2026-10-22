"""Protocol unit test for the Web console's formal PC snapshot receiver."""
from __future__ import annotations

import queue
import struct

from app import (ETH_FRAME_LOCK, ETH_FRAME_RB, ETH_FRAME_SNAPSHOT,
                 EthTransport, app, decode_pkt)


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
    old_probe = dict(ETH_FRAME_RB)
    old_snapshot = dict(ETH_FRAME_SNAPSHOT)
    probe_sentinel = {**old_probe, "id": 77, "data": b"probe", "gaps": 2,
                      "words": 1, "ts": "probe", "stride": 3}
    with ETH_FRAME_LOCK:
        ETH_FRAME_RB.update(probe_sentinel)
    frame_id = 0x4242
    width, height = 3, 3
    total_words = (width * height + 1) // 2

    try:
        begin = struct.pack("<HBBIHHBBH", frame_id, 4, 0x10, total_words,
                            width, height, 0, 0, 0)
        link._on_snapshot(packet(0x21, begin))
        payload = struct.pack("<HH", frame_id, 0) + bytes(total_words * 4)
        link._on_snapshot(packet(0x22, payload))
        link._on_snapshot(packet(0x23, struct.pack("<HIH", frame_id, 0, 0)))
        if fake.sent[-1][0][4:8] != bytes((0x24, 0, 3, 0)) or fake.sent[-1][0][10] != 0:
            raise AssertionError("image RESULT=0 was not sent")

        link._on_snapshot(packet(0x30, struct.pack("<HIH", frame_id, 0, 0)))
        link._on_snapshot(packet(0x32, struct.pack("<HIH", frame_id, 0, 0)))
        replies = [(p[0][4], p[0][10]) for p in fake.sent]
        if replies[-2:] != [(0x33, 0), (0x24, 2)]:
            raise AssertionError(f"audio/commit replies incorrect: {replies[-2:]}")
        with ETH_FRAME_LOCK:
            if (ETH_FRAME_SNAPSHOT["words"] != total_words or ETH_FRAME_SNAPSHOT["gaps"] != 0 or
                    ETH_FRAME_SNAPSHOT["stride"] != 1 or
                    ETH_FRAME_SNAPSHOT["width"] != width or ETH_FRAME_SNAPSHOT["height"] != height or
                    len(ETH_FRAME_SNAPSHOT["data"]) != total_words * 4):
                raise AssertionError("committed frame metadata incorrect")
            if ETH_FRAME_RB != probe_sentinel:
                raise AssertionError("formal snapshot overwrote the 3:1 probe buffer")
        event = events.get_nowait()
        if (event["type"] != "frame" or event["kind"] != "rb" or
                event["source"] != "snapshot" or event["gaps"] != 0 or
                event["w"] != width or event["h"] != height):
            raise AssertionError(f"snapshot event incorrect: {event}")
        client = app.test_client()
        response = client.get("/api/frame?slot=snapshot")
        if (response.status_code != 200 or len(response.data) != total_words * 4 or
                response.headers.get("X-Frame-Id") != str(ETH_FRAME_SNAPSHOT["id"]) or
                response.headers.get("X-Frame-Width") != str(width) or
                response.headers.get("X-Frame-Height") != str(height)):
            raise AssertionError("snapshot endpoint did not return its isolated full frame")
        if "error=3" not in decode_pkt(bytes((0xA5, 0x39, 0, 0, 0, 0, 3, 0))):
            raise AssertionError("media TX error/state status was not decoded")
        if "checksum" not in decode_pkt(bytes((0xA5, 0xC9, 0, 0, 0, 0, 3, 0))):
            raise AssertionError("detailed display reject reason was not decoded")
        print("PASS: variable-size raw PC snapshot ACKs, dimensions, endpoint and status decoding")
    finally:
        with ETH_FRAME_LOCK:
            ETH_FRAME_RB.clear()
            ETH_FRAME_RB.update(old_probe)
            ETH_FRAME_SNAPSHOT.clear()
            ETH_FRAME_SNAPSHOT.update(old_snapshot)


if __name__ == "__main__":
    main()
