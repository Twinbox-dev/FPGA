#!/usr/bin/env python3
"""Emulate the display board for a standalone media-board acceptance test."""
from __future__ import annotations

import argparse
import io
import socket
import struct
import time
import wave
from pathlib import Path

from pc_display_media_probe import bmp_native_words, load_pcm

MAGIC = b"\xaa\xbb\xcc\xdd"


def packet(kind: int, payload: bytes = b"") -> bytes:
    return MAGIC + struct.pack("<HH", kind, len(payload)) + payload


def pcm_from_wav_bytes(data: bytes) -> bytes:
    with wave.open(io.BytesIO(data), "rb") as src:
        params = src.getparams()
        if (params.nchannels, params.sampwidth, params.framerate, params.comptype) != (1, 1, 24000, "NONE"):
            raise ValueError(f"unsupported WAV format in SD image: {params}")
        return src.readframes(params.nframes)


def read_fat32_wavs(image_path: Path) -> dict[str, bytes]:
    """Read WAV files in the FAT32 root of a raw MBR disk image."""
    with image_path.open("rb") as image:
        mbr = image.read(512)
        partition = mbr[446:462]
        lba_start = struct.unpack_from("<I", partition, 8)[0]
        image.seek(lba_start * 512)
        boot = image.read(512)
        bps = struct.unpack_from("<H", boot, 11)[0]
        spc = boot[13]
        reserved = struct.unpack_from("<H", boot, 14)[0]
        fat_count = boot[16]
        fat_size = struct.unpack_from("<I", boot, 36)[0]
        root_cluster = struct.unpack_from("<I", boot, 44)[0]
        fat_offset = (lba_start + reserved) * bps
        data_offset = (lba_start + reserved + fat_count * fat_size) * bps
        cluster_bytes = spc * bps

        def fat_entry(cluster: int) -> int:
            image.seek(fat_offset + cluster * 4)
            return struct.unpack("<I", image.read(4))[0] & 0x0FFFFFFF

        def cluster_offset(cluster: int) -> int:
            return data_offset + (cluster - 2) * cluster_bytes

        def chain(start: int):
            cluster = start
            seen = 0
            while 2 <= cluster < 0x0FFFFFF8:
                yield cluster
                cluster = fat_entry(cluster)
                seen += 1
                if seen > 100000:
                    raise ValueError("FAT32 cluster chain loop")

        wavs: dict[str, bytes] = {}
        for dir_cluster in chain(root_cluster):
            image.seek(cluster_offset(dir_cluster))
            raw = image.read(cluster_bytes)
            for offset in range(0, len(raw), 32):
                entry = raw[offset:offset + 32]
                if not entry or entry[0] == 0:
                    break
                if entry[0] == 0xE5 or entry[11] == 0x0F or entry[11] & 0x10:
                    continue
                ext = entry[8:11].decode("ascii", "ignore").strip()
                if ext.upper() != "WAV":
                    continue
                base = entry[:8].decode("ascii", "ignore").strip()
                size = struct.unpack_from("<I", entry, 28)[0]
                start_cluster = ((struct.unpack_from("<H", entry, 20)[0] << 16) |
                                 struct.unpack_from("<H", entry, 26)[0])
                data = bytearray()
                for cluster in chain(start_cluster):
                    image.seek(cluster_offset(cluster))
                    data.extend(image.read(cluster_bytes))
                    if len(data) >= size:
                        break
                wavs[f"{base}.{ext.upper()}"] = bytes(data[:size])
        return wavs


