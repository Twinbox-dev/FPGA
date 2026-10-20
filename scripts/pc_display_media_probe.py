#!/usr/bin/env python3
"""Act as a PC media board for the display FPGA's standalone acceptance test.

Sends the agreed 0x20..0x33 image/PCM packets to a display board, checks its
transaction replies, then requests the existing 1/3-rate SDRAM readback probe
and compares every captured word with the transmitted frame.
"""
from __future__ import annotations

import argparse
import socket
import struct
import time
import wave
from pathlib import Path

MAGIC = b"\xaa\xbb\xcc\xdd"
FRAME_WORDS = 1280 * 720 // 2
IMAGE_PACKET_WORDS = 253
AUDIO_PACKET_SAMPLES = 1012


def packet(kind: int, payload: bytes = b"") -> bytes:
    return MAGIC + struct.pack("<HH", kind, len(payload)) + payload


def bmp_words(path: Path) -> list[int]:
    data = path.read_bytes()
    if data[:2] != b"BM" or len(data) < 54:
        raise ValueError(f"not a BMP file: {path}")
    pixel_offset = struct.unpack_from("<I", data, 10)[0]
    width, signed_height = struct.unpack_from("<ii", data, 18)
    planes, bpp = struct.unpack_from("<HH", data, 26)
    compression = struct.unpack_from("<I", data, 30)[0]
    height = abs(signed_height)
    if not (0 < width <= 1280 and 0 < height <= 720 and
            planes == 1 and bpp == 24 and compression == 0):
        raise ValueError(f"unsupported BMP geometry/format: {width}x{signed_height}, {bpp}bpp")
    stride = (width * 3 + 3) & ~3
    left = (1280 - width) >> 1
    bottom = (720 - height) - ((720 - height) >> 1)
    frame = [0] * FRAME_WORDS
    for y in range(height):
        file_row = y if signed_height > 0 else height - 1 - y
        start = pixel_offset + file_row * stride
        output_y = bottom + y
        for x in range(width):
            off = start + 3 * x
            blue, green, red = data[off:off + 3]
            pixel = ((red >> 3) << 11) | ((green >> 2) << 5) | (blue >> 3)
            output_x = left + x
            pixel_index = output_y * 1280 + output_x
            word_index = pixel_index >> 1
            if pixel_index & 1:
                frame[word_index] |= pixel << 16
            else:
                frame[word_index] |= pixel
    return frame


def load_pcm(path: Path | None) -> bytes:
    if path is None:
        return b""
    with wave.open(str(path), "rb") as src:
        params = src.getparams()
        if (params.nchannels, params.sampwidth, params.framerate, params.comptype) != (1, 1, 24000, "NONE"):
            raise ValueError("WAV must be uncompressed 24 kHz / 8-bit / mono PCM")
        return src.readframes(params.nframes)


