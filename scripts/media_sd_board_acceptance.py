#!/usr/bin/env python3
"""Exercise the physical media board through Ethernet and verify D snapshots.

This uses the product V1 N/D commands. N loads the next card image through the
real display board; its ACK reports whether paired audio committed. D rereads the
currently committed image to the PC. The PC checks complete 1280x720 RGB565
frames against the checked-in BMP golden set. The product D snapshot contains
image pixels only, so PCM byte-for-byte checks remain in the SD/FAT simulation;
board acceptance checks the paired/silent audio flag in the post-commit ACK.
"""
from __future__ import annotations

import json
import queue
import re
import struct
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts" / "web_console"))
sys.path.insert(0, str(ROOT / "scripts"))

from app import ETH_FRAME_LOCK, ETH_FRAME_SNAPSHOT, EthTransport
from pc_display_media_probe import bmp_words
from pc_media_display_stub import pcm_from_wav_bytes, read_fat32_wavs

FRAME_WORDS = 1280 * 720 // 2
ROW_BYTES = 640 * 4
MAGIC = b"\xaa\xbb\xcc\xdd"


class CapturingTransport(EthTransport):
    def __init__(self, subs):
        super().__init__(subs)
        self.snapshot_pcm = b""
        self.snapshot_pcm_count = 0
        self.snapshot_pcm_frame = None

    def _on_snapshot(self, data: bytes) -> None:
        if len(data) >= 8:
            kind = int.from_bytes(data[4:6], "little")
            if kind == 0x30 and self.snapshot is not None:
                self.snapshot_pcm = b""
                self.snapshot_pcm_count = int.from_bytes(data[10:14], "little")
                self.snapshot_pcm_frame = int.from_bytes(data[8:10], "little")
            elif kind == 0x32 and self.snapshot is not None:
                self.snapshot_pcm = bytes(self.snapshot["audio"])
        super()._on_snapshot(data)


def wait_event(events: queue.Queue, predicate, timeout: float, label: str):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        try:
            item = events.get(timeout=min(0.5, deadline - time.monotonic()))
        except queue.Empty:
            continue
        if predicate(item):
            return item
        if item.get("type") == "pkt" and item.get("kind") in ("ack", "diag", "status"):
            print(f"  RX {item['kind']}: {item['text']}", flush=True)
    raise TimeoutError(f"timed out waiting for {label}")


def query_status(link: CapturingTransport, events: queue.Queue, timeout: float):
    link.send_key("s")
    return wait_event(events, lambda item: item.get("type") == "pkt" and
                      item.get("kind") == "status", timeout, "media status")


def status_index(text: str) -> int:
    match = re.search(r"img=(\d+)", text)
    if not match:
        raise RuntimeError(f"status did not include committed image index: {text}")
    return int(match.group(1))


def build_golden_frames(golden_dir: Path):
    frames = {}
    for bmp in sorted(golden_dir.glob("*.BMP")):
        words = bmp_words(bmp)
        if len(words) != FRAME_WORDS:
            raise ValueError(f"unexpected golden frame length for {bmp}: {len(words)}")
        raw = struct.pack(f"<{FRAME_WORDS}I", *words)
        bottom_up = b"".join(raw[row * ROW_BYTES:(row + 1) * ROW_BYTES]
                              for row in range(719, -1, -1))
        frames[bmp.name.upper()] = (raw, bottom_up)
    if len(frames) != 6:
        raise ValueError(f"expected six BMP goldens, found {len(frames)} in {golden_dir}")
    return frames


def list_fat32_root(image_path: Path) -> list[str]:
    """List root short names from the card mirror for real-card comparison."""
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
        names: list[str] = []

        def fat_entry(cluster: int) -> int:
            image.seek(fat_offset + cluster * 4)
            return struct.unpack("<I", image.read(4))[0] & 0x0FFFFFFF

        cluster = root_cluster
        seen = 0
        while 2 <= cluster < 0x0FFFFFF8:
            image.seek(data_offset + (cluster - 2) * cluster_bytes)
            raw = image.read(cluster_bytes)
            for offset in range(0, len(raw), 32):
                entry = raw[offset:offset + 32]
                if not entry or entry[0] == 0:
                    return names
                if entry[0] == 0xE5 or entry[11] == 0x0F or entry[11] & 0x18:
                    continue
                base = entry[:8].decode("ascii", "ignore").strip()
                ext = entry[8:11].decode("ascii", "ignore").strip()
                names.append(f"{base}.{ext}" if ext else base)
            cluster = fat_entry(cluster)
            seen += 1
            if seen > 100000:
                raise ValueError("FAT32 root cluster chain loop")
        return names


