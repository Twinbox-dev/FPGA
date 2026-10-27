"""Check product video admission and still-image restoration on one display FPGA.

Uses ordinary product image/control packets plus the VD/AD sender; no temporary
FPGA diagnostic build is needed. HDMI appearance and audio still need observation.
"""
from __future__ import annotations

import argparse
import json
import socket
import struct
import subprocess
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
VIDEO_PROFILE = json.loads((ROOT / "scripts" / "direct_video_profile.json").read_text(encoding="utf-8"))
sys.path.insert(0, str(ROOT / "scripts" / "web_console"))
import app as console
from media_upload import control_packet, image_packet, rgb24_to_native_words, resolve_ffmpeg


def view(link):
    return list(link._refresh_display_view(2.0))


def wait_for_view(link, predicate, timeout: float, description: str):
    """Poll authoritative FPGA state across its control/status publication latency."""
    deadline = time.monotonic() + timeout
    last = None
    while time.monotonic() < deadline:
        last = view(link)
        if predicate(last):
            return last
        time.sleep(0.05)
    raise TimeoutError(f"display did not publish {description}; last state={last}")


def settings(link, opcode, payload, response_kind):
    link._send_display(control_packet(opcode, payload))
    deadline = time.monotonic() + 3
    while time.monotonic() < deadline:
        link.upload_sock.settimeout(max(0.001, deadline - time.monotonic()))
        data, peer = link.upload_sock.recvfrom(2048)
        if peer[0] != link.DISPLAY_IP or len(data) < 9 or data[:4] != b"\xaa\xbb\xcc\xdd":
            continue
        kind, size = struct.unpack_from(">HH", data, 4)
        if kind == response_kind and size == len(data) - 8 and data[8] == payload[0]:
            return data[8:]
    raise TimeoutError(f"no control ACK 0x{response_kind:04x}")


