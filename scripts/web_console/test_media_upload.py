"""Run with: python test_media_upload.py from scripts/web_console."""
import io
import struct
import wave
from unittest.mock import patch

import app as console
from media_upload import (MAX_AUDIO_SAMPLES, PC_AUDIO_MAX_SAMPLES, control_packet, image_packet,
                          load_pcm_wav, rgb24_to_native_words, unpack_display_packet)


def make_wav(samples=b"\x10\x80\xf0"):
    out = io.BytesIO()
    with wave.open(out, "wb") as dst:
        dst.setnchannels(1)
        dst.setsampwidth(1)
        dst.setframerate(24000)
        dst.writeframes(samples)
    return out.getvalue()


def main():
    # Asymmetric colors prove top-down browser pixels become bottom-up wire rows.
    rgb = bytes([255, 0, 0, 0, 255, 0, 0, 0, 255, 255, 255, 255])
    words, checksum = rgb24_to_native_words(rgb, 2, 2)
    expected = struct.pack("<II", 0xFFFF001F, 0x07E0F800)
    assert words == expected and checksum == (0xFFFF001F + 0x07E0F800) & 0xFFFFFFFF

    odd_words, odd_sum = rgb24_to_native_words(bytes([0, 0, 255]), 1, 1)
    assert odd_words == struct.pack("<I", 0x001F) and odd_sum == 0x001F
    assert unpack_display_packet(control_packet(0x0048, b"\x7f")) == (0x48, b"\x7f")

    class FakeSocket:
        def __init__(self, transport, layout=2):
            self.transport = transport
            self.layout = layout
            self.sent_kinds = []
            self.sent_payloads = []
            self.pending = []
            self.timeout = None

        def sendto(self, data, address):
            assert address == (self.transport.DISPLAY_IP, self.transport.DISPLAY_PORT)
            kind, length = struct.unpack_from(">HH" if data[4] == 0 else "<HH", data, 4)
            payload = data[8:]
            assert len(payload) == length
            self.sent_kinds.append(kind)
            self.sent_payloads.append((kind, payload))
            if kind == 0x20:
                self.reply(image_packet(0x20, b"\x01"))
            elif kind == 0x48:
                seq = payload[0]
                body = bytes((0x01, 7, 0, self.layout, 0,
                              0 if self.layout == 0 else 2,
                              1 if self.layout == 0 else 15, 4, 5, 6, 7,
                              0x80, 0x02, 0x68, 0x01, 0))
                self.reply(control_packet(0x0048, body))
            elif kind == 0x49:
                seq = payload[0]
                window = 0 if self.layout == 0 else 2
                mask = 1 if self.layout == 0 else 15
                self.reply(control_packet(0x004A, bytes((seq, 0, window, self.layout, 8, 0, 5, mask))))
            elif kind == 0x23:
                frame = payload[:2]
                self.reply(image_packet(0x24, frame + (b"\x00" if self.layout == 0 else b"\x02")))
            elif kind == 0x32:
                frame = payload[:2]
                self.reply(image_packet(0x33, frame + b"\x00"))
                self.reply(image_packet(0x24, frame + b"\x02"))

        def reply(self, packet):
            self.pending.append(packet)

        def settimeout(self, timeout):
            self.timeout = timeout

        def recvfrom(self, size):
            if not self.pending:
                raise TimeoutError("fake reply queue empty")
            return self.pending.pop(0), (self.transport.DISPLAY_IP, self.transport.DISPLAY_PORT)

        def close(self):
            pass

    old_link = console.eth_link

    class FakeEth:
        def is_open(self):
            return True

        def upload_image(self, pixels, width, height, pcm):
            self.call = (pixels, width, height, pcm)
            return {"frame_id": 0x7001, "width": width, "height": height,
                    "words": (width * height + 1) // 2,
                    "audio_samples": len(pcm), "result": 2,
                    "layout": 2, "window": 2, "sd_index": 5}

    fake = FakeEth()
    console.eth_link = fake
    try:
        client = console.app.test_client()
        response = client.post("/api/eth/upload-image", data={
            "width": "2", "height": "2", "include_audio": "0",
            "pixels": (io.BytesIO(rgb), "image.rgb"),
        }, content_type="multipart/form-data")
        assert response.status_code == 200 and response.json["words"] == 2
        assert fake.call == (rgb, 2, 2, b"")

        response = client.post("/api/eth/upload-image", data={
            "width": "1", "height": "1", "include_audio": "1",
            "pixels": (io.BytesIO(bytes([1, 2, 3])), "image.rgb"),
            "audio": (io.BytesIO(make_wav()), "tone.wav"),
        }, content_type="multipart/form-data")
        assert response.status_code == 200 and fake.call[3] == b"\x10\x80\xf0"

        with patch.object(console, "transcode_audio_stream", return_value=b"\x80") as transcode:
            response = client.post("/api/eth/upload-image", data={
                "width": "1", "height": "1", "include_audio": "1",
                "pixels": (io.BytesIO(bytes([1, 2, 3])), "image.rgb"),
                "audio": (io.BytesIO(b"mp4 container"), "clip.mp4"),
            }, content_type="multipart/form-data")
        assert response.status_code == 200 and fake.call[3] == b"\x80"
        assert transcode.call_count == 1 and transcode.call_args.args[1] == "clip.mp4"

        response = client.post("/api/eth/upload-image", data={
            "width": "1", "height": "1", "include_audio": "0",
            "pixels": (io.BytesIO(b"short"), "image.rgb"),
        }, content_type="multipart/form-data")
        assert response.status_code == 400

        transport = console.EthTransport()
        transport.sock = object()
        fake_socket = FakeSocket(transport)
        transport.upload_sock = fake_socket
        result = transport.upload_image(rgb, 2, 2, b"")
        assert result["result"] == 2 and result["audio_samples"] == 0
        assert (result["layout"], result["window"], result["sd_index"]) == (2, 2, 5)
        assert fake_socket.sent_kinds == [0x20, 0x48, 0x49, 0x21, 0x22, 0x23, 0x48]
        prepare = next(payload for kind, payload in fake_socket.sent_payloads if kind == 0x49)
        assert prepare == struct.pack("<BBBBHH", prepare[0], 0, 2, 0xFE, 7, 0)
        begin = next(payload for kind, payload in fake_socket.sent_payloads if kind == 0x21)
        _, image_index, _, _, _, _, layout, window, generation = struct.unpack("<HBBIHHBBH", begin)
        assert (image_index, layout, window, generation) == (5, 2, 2, 8)

        single_transport = console.EthTransport()
        single_transport.sock = object()
        single_socket = FakeSocket(single_transport, layout=0)
        single_transport.upload_sock = single_socket
        single_result = single_transport.upload_image(rgb[:3], 1, 1, b"\x80\x81")
        assert single_result["result"] == 2 and single_result["audio_samples"] == 2
        assert single_result["layout"] == 0 and single_result["window"] == 0
        assert single_socket.sent_kinds == [0x20, 0x48, 0x49, 0x21, 0x22, 0x23, 0x30, 0x31, 0x32, 0x48]

        multi_audio_transport = console.EthTransport()
        multi_audio_transport.sock = object()
        multi_audio_socket = FakeSocket(multi_audio_transport, layout=2)
        multi_audio_transport.upload_sock = multi_audio_socket
        try:
            multi_audio_transport.upload_image(rgb[:3], 1, 1, b"\x80")
            raise AssertionError("multi-view PC upload must reject audio")
        except RuntimeError as exc:
            assert "single-image" in str(exc)
        assert multi_audio_socket.sent_kinds == [0x20, 0x48, 0x48]
        long_wav = make_wav(bytes(MAX_AUDIO_SAMPLES + 100))
        assert len(load_pcm_wav(long_wav, max_samples=PC_AUDIO_MAX_SAMPLES)) == PC_AUDIO_MAX_SAMPLES
        try:
            load_pcm_wav(long_wav)
            raise AssertionError("unbounded WAV validation must keep the FPGA protocol cap")
        except ValueError:
            pass
        print("PASS RGB565 packing, multi-window target/index preservation, odd-pixel padding and 60s PCM cap")
    finally:
        console.eth_link = old_link


if __name__ == "__main__":
    main()