def main() -> None:
    import argparse

    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--pc-ip", default="192.168.137.1")
    parser.add_argument("--golden-dir", type=Path, default=ROOT / "img" / "golden")
    parser.add_argument("--card-image", type=Path, default=ROOT / "img" / "card_user_real.img")
    parser.add_argument("--images", type=int, default=6)
    parser.add_argument("--timeout", type=float, default=45.0)
    parser.add_argument("--settle-seconds", type=float, default=3.0,
                        help="allow the asynchronous N load/display commit to finish before querying S")
    parser.add_argument("--captures", type=Path, default=ROOT / "boardtest" / "captures")
    parser.add_argument("--list-card", action="store_true",
                        help="print files in the card mirror and exit")
    args = parser.parse_args()
    if not 1 <= args.images <= 6 or args.timeout <= 0 or args.settle_seconds < 0:
        parser.error("images must be 1..6, timeout positive, and settle time nonnegative")

    golden = build_golden_frames(args.golden_dir)
    if args.list_card:
        print(json.dumps(list_fat32_root(args.card_image), ensure_ascii=False, indent=2))
        return
    card_wavs_raw = read_fat32_wavs(args.card_image)
    card_pcm = {name.upper(): pcm_from_wav_bytes(raw) for name, raw in card_wavs_raw.items()}
    print(f"goldens={len(golden)} card WAVs={[(name,len(pcm)) for name,pcm in card_pcm.items()]}", flush=True)

    args.captures.mkdir(parents=True, exist_ok=True)
    run_tag = time.strftime("%Y%m%d_%H%M%S")
    events: queue.Queue = queue.Queue()
    link = CapturingTransport([events])
    error = link.open()
    if error:
        raise RuntimeError(error)

    results = []
    last_frame_id = 0
    try:
        status = query_status(link, events, args.timeout)
        auto = re.search(r"自动轮播=(开|关)", status["text"])
        if auto and auto.group(1) == "开":
            link.send_key("a")
            wait_event(events, lambda item: item.get("type") == "pkt" and
                       item.get("kind") == "ack" and "ACK 自动轮播" in item.get("text", ""),
                       args.timeout, "disable auto-advance")
            status = query_status(link, events, args.timeout)

        for attempt in range(1, args.images + 1):
            old_index = status_index(status["text"])
            started = time.monotonic()
            link.send_key("n")
            command_ack = wait_event(events, lambda item: item.get("type") == "pkt" and
                                     item.get("kind") == "ack" and "ACK 下一张" in item.get("text", ""),
                                     args.timeout, f"image {attempt} N command ACK")
            deadline = time.monotonic() + args.timeout
            time.sleep(min(args.settle_seconds, args.timeout))
            while True:
                status = query_status(link, events, max(0.5, deadline - time.monotonic()))
                image_index = status_index(status["text"])
                if image_index != old_index:
                    break
                if time.monotonic() >= deadline:
                    raise TimeoutError(f"image index did not advance from {old_index}; last status={status['text']}")
                time.sleep(min(1.0, max(0.0, deadline - time.monotonic())))
            commit_seconds = time.monotonic() - started
            paired_committed = "+wav" in status["text"]

            with ETH_FRAME_LOCK:
                last_frame_id = ETH_FRAME_SNAPSHOT["id"]
            link.snapshot_pcm = b""
            link.snapshot_pcm_count = 0
            started = time.monotonic()
            link.send_key("d")
            frame_event = wait_event(events, lambda item: item.get("type") == "frame" and
                                     item.get("source") == "snapshot" and
                                     item.get("id", 0) > last_frame_id,
                                     args.timeout, f"image {attempt} D snapshot")
            snapshot_seconds = time.monotonic() - started
            with ETH_FRAME_LOCK:
                frame = dict(ETH_FRAME_SNAPSHOT)
            raw = frame["data"]
            if frame["gaps"] != 0 or frame["words"] != FRAME_WORDS or len(raw) != FRAME_WORDS * 4:
                args.captures.joinpath(f"{run_tag}_frame{attempt}_bad.bin").write_bytes(raw)
                raise RuntimeError(f"invalid D frame metadata: {frame['words']} words, gaps={frame['gaps']}, bytes={len(raw)}")

            match_name = None
            orientation = None
            for name, (expected, expected_bottom_up) in golden.items():
                if raw == expected:
                    match_name, orientation = name, "top-down"
                    break
                if raw == expected_bottom_up:
                    match_name, orientation = name, "bottom-up"
                    break
            if match_name is None:
                args.captures.joinpath(f"{run_tag}_frame{attempt}_mismatch.bin").write_bytes(raw)
                raise RuntimeError(f"D frame {attempt} does not exactly match any BMP golden")

            image_stem = Path(match_name).stem.upper()
            expected_pcm = card_pcm.get(f"{image_stem}.WAV")
            mirror_pair_match = (expected_pcm is not None) == paired_committed

            link.send_key("i")
            diag = wait_event(events, lambda item: item.get("type") == "pkt" and
                              item.get("kind") == "diag", args.timeout, "SD timing diagnostic")
            record = {"cycle": attempt, "board_index": image_index, "bmp": match_name,
                      "orientation": orientation, "image_words": frame["words"],
                      "n_ack": command_ack["text"],
                      "committed_status": status["text"],
                      "image_gaps": frame["gaps"],
                      "paired_audio_committed": paired_committed,
                      "card_mirror_pair_match": mirror_pair_match,
                      "mirror_pcm_bytes": len(expected_pcm) if expected_pcm is not None else 0,
                      "d_snapshot_audio_payload_bytes": len(link.snapshot_pcm),
                      "commit_seconds": round(commit_seconds, 4),
                      "snapshot_seconds": round(snapshot_seconds, 4),
                      "diagnostic": diag["text"]}
            results.append(record)
            print(json.dumps(record, ensure_ascii=False), flush=True)

        found = {record["bmp"] for record in results}
        if len(found) < args.images:
            raise RuntimeError(f"{args.images} advances produced only {len(found)} unique images: {sorted(found)}")
        report = {"run": run_tag, "results": results, "unique_images": sorted(found),
                  "card_wavs": {name: len(pcm) for name, pcm in card_pcm.items()}}
        report_path = args.captures / f"{run_tag}_sd_board_acceptance.json"
        report_path.write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding="utf-8")
        print(f"PASS: {len(found)} unique BMPs and board-reported paired/silent audio commits verified; report={report_path}", flush=True)
    finally:
        link.close()


if __name__ == "__main__":
    main()
