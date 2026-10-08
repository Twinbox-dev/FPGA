"""Fast PC-side checks for the serial/UDP subtitle transaction."""
import os

os.environ["WEB_LOOPBACK"] = "1"

from app import CMDS, EthTransport, app, decode_ack, link, subtitle_bytes


def main():
    assert subtitle_bytes("N0P!") == bytes([0x54, 0x84, 0xCE, 0xB0, 0xD0, 0xA1, 0x80, 0x8B])
    assert len(subtitle_bytes("A" * 160)) == 164
    for size in range(161):
        encoded = subtitle_bytes("N" * size)
        assert all(byte not in CMDS.values() for byte in encoded[1:]), size
    client = app.test_client()
    assert client.post("/api/subtitle", json={"mode": "serial", "text": ""}).status_code == 200
    assert client.post("/api/subtitle", json={"mode": "serial", "text": "N0P!"}).status_code == 200
    assert link.subtitle == "N0P!"
    assert "校验通过" in decode_ack(bytes([0x5A, 0x54, 8, 1, 0, 0, 0x44, 0x80]))
    assert "失败" in decode_ack(bytes([0x5A, 0x54, 8, 1, 0, 0, 0x44, 0x00]))
    for invalid in ("A" * 161, "line\nbreak", "中文"):
        assert client.post("/api/subtitle", json={"mode": "serial", "text": invalid}).status_code == 400
    assert {"3", "4", "5"}.issubset({k["key"] for k in client.get("/api/keys").json["keys"]})

    class FakeSocket:
        def __init__(self):
            self.packets = []

        def sendto(self, payload, target):
            self.packets.append((payload, target))

    eth = EthTransport()
    eth.sock = FakeSocket()
    assert eth.send_subtitle("N0P!") == ""
    packets = eth.sock.packets
    assert len(packets) == len(subtitle_bytes("N0P!"))
    for (packet, target), byte in zip(packets, subtitle_bytes("N0P!")):
        assert packet == bytes([0xAA, 0xBB, 0xCC, 0xDD, 0, 1, 0, 2, byte, byte ^ 0xFF])
        assert target == (eth.board, eth.BOARD_PORT)
    print("PASS subtitle PC transport: validation, loopback, Ethernet packet framing")


if __name__ == "__main__":
    main()