class Probe:
    def __init__(self, board_ip: str, pc_ip: str, pace_s: float, ctrl_port: int):
        self.board_ip = board_ip
        self.pace_s = pace_s
        self.pending_formal: list[bytes] = []
        self.formal_order: list[tuple[int, int]] = []
        self.ctrl = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        self.dump = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        for sock in (self.ctrl, self.dump):
            if hasattr(socket, "SO_EXCLUSIVEADDRUSE"):
                sock.setsockopt(socket.SOL_SOCKET, socket.SO_EXCLUSIVEADDRUSE, 1)
            sock.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 16 * 1024 * 1024)
        self.ctrl.bind((pc_ip, ctrl_port))
        self.dump.bind((pc_ip, 3))

    def send(self, kind: int, payload: bytes = b"") -> None:
        self.ctrl.sendto(packet(kind, payload), (self.board_ip, 1))

    def receive(self, sock: socket.socket, timeout_s: float) -> bytes:
        sock.settimeout(timeout_s)
        data, _ = sock.recvfrom(2048)
        return data

    def wait_formal(self, kind: int, frame_id: int | None, timeout_s: float = 10.0) -> int:
        def parse(data: bytes):
            if len(data) < 8 or data[:4] != MAGIC or data[4] != kind or data[5] != 0:
                return None
            length = int.from_bytes(data[6:8], "little")
            payload = data[8:]
            if len(payload) != length:
                return None
            if kind == 0x20 and payload == b"\x01":
                return 1
            if kind in (0x24, 0x33) and len(payload) == 3:
                rx_frame = int.from_bytes(payload[:2], "little")
                if frame_id is None or rx_frame == frame_id:
                    return payload[2]
            return None

        for index, data in enumerate(self.pending_formal):
            result = parse(data)
            if result is not None:
                del self.pending_formal[index]
                return result
        deadline = time.monotonic() + timeout_s
        while time.monotonic() < deadline:
            try:
                data = self.receive(self.ctrl, min(0.5, deadline - time.monotonic()))
            except socket.timeout:
                continue
            if len(data) >= 8 and data[:4] == MAGIC and data[5] == 0 and data[4] in (0x20,0x24,0x33):
                length = int.from_bytes(data[6:8], "little")
                payload = data[8:]
                if len(payload) == length:
                    if data[4] in (0x24,0x33) and len(payload)==3:
                        self.formal_order.append((data[4], payload[2]))
                        print(f"RX result type=0x{data[4]:02x} frame={int.from_bytes(payload[:2], 'little'):04x} code={payload[2]}", flush=True)
                    result = parse(data)
                    if result is not None:
                        return result
                    self.pending_formal.append(data)
        raise TimeoutError(f"no response type 0x{kind:04x} within {timeout_s}s; seen={self.formal_order}; queued={len(self.pending_formal)}")

    def send_image(self, words: list[int], frame_id: int, image_index: int,
                   has_wav: bool, attempts: int = 3) -> None:
        checksum = sum(words) & 0xFFFFFFFF
        flags = (0x08 if has_wav else 0x00)  # bit 3 = matching WAV; bit 0 = previous
        for attempt in range(1, attempts + 1):
            self.send(0x21, struct.pack("<HBBI", frame_id, image_index, flags, len(words)))
            for sequence, first in enumerate(range(0, len(words), IMAGE_PACKET_WORDS)):
                chunk = words[first:first + IMAGE_PACKET_WORDS]
                payload = struct.pack("<HH", frame_id, sequence) + struct.pack(f"<{len(chunk)}I", *chunk)
                self.send(0x22, payload)
                if self.pace_s:
                    time.sleep(self.pace_s)
            self.send(0x23, struct.pack("<HIH", frame_id, checksum, 0))
            result = self.wait_formal(0x24, frame_id)
            print(f"image attempt {attempt}: RESULT={result}", flush=True)
            if result == 0:
                return
            if result != 1:
                raise RuntimeError(f"unexpected image result {result}")
        raise RuntimeError("image END checksum/sequence rejected three times")

    def send_audio(self, pcm: bytes, frame_id: int, attempts: int = 3) -> None:
        checksum = sum(pcm) & 0xFFFFFFFF
        for attempt in range(1, attempts + 1):
            self.send(0x30, struct.pack("<HIH", frame_id, len(pcm), 0))
            for sequence, first in enumerate(range(0, len(pcm), AUDIO_PACKET_SAMPLES)):
                chunk = pcm[first:first + AUDIO_PACKET_SAMPLES]
                self.send(0x31, struct.pack("<HH", frame_id, sequence) + chunk)
                if self.pace_s:
                    time.sleep(self.pace_s)
            self.send(0x32, struct.pack("<HIH", frame_id, checksum, 0))
            result = self.wait_formal(0x33, frame_id)
            print(f"audio attempt {attempt}: samples={len(pcm)} RESULT={result}", flush=True)
            if result == 0:
                return
            if result != 1:
                raise RuntimeError(f"unexpected audio result {result}")
        raise RuntimeError("audio END checksum/sequence rejected three times")

    def set_control(self, sequence: int, op: int, value: int) -> None:
        self.send(0x40, bytes((sequence & 0xff, op, value, 0)))
        result = self.wait_control(0x41, sequence)
        if result != (op, 0, value):
            raise RuntimeError(f"SET op={op} value={value}: ACK={result}")

    def wait_control(self, kind: int, sequence: int, timeout_s: float = 5.0):
        deadline = time.monotonic() + timeout_s
        while time.monotonic() < deadline:
            try:
                data = self.receive(self.ctrl, min(0.5, deadline - time.monotonic()))
            except socket.timeout:
                continue
            if len(data) < 8 or data[:4] != MAGIC or data[4] != kind or data[5] != 0:
                continue
            length = int.from_bytes(data[6:8], "little")
            payload = data[8:]
            if len(payload) != length:
                continue
            if kind == 0x41 and length == 4 and payload[0] == (sequence & 0xff):
                return payload[1], payload[2], payload[3]
            if kind == 0x43 and length == 8 and payload[0] == (sequence & 0xff):
                return tuple(payload)
        raise TimeoutError(f"no control response 0x{kind:02x} for sequence {sequence}")

    def request_status(self, sequence: int = 0x7e):
        self.send(0x42, bytes((sequence,)))
        return self.wait_control(0x43, sequence)

    def upload_subtitle(self, text: str, sequence: int = 0x55) -> None:
        raw = text.encode("ascii")
        if len(raw) > 160 or any(x < 0x20 or x > 0x7e for x in raw):
            raise ValueError("subtitle must be printable ASCII, at most 160 characters")
        checksum = len(raw)
        for byte in raw:
            checksum ^= byte
        self.send(0x44, bytes((sequence, len(raw), checksum)))
        for offset, byte in enumerate(raw):
            self.send(0x45, bytes((sequence, offset, byte)))
            if self.pace_s:
                time.sleep(self.pace_s)
        self.send(0x46, bytes((sequence, len(raw), checksum)))
        ack = self.wait_control(0x41, sequence)
        if ack != (8, 0, len(raw)):
            raise RuntimeError(f"subtitle ACK={ack}")

    def readback(self, attempts: int, timeout_s: float = 0.45) -> bytes:
        for attempt in range(1, attempts + 1):
            # V1 command frame: type and length are big-endian; payload is [D,~D].
            self.ctrl.sendto(MAGIC + struct.pack(">HH", 1, 2) + b"D\xbb", (self.board_ip, 1))
            packet_data = bytearray()
            expected_sequence = 0
            gaps = 0
            saw_stream = False
            last_packet = time.monotonic()
            while time.monotonic() - last_packet < timeout_s:
                try:
                    data = self.receive(self.dump, timeout_s)
                except socket.timeout:
                    break
                if len(data) < 10 or data[:6] != MAGIC + b"\x04\x00":
                    continue
                declared = int.from_bytes(data[6:8], "little")
                payload = data[8:]
                if declared != len(payload) or len(payload) < 2 or (len(payload) - 2) % 4:
                    continue
                seq = int.from_bytes(payload[:2], "little")
                if seq == 0:
                    packet_data.clear()
                    expected_sequence = 0
                    gaps = 0
                    saw_stream = True
                elif not saw_stream:
                    continue
                if seq != expected_sequence:
                    gaps += (seq - expected_sequence) & 0xffff
                expected_sequence = (seq + 1) & 0xffff
                packet_data.extend(payload[2:])
                last_packet = time.monotonic()
            words = len(packet_data) // 4
            print(f"readback attempt {attempt}: {words} sampled words, sequence gaps={gaps}", flush=True)
            if words == FRAME_WORDS // 3 and gaps == 0:
                return bytes(packet_data[:words * 4])
            time.sleep(0.5)
        raise RuntimeError("readback probe did not return a complete 1/3-rate frame")


