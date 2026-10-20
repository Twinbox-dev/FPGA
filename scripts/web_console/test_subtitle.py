"""Fast PC-side checks for the serial/UDP subtitle transaction."""
import os

os.environ["WEB_LOOPBACK"] = "1"

from app import CMDS, EthTransport, app, decode_ack, eth_link, link, subtitle_bytes


def main():
    assert subtitle_bytes("N0P!") == bytes([0x54, 0x84, 0xCE, 0xB0, 0xD0, 0xA1, 0x80, 0x8B])
    assert len(subtitle_bytes("A" * 160)) == 164
    for size in range(161):
        encoded = subtitle_bytes("N" * size)
        assert all(byte not in CMDS.values() for byte in encoded[1:]), size
    client = app.test_client()
    page = client.get("/").get_data(as_text=True)
    assert 'id="ethIp"' not in page
    assert 'connState.eth && !connState.serial ? "eth"' in page
    assert 'localStorage.setItem("fpga-web-mode", m)' in page
    assert client.post("/api/subtitle", json={"mode": "serial", "text": ""}).status_code == 200
    assert client.post("/api/subtitle", json={"mode": "serial", "text": "N0P!"}).status_code == 200
    assert link.subtitle == "N0P!"
    diag_ack = decode_ack(bytes([0x5A, 0x54, 0x40, 1, 4, 0xA5, 0x40, 0x00]))
    assert "FPGA_TAG=5 FPGA_ERR=2" in diag_ack
    assert "SUB_LEN=1 RX_COUNT=4 WIRE=40 CALC=40" in diag_ack
    assert "COMMIT=OK" in decode_ack(bytes([0x5A, 0x54, 8, 1, 0, 0, 0x44, 0x80]))
    assert "COMMIT=NO" in decode_ack(bytes([0x5A, 0x54, 8, 1, 0, 0, 0x44, 0x00]))
    for invalid in ("A" * 161, "line\nbreak", "中文"):
        assert client.post("/api/subtitle", json={"mode": "serial", "text": invalid}).status_code == 400
    assert {"3", "4", "5"}.issubset({k["key"] for k in client.get("/api/keys").json["keys"]})
    status = client.get("/api/status").json
    assert status["eth_board"] == "192.168.137.3"
    assert status["eth_local_port"] == 2
    original_open = eth_link.open
    opened = []
    eth_link.open = lambda: opened.append(True) or ""
    try:
        response = client.post("/api/eth/connect", json={"board": "127.0.0.1"})
        assert response.status_code == 200
        assert response.json["target"] == "192.168.137.3:1"
        assert opened == [True]
    finally:
        eth_link.open = original_open

    class FakeSocket:
        def __init__(self):
            self.packets = []
            self.on_send = None

        def sendto(self, payload, target):
            self.packets.append((payload, target))
            if self.on_send:
                self.on_send(payload, target)

    eth = EthTransport()
    eth.sock = FakeSocket()
    encoded = subtitle_bytes("N0P!")
    eth.sock.on_send = lambda payload, target: (
        eth._capture_subtitle_ack(bytes([0x5A, 0x54, 8, 1, 0, 0, 0x44, 0x80]))
        if len(eth.sock.packets) == len(encoded) else None)
    assert eth.send_subtitle("N0P!") == ""
    packets = eth.sock.packets
    assert len(packets) == len(encoded)
    for (packet, target), byte in zip(packets, encoded):
        assert packet == bytes([0xAA, 0xBB, 0xCC, 0xDD, 0, 1, 0, 2, byte, byte ^ 0xFF])
        assert target == (eth.board, eth.BOARD_PORT)
    assert eth.board == "192.168.137.3"

    rejected = EthTransport()
    rejected.sock = FakeSocket()
    rejected.sock.on_send = lambda payload, target: rejected._capture_subtitle_ack(
        bytes([0x5A, 0x54, 8, 1, 0, 0xA5, 0x44, 0x00])) if len(rejected.sock.packets) == len(encoded) else None
    assert "FPGA" in rejected.send_subtitle("N0P!")
    assert rejected.subtitle_result_code == 2
    assert rejected.subtitle_result_tag == 5

    timeout = EthTransport()
    timeout.SUBTITLE_ACK_TIMEOUT = 0
    timeout.sock = FakeSocket()
    assert "没有收到显示板确认" in timeout.send_subtitle("N0P!")
    print("PASS subtitle PC transport: validation, loopback, Ethernet packet framing")


if __name__ == "__main__":
    main()
