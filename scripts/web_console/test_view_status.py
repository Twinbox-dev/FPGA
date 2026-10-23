"""Authoritative view decoding, sequence ordering and API admission checks."""
import struct
import app as console


def body(sequence, generation=1, layout=2, busy=0, focus=3, mask=15, result=0):
    return struct.pack("<BHBBBB4BHHB", sequence, generation, layout, busy, focus, mask,
                       1, 3, 5, 6, 571, 720, result)


def main():
    old_state, old_resync = console.VIEW_STATE, console.VIEW_RESYNC
    original_send = console.eth_link.send_key
    events, sent = [], []
    console.eth_link.send_key = lambda key: sent.append(key) or ""
    console.VIEW_STATE = None
    console.VIEW_RESYNC = False
    try:
        assert console.publish_view(body(254), events.append)
        assert console.publish_view(body(1), events.append)  # wrap
        assert not console.publish_view(body(0), events.append)  # stale
        assert not console.publish_view(body(1), events.append)  # duplicate
        assert events[-1]["indices"] == [1, 3, 5, 6]
        assert (events[-1]["width"], events[-1]["height"]) == (571, 720)
        assert not console.publish_view(body(2, layout=3), events.append)
        client = console.app.test_client()
        assert client.get("/api/status").json["view"]["focus"] == 3
        assert client.post("/api/cmd", json={"mode": "eth", "key": "7"}).status_code == 409
        assert client.post("/api/cmd", json={"mode": "eth", "key": "6"}).json["ok"]
        assert console.publish_view(body(2, busy=1), events.append)
        for key in ("n", "p", "d", "6", "7", "8"):
            assert client.post("/api/cmd", json={"mode": "eth", "key": key}).status_code == 409
        assert client.post("/api/cmd", json={"mode": "eth", "key": "s"}).json["ok"]
        assert console.publish_view(body(0, generation=0, layout=0, focus=0, mask=1), events.append)
        assert console.publish_view(body(1, generation=0, layout=0, focus=0, mask=1), events.append)
        keys = client.get("/api/keys").json
        assert {"6", "7", "8"}.issubset({item["key"] for item in keys["keys"]})
        assert sent == ["6", "s"]
        print("PASS: 16-byte VIEW_STATUS, stale/wrapped sequence, S resync and busy/layout API admission")
    finally:
        console.VIEW_STATE, console.VIEW_RESYNC = old_state, old_resync
        console.eth_link.send_key = original_send


if __name__ == "__main__":
    main()