def populate_layout(link, layout):
    """PC models only the existing media PREPARE/image/empty-WAV transactions."""
    current = view(link)
    if current[4]:
        raise RuntimeError("cannot change layout while another transaction is active")
    if current[3] and layout and current[3] != layout:
        populate_layout(link, 0)  # Product rule: multi -> single -> other multi.
        current = view(link)
    generation = struct.unpack_from("<H", bytes(current), 1)[0]
    sequence = link._next_display_sequence()
    link._send_display(control_packet(0x49, struct.pack("<BBBBHH", sequence, 0, layout, 0xFF, generation, 0)))
    reply = link._wait_display(0x4A, 3, lambda b: len(b) == 8 and b[0] == sequence)
    if reply[1]:
        raise RuntimeError(f"layout PREPARE rejected: {reply[1]}")
    generation = struct.unpack_from("<H", reply, 4)[0]
    count = (1, 2, 4)[layout] if layout != current[3] else 1
    width, height = 320, 180
    for slot in range(count):
        window = slot if count > 1 else reply[2]
        pixels = bytes(channel for y in range(height) for x in range(width)
                       for channel in (x * 255 // (width - 1),
                                       y * 255 // (height - 1), (window + 1) * 48))
        words, checksum = rgb24_to_native_words(pixels, width, height)
        frame = link.display_frame_id
        link.display_frame_id = (frame + 1) & 65535
        index = (reply[6] + window) % 6
        link._send_display(image_packet(0x21, struct.pack("<HBBIHHBBH", frame, index, 0,
                          len(words) // 4, width, height, layout, window, generation)))
        for packet_seq, offset in enumerate(range(0, len(words), 253 * 4)):
            link._send_display(image_packet(0x22, struct.pack("<HH", frame, packet_seq) + words[offset:offset + 253 * 4]))
            time.sleep(0.004)
        time.sleep(0.001)
        link._send_display(image_packet(0x23, struct.pack("<HIH", frame, checksum, 0)))
        result = link._wait_display(0x24, 12, lambda b: len(b) == 3 and int.from_bytes(b[:2], "little") == frame)
        if layout == 0:
            if result[2] != 0:
                raise RuntimeError(f"single image rejected: {result[2]}")
            link._send_display(image_packet(0x30, struct.pack("<HIH", frame, 0, 0)))
            link._send_display(image_packet(0x32, struct.pack("<HIH", frame, 0, 0)))
            link._wait_display(0x33, 5, lambda b: len(b) == 3 and int.from_bytes(b[:2], "little") == frame and b[2] == 0)
            link._wait_display(0x24, 5, lambda b: len(b) == 3 and int.from_bytes(b[:2], "little") == frame and b[2] == 2)
        elif result[2] != (2 if slot == count - 1 else 3):
            raise RuntimeError(f"multi-view slot rejected: {result[2]}")
    final = view(link)
    if final[3] != layout or final[4] or final[6] != (1, 3, 15)[layout]:
        raise AssertionError("layout did not atomically commit all windows")
    return final


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--input", required=True, type=Path)
    parser.add_argument("--frames", type=int, default=1800)
    parser.add_argument("--audio", action="store_true")
    parser.add_argument("--prefetch", type=int, choices=range(17), default=16,
                        help="bounded FFmpeg frame prefetch used by the product sender")
    parser.add_argument("--upload-still", action="store_true")
    parser.add_argument("--layout", type=int, choices=(0, 1, 2),
                        help="populate a synthetic single/dual/quad page before video; replaces images")
    parser.add_argument("--output", type=Path,
                        default=ROOT / "boardtest/captures/video_integration/product_probe.json")
    args = parser.parse_args()
    args.output.parent.mkdir(parents=True, exist_ok=True)
    link = console.EthTransport()
    # An ephemeral test socket does not displace an existing web console.
    link.LOCAL_PORT = 0
    error = link.open()
    if error:
        raise RuntimeError(error)
    process = None
    result = {"visual_acceptance": "requires human observation"}
    status = args.output.with_suffix(".video.json")
    log_path = args.output.with_suffix(".video.log")
    try:
        if args.upload_still:
            width, height = 320, 180
            pixels = bytes(channel for y in range(height) for x in range(width)
                           for channel in (x * 255 // (width - 1),
                                           y * 255 // (height - 1), 96))
            result["still_upload"] = link.upload_image(pixels, width, height)
        link.upload_sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        link.upload_sock.bind((link.LOCAL_IP, 0))
        if args.layout is not None:
            result["layout_setup"] = populate_layout(link, args.layout)
        before = view(link)
        if before[4]:
            raise RuntimeError("display is busy before video; do not interrupt the existing transaction")
        result["before"] = before
        initial_settings = settings(link, 0x42, bytes((link._next_display_sequence(),)), 0x43)
        result["settings_before"] = list(initial_settings)
        command = [sys.executable, str(ROOT / "scripts/direct_video_sender.py"),
                   "--input", str(args.input.resolve()), "--frames", str(args.frames),
                   "--window", "512", "--require-ready", "--quiet", "--ffmpeg", resolve_ffmpeg(),
                   "--prefetch", str(args.prefetch),
                   "--status-file", str(status), "--status-interval", "1"]
        if args.audio:
            command.append("--audio")
        with log_path.open("wb") as log:
            process = subprocess.Popen(command, stdout=log, stderr=subprocess.STDOUT,
                                       creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0))
        deadline = time.monotonic() + 15
        while time.monotonic() < deadline:
            if process.poll() is not None:
                raise RuntimeError(f"sender exited during startup; inspect {log_path}")
            try:
                progress = json.loads(status.read_text(encoding="utf-8"))
            except (OSError, ValueError):
                progress = {}
            if progress.get("ready_received") and progress.get("frames", 0) >= 3:
                break
            time.sleep(0.1)
        else:
            raise TimeoutError("no READY and advancing frames")
        # The video lease crosses into the SDRAM/pixel domains before the
        # view manager publishes external_busy. Do not treat the first stale
        # status snapshot as a functional failure.
        during = wait_for_view(link, lambda state: state[4] == 1, 3.0, "video busy")
        result["during"] = during
        print(f"Video READY: HDMI should now show the selected {VIDEO_PROFILE['width']}x{VIDEO_PROFILE['height']} video", flush=True)
        generation = struct.unpack_from("<H", bytes(during), 1)[0]
        sequence = link._next_display_sequence()
        prepare = struct.pack("<BBBBHH", sequence, 0, during[3], 0xFF, generation, 0)
        link._send_display(control_packet(0x49, prepare))
        reply = link._wait_display(0x4A, 2, lambda body: len(body) == 8 and body[0] == sequence)
        result["busy_prepare_reply"] = list(reply)
        if reply[1] != 1:
            raise AssertionError("new image transaction was not rejected during video")
        volume = (initial_settings[1] + 1) % 9
        for value in (volume, initial_settings[1]):
            seq = link._next_display_sequence()
            ack = settings(link, 0x40, bytes((seq, 1, value, 0)), 0x41)
            if ack != bytes((seq, 1, 0, value)):
                raise AssertionError("volume ACK changed or was misrouted during video")
        result["volume_during_video"] = True
        if process.wait(timeout=max(30, args.frames / 50 + 20)):
            raise RuntimeError(f"sender failed; inspect {log_path}")
        result["video"] = json.loads(status.read_text(encoding="utf-8"))
        if result["video"].get("skipped_rows") or not result["video"].get("ready_received"):
            raise AssertionError("sender skipped rows or never received READY")
        if any(result["video"].get("receiver_health", {}).values()):
            raise AssertionError("receiver reported missing video/audio during playback")
        deadline = time.monotonic() + 8
        while time.monotonic() < deadline:
            after = view(link)
            if not after[4]:
                break
            time.sleep(0.2)
        else:
            raise TimeoutError("display did not release video ownership")
        result["after"] = after
        # Layout, generation, validity, indices and source dimensions must survive.
        # READY defines the actual handoff: a transaction already accepted
        # before the video request is allowed to finish before this snapshot.
        for start, end in ((1, 4), (6, 11)):
            if during[start:end] != after[start:end]:
                raise AssertionError("original still-image metadata changed during video")
        if during[5] == after[5] and during[11:15] != after[11:15]:
            raise AssertionError("source dimensions changed without a focus change")
        result["protocol_pass"] = True
        print("PASS video READY, busy rejection, playback and original layout/image metadata restoration")
    finally:
        if process is not None and process.poll() is None:
            subprocess.run(["taskkill", "/PID", str(process.pid), "/T", "/F"],
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=False)
        link.close()
        args.output.write_text(json.dumps(result, ensure_ascii=False, indent=2), encoding="utf-8")


if __name__ == "__main__":
    main()
