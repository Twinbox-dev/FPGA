"""Run with: python scripts/web_console/test_stream.py."""
import time

import app as webapp


def stream_packet(seq: int, words: bytes) -> bytes:
    return b"\xAA\xBB\xCC\xDD\x04\x00\x00\x00" + seq.to_bytes(2, "little") + words


def main() -> None:
    link = webapp.EthTransport([])
    payloads = [bytes([i]) * (n * 4) for i, n in enumerate((253, 253, 29), 1)]
    for seq, payload in enumerate(payloads):
        link._on_stream(stream_packet(seq, payload))
    link.str["rb"]["last"] = time.time() - 1
    link._stream_poll()

    expected = b"".join(payloads)
    assert webapp.ETH_FRAME_RB["data"] == expected
    assert webapp.ETH_FRAME_RB["words"] == 535
    assert webapp.ETH_FRAME_RB["gaps"] == 0
    with webapp.app.test_client() as client:
        resp = client.get("/api/frame?slot=rb")
        assert resp.data == expected
        assert resp.headers["X-Frame-Stride"] == "3"
        assert resp.headers["X-Frame-Words"] == "535"
    print("Readback UDP reassembly and frame API: PASS")


if __name__ == "__main__":
    main()