def compare_readback(sampled: bytes, words: list[int]) -> tuple[int, int]:
    got = [int.from_bytes(sampled[i:i + 4], "little") for i in range(0, len(sampled), 4)]
    best_phase, best_bad = 0, len(got)
    for phase in range(3):
        bad = sum(value != words[(phase + 3 * i) % len(words)] for i, value in enumerate(got))
        if bad < best_bad:
            best_phase, best_bad = phase, bad
    return best_phase, best_bad


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--board-ip", default="192.168.137.2")
    ap.add_argument("--pc-ip", default="192.168.137.1")
    ap.add_argument("--ctrl-port", type=int, default=2,
                    help="PC return port for media replies (WebTransport uses 2)")
    ap.add_argument("--bmp", type=Path, default=Path("img/golden/IMG1.BMP"))
    ap.add_argument("--wav", type=Path, default=Path("img/wav/IMG001.WAV"))
    ap.add_argument("--pace-ms", type=float, default=0.5,
                    help="inter-UDP-packet spacing; default leaves time for the FPGA BRAM packet buffer")
    ap.add_argument("--frame-id", type=lambda x: int(x, 0), default=0x2401)
    ap.add_argument("--dump-attempts", type=int, default=3)
    ap.add_argument("--capture-prefix", type=Path, default=Path("boardtest/captures/display_pc_probe"))
    ap.add_argument("--skip-controls", action="store_true")
    args = ap.parse_args()

    frame = bmp_words(args.bmp)
    pcm = load_pcm(args.wav if args.wav and args.wav.exists() else None)
    print(f"frame: {args.bmp} -> {len(frame)} words; paired PCM samples={len(pcm)}", flush=True)
    probe = Probe(args.board_ip, args.pc_ip, args.pace_ms / 1000.0, args.ctrl_port)
    try:
        ready = None
        for _ in range(10):
            probe.send(0x20)
            try:
                ready = probe.wait_formal(0x20, None, timeout_s=1.0)
                break
            except TimeoutError:
                time.sleep(0.25)
        if ready is None:
            raise TimeoutError("display did not answer ten READY queries")
        print(f"display READY={ready}", flush=True)
        probe.set_control(0xf0, 4, 0)
        print("transition mode set to direct for deterministic readback", flush=True)
        if not args.skip_controls:
            print(f"preflight status: {probe.request_status(0xf1)}", flush=True)
        probe.send_image(frame, args.frame_id, 0, bool(pcm))
        probe.send_audio(pcm, args.frame_id)
        final_result = None
        try:
            final_result = probe.wait_formal(0x24, args.frame_id)
        except TimeoutError:
            print("no final RESULT=2 received; continuing with SDRAM readback to check commit state", flush=True)
        if final_result == 2:
            print(f"formal result order: {[(hex(kind), code) for kind, code in probe.formal_order]}", flush=True)
            print("image/audio transaction committed", flush=True)

        if not args.skip_controls:
            for seq, (op, value) in enumerate(((1, 4), (2, 5), (3, 3),
                                                (5, 1), (6, 1), (7, 2)), 1):
                probe.set_control(seq, op, value)
            status = probe.request_status()
            print(f"display status bytes: {status}", flush=True)
            probe.upload_subtitle("FPGA DISPLAY LINK")
            print("control SET/status/subtitle passed", flush=True)

        sampled = probe.readback(args.dump_attempts)
        args.capture_prefix.parent.mkdir(parents=True, exist_ok=True)
        raw_path = args.capture_prefix.with_suffix(".rgb565le")
        raw_path.write_bytes(sampled)
        phase, bad = compare_readback(sampled, frame)
        words = len(sampled) // 4
        print(f"readback comparison: {bad}/{words} mismatches, best phase={phase}", flush=True)
        if bad:
            raise RuntimeError("display SDRAM/video readback differs from the sent frame")
        if final_result != 2:
            raise RuntimeError("readback pixels match, but final RESULT=2 was not returned")
        print(f"PASS: full frame, PCM transaction, and readback; raw={raw_path}", flush=True)
    finally:
        probe.ctrl.close()
        probe.dump.close()


if __name__ == "__main__":
    main()
