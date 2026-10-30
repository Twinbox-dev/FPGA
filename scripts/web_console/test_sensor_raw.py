"""Host protocol checks for raw sensor snapshot packet assembly and API shape."""
from __future__ import annotations

from app import EthTransport, app, eth_link


def main():
    link = EthTransport()
    payload = bytes(range(42))
    with link.sensor_condition:
        link.sensor_waiting = True
        link.sensor_active_sequence = None
        link.sensor_chunks = {}

    # Deliberately deliver chunks out of order; the sequence and chunk indices
    # make the snapshot reassembly independent of UDP arrival order.
    for index in (3, 0, 2, 1, 6, 4, 5):
        link._capture_sensor_chunk(bytes((0x2A, index)) + payload[index * 6:(index + 1) * 6])
    raw, sequence = link.sensor_result
    assert sequence == 0x2A and raw == payload

    original = eth_link.read_sensor_snapshot
    try:
        expected = {"sequence": 42, "bmp_address": "0x00", "bmp_id": "0x01",
                    "flags": {"initialized": False, "bmp_present": False,
                              "bmp_sample_valid": False, "aht_initialized": False,
                              "aht_sample_valid": False, "busy_timeout": False,
                              "i2c_timeout": True, "init_error": False},
                    "bmp_calibration_raw": payload[3:27].hex(" "),
                    "bmp_sample_raw": payload[27:33].hex(" "),
                    "aht_sample_raw": payload[33:39].hex(" ")}
        eth_link.read_sensor_snapshot = lambda timeout=4.0: (expected, None)
        response = app.test_client().post("/api/sensor/raw")
        assert response.status_code == 200
        assert response.get_json() == {"ok": True, "raw": expected}
    finally:
        eth_link.read_sensor_snapshot = original

    print("PASS sensor raw API: seven out-of-order chunks assemble and endpoint returns raw-only fields")


if __name__ == "__main__":
    main()