class DisplayStub:
    def __init__(self, sock: socket.socket, board_ip: str, golden_dir: Path,
                 wav_dir: Path, frames: int, card_image: Path | None,
                 request_snapshot: bool):
        self.sock = sock
        self.board_ip = board_ip
        self.frames_goal = frames
        self.request_snapshot = request_snapshot
        self.frames_done = 0
        self.peer: tuple[str, int] | None = None
        self.golden = {path.name: bmp_native_words(path) for path in sorted(golden_dir.glob("*.BMP"))}
        self.pcm = {path.name: load_pcm(path) for path in sorted(wav_dir.glob("*.WAV"))
                    if path.name.upper().startswith("IMG")}
        if card_image is not None:
            self.pcm.update({name: pcm_from_wav_bytes(raw)
                             for name, raw in read_fat32_wavs(card_image).items()})
        self.frame_id: int | None = None
        self.image_index = 0
        self.flags = 0
        self.image_words: list[int] = []
        self.image_next_seq = 0
        self.image_bad = False
        self.image_width = self.image_height = self.image_count = 0
        self.audio_id: int | None = None
        self.audio_count = 0
        self.audio_data = bytearray()
        self.audio_next_seq = 0
        self.audio_bad = False
        self.expected_pcm = b""
        self.expected_image: str | None = None
        self.expected_wav: str | None = None

    def send(self, kind: int, payload: bytes = b"") -> None:
        if self.peer is None:
            return
        self.sock.sendto(packet(kind, payload), self.peer)

    def match_image(self) -> tuple[str | None, list[int] | None]:
        for name, (expected, width, height) in self.golden.items():
            if (width, height) == (self.image_width, self.image_height) and expected == self.image_words:
                return name, expected
        return None, None

    def match_pcm(self) -> str | None:
        for name, expected in self.pcm.items():
            if expected == bytes(self.audio_data):
                return name
        return None

    def closest_pcm(self) -> tuple[str | None, int | None, int | None]:
        best_name, best_mismatches, best_first = None, None, None
        actual = bytes(self.audio_data)
        for name, expected in self.pcm.items():
            if len(expected) != len(actual):
                continue
            mismatch_positions = [i for i, (a, b) in enumerate(zip(actual, expected)) if a != b]
            if best_mismatches is None or len(mismatch_positions) < best_mismatches:
                best_name = name
                best_mismatches = len(mismatch_positions)
                best_first = mismatch_positions[0] if mismatch_positions else None
        return best_name, best_mismatches, best_first

    def receive(self, data: bytes, peer: tuple[str, int]) -> None:
        if peer[0] != self.board_ip or len(data) < 8 or data[:4] != MAGIC:
            return
        if data[4:6] == b"\x00\x02":
            declared = int.from_bytes(data[6:8], "big")
            if declared == len(data) - 8 and declared == 8:
                print(f"V1 control ACK payload={data[8:].hex()}", flush=True)
            return
        kind = int.from_bytes(data[4:6], "little")
        length = int.from_bytes(data[6:8], "little")
        payload = data[8:]
        if len(payload) != length:
            print(f"DROP malformed type=0x{kind:04x} len={length}/{len(payload)}", flush=True)
            return
        self.peer = peer

        if kind == 0x20 and length == 0:
            self.send(0x20, b"\x01")
            print("READY query -> READY=1", flush=True)
        elif kind == 0x21 and length == 16:
            self.frame_id = int.from_bytes(payload[:2], "little")
            self.image_index = payload[2]
            self.flags = payload[3]
            total_words = int.from_bytes(payload[4:8], "little")
            self.image_width, self.image_height = struct.unpack_from("<HH", payload, 8)
            self.image_count = total_words
            self.image_words = []
            self.image_next_seq = 0
            self.image_bad = not (0 < self.image_width <= 1280 and 0 < self.image_height <= 720 and
                                  total_words == (self.image_width * self.image_height + 1) // 2 and
                                  payload[12:] == bytes(4))
            self.expected_image = None
            print(f"IMAGE BEGIN frame={self.frame_id:04x} index={self.image_index} "
                  f"flags=0x{self.flags:02x} words={total_words}", flush=True)
        elif kind == 0x22 and length >= 8:
            frame_id = int.from_bytes(payload[:2], "little")
            seq = int.from_bytes(payload[2:4], "little")
            if frame_id != self.frame_id or seq != self.image_next_seq or (length - 4) % 4:
                self.image_bad = True
            self.image_next_seq = seq + 1
            count = (length - 4) // 4
            self.image_words.extend(struct.unpack(f"<{count}I", payload[4:]))
        elif kind == 0x23 and length == 8:
            frame_id = int.from_bytes(payload[:2], "little")
            sent_sum = int.from_bytes(payload[2:6], "little")
            got_sum = sum(self.image_words) & 0xFFFFFFFF
            self.expected_image, _ = self.match_image()
            ok = (frame_id == self.frame_id and not self.image_bad and
                  len(self.image_words) == self.image_count and sent_sum == got_sum and
                  self.expected_image is not None)
            self.send(0x24, struct.pack("<HB", frame_id, 0 if ok else 1))
            print(f"IMAGE END words={len(self.image_words)} sum={'ok' if sent_sum==got_sum else 'bad'} "
                  f"golden={self.expected_image or 'no exact match'} result={0 if ok else 1}", flush=True)
            if not ok:
                self.image_bad = True
        elif kind == 0x30 and length == 8:
            self.audio_id = int.from_bytes(payload[:2], "little")
            self.audio_count = int.from_bytes(payload[2:6], "little")
            self.audio_data = bytearray()
            self.audio_next_seq = 0
            self.audio_bad = self.audio_id != self.frame_id
            self.expected_wav = None
            print(f"AUDIO BEGIN frame={self.audio_id:04x} samples={self.audio_count}", flush=True)
        elif kind == 0x31 and length >= 4:
            frame_id = int.from_bytes(payload[:2], "little")
            seq = int.from_bytes(payload[2:4], "little")
            if frame_id != self.audio_id or seq != self.audio_next_seq:
                self.audio_bad = True
            self.audio_next_seq = seq + 1
            self.audio_data.extend(payload[4:])
        elif kind == 0x32 and length == 8:
            frame_id = int.from_bytes(payload[:2], "little")
            sent_sum = int.from_bytes(payload[2:6], "little")
            got_sum = sum(self.audio_data) & 0xFFFFFFFF
            self.expected_wav = self.match_pcm()
            debug_path = Path("boardtest/captures") / f"media_audio_frame{frame_id:04x}.pcm"
            debug_path.parent.mkdir(parents=True, exist_ok=True)
            debug_path.write_bytes(self.audio_data)
            closest_name, closest_mismatches, closest_first = self.closest_pcm()
            count_ok = len(self.audio_data) == self.audio_count
            pcm_ok = self.audio_count == 0 or self.expected_wav is not None
            ok = (frame_id == self.audio_id and not self.audio_bad and count_ok and
                  sent_sum == got_sum and pcm_ok)
            self.send(0x33, struct.pack("<HB", frame_id, 0 if ok else 1))
            print(f"AUDIO END samples={len(self.audio_data)} sum={'ok' if sent_sum==got_sum else 'bad'} "
                  f"golden={self.expected_wav or ('silence' if not self.audio_data else 'no exact match')} "
                  f"closest={closest_name} mismatches={closest_mismatches} first={closest_first} "
                  f"result={0 if ok else 1}", flush=True)
            if ok and not self.image_bad:
                self.send(0x24, struct.pack("<HB", frame_id, 2))
                self.frames_done += 1
                print("COMMIT -> RESULT=2", flush=True)
                if self.request_snapshot and self.frames_done == 1:
                    request = MAGIC + struct.pack(">HH", 1, 2) + b"D\xbb"
                    self.sock.sendto(request, (self.board_ip, 1))
                    print("PC requested a formal snapshot with V1 D", flush=True)
        elif kind == 0x02:
            # V1 media-board ACK to the PC's D command.
            print(f"PC command ACK payload={payload.hex()}", flush=True)
        elif kind == 0x40 and length == 4:
            seq, op, value, _ = payload
            self.send(0x41, bytes((seq, op, 0, value)))
        elif kind == 0x42 and length == 1:
            seq = payload[0]
            self.send(0x43, bytes((seq, 8, 4, 2, 0, 1, 0, 1)))
        elif kind in (0x44, 0x45, 0x46):
            # The acceptance flow does not upload a subtitle. Keep the endpoint
            # well-formed if a smoke test sends one, and ACK its final packet.
            if kind == 0x46 and length == 3:
                seq, title_len, _ = payload
                self.send(0x41, bytes((seq, 8, 0, title_len)))
        elif kind not in (0x22, 0x31):
            print(f"IGNORE type=0x{kind:04x} len={length}", flush=True)


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--board-ip", default="192.168.137.3")
    ap.add_argument("--pc-ip", default="192.168.137.1")
    ap.add_argument("--port", type=int, default=2)
    ap.add_argument("--golden-dir", type=Path, default=Path("img/golden"))
    ap.add_argument("--wav-dir", type=Path, default=Path("img/wav"))
    ap.add_argument("--card-image", type=Path,
                    help="also compare PCM against WAV files in a raw MBR/FAT32 SD image")
    ap.add_argument("--frames", type=int, default=1)
    ap.add_argument("--timeout-seconds", type=float, default=60.0)
    ap.add_argument("--request-snapshot", action="store_true",
                    help="after the first commit, send V1 D and verify a formal PC snapshot")
    args = ap.parse_args()
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    if hasattr(socket, "SO_EXCLUSIVEADDRUSE"):
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_EXCLUSIVEADDRUSE, 1)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 16 * 1024 * 1024)
    sock.bind((args.pc_ip, args.port))
    stub = DisplayStub(sock, args.board_ip, args.golden_dir, args.wav_dir,
                       args.frames, args.card_image, args.request_snapshot)
    print(f"PC display stub listening on {args.pc_ip}:{args.port}; waiting for media READY", flush=True)
    deadline = time.monotonic() + args.timeout_seconds
    try:
        while stub.frames_done < args.frames and time.monotonic() < deadline:
            sock.settimeout(min(1.0, max(0.01, deadline - time.monotonic())))
            try:
                data, peer = sock.recvfrom(2048)
            except socket.timeout:
                continue
            stub.receive(data, peer)
        if stub.frames_done < args.frames:
            raise SystemExit(f"timeout: completed {stub.frames_done}/{args.frames} frames")
        print(f"PASS: PC display stub committed {stub.frames_done} media frame(s)", flush=True)
    finally:
        sock.close()


if __name__ == "__main__":
    main()
