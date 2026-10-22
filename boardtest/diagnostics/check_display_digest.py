#!/usr/bin/env python3
"""Compare actual display SDRAM scan digests to independent padded BMP goldens.

Requires the isolated display_frame_digest candidate and the normal media bit.
Uses local Flask HTTP for N/S/D and a separate UDP :4 for the display probe.
This is an acceptance tool, not a product protocol extension.
"""
from __future__ import annotations
import argparse
import json
import queue
import re
import socket
import struct
import sys
import threading
import time
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts"))
from analyze_frame_dump import expected_from_bmp
from media_sd_board_acceptance import build_golden_frames

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--steps", type=int, default=6)
    parser.add_argument("--url", default="http://127.0.0.1:5000")
    parser.add_argument("--display", default="192.168.137.2")
    parser.add_argument("--source-only", action="store_true",
                        help="product-bit smoke check: commit plus source D only, no SDRAM claim")
    parser.add_argument("--output", type=Path,
                        default=ROOT / "boardtest/captures/display_digest_stage1/acceptance.json")
    args = parser.parse_args()
    events = queue.Queue()
    def listen():
        with urllib.request.urlopen(args.url + "/api/stream", timeout=180) as stream:
            for line in stream:
                if line.startswith(b"data: "):
                    events.put(json.loads(line[6:]))
    threading.Thread(target=listen, daemon=True).start()
    def http(path, payload=None, head=False):
        request = urllib.request.Request(args.url + path,
                    data=None if payload is None else json.dumps(payload).encode(),
                    headers={} if payload is None else {"Content-Type": "application/json"},
                    method="HEAD" if head else ("GET" if payload is None else "POST"))
        with urllib.request.urlopen(request, timeout=15) as response:
            return response.headers, response.read()
    def command(key):
        _, body = http("/api/cmd", {"mode": "eth", "key": key})
        if not json.loads(body).get("ok"):
            raise RuntimeError(f"command {key} rejected: {body!r}")
    def status():
        command("s")
        end = time.monotonic() + 4
        while time.monotonic() < end:
            try:
                event = events.get(timeout=.25)
            except queue.Empty:
                continue
            if event.get("kind") == "status":
                text = event["text"]
                match = re.search(r"media-TX=(\S+) error=.*?\((\d+)\).*?img=(\d+)", text)
                if match:
                    return match.group(1), int(match.group(2)), int(match.group(3)), text
        raise TimeoutError("no current media status")
    raw_goldens = build_golden_frames(ROOT / "img/golden")
    goldens = {}
    for name in raw_goldens:
        _, display, _ = expected_from_bmp(ROOT / "img/golden" / name)
        ordered = 0
        for word in display:
            ordered = ((ordered * 33) ^ word) & 0xffffffff
        write_ordered=0
        for row in range(719,-1,-1):
            for word in display[row*640:(row+1)*640]:
                write_ordered=((write_ordered*33)^word)&0xffffffff
        raw_words=struct.unpack('<'+'I'*(len(raw_goldens[name][0])//4),raw_goldens[name][0])
        raw_ordered=0
        for word in raw_words:raw_ordered=((raw_ordered*33)^word)&0xffffffff
        goldens[name] = (sum(display) & 0xffffffff, ordered, write_ordered,
                         sum(raw_words)&0xffffffff,raw_ordered,len(raw_words))
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.bind(("", 4))
    sock.settimeout(.3)
    request = bytes.fromhex("aa bb cc dd 00 47 00 00")
    records = []
    time.sleep(.3)
    try:
        for step in range(args.steps):
            _, error, previous_index, _ = status()
            command("n")
            end = time.monotonic() + 20
            while time.monotonic() < end:
                time.sleep(.3)
                mode, error, index, text = status()
                if error:
                    raise RuntimeError(text)
                if mode == "idle" and index != previous_index:
                    break
            else:
                raise TimeoutError("N did not commit a new image")
            header, _ = http("/api/frame?slot=snapshot", head=True)
            old_id = header["X-Frame-Id"]
            command("d")
            end = time.monotonic() + 20
            while time.monotonic() < end:
                time.sleep(.2)
                header, _ = http("/api/frame?slot=snapshot", head=True)
                if header["X-Frame-Id"] != old_id:
                    header, raw = http("/api/frame?slot=snapshot")
                    break
            else:
                raise TimeoutError("D did not return a new source snapshot")
            size = int(header["X-Frame-Width"]), int(header["X-Frame-Height"])
            names = [name for name, (gold, w, h) in raw_goldens.items()
                     if (w, h) == size and gold == raw]
            if len(names) != 1 or int(header["X-Frame-Gaps"]) != 0:
                raise ValueError(f"source snapshot mismatch: size={size}, matches={names}")
            name = names[0]
            if args.source_only:
                record = {"step": step + 1, "bmp": name, "source_size": size,
                          "source_words": int(header["X-Frame-Words"]), "index": index,
                          "validation": "commit-and-source-only"}
                records.append(record)
                print("PASS", json.dumps(record), flush=True)
                continue
            expected_sum, expected_hash, expected_write_hash, raw_sum, raw_hash, raw_count = goldens[name]
            end = time.monotonic() + 8
            last = None
            while time.monotonic() < end:
                sock.sendto(request, (args.display, 1))
                try:
                    data, _ = sock.recvfrom(2048)
                except socket.timeout:
                    continue
                if len(data) != 72 or data[:8] != bytes.fromhex("aa bb cc dd 00 47 00 40"):
                    continue
                frame, magic, bank, count, total, ordered = struct.unpack("<HBBIII", data[8:24])
                wf, wm, wb, wc, ws, wh = struct.unpack("<HBBIII", data[24:40])
                rf, rm, rb, rc, rs, rh = struct.unpack("<HBBIII", data[40:56])
                pf, pm, pb, pc, ps, ph = struct.unpack("<HBBIII", data[56:72])
                last = {"scan":(frame,magic,bank,count,total,ordered),"write":(wf,wm,wb,wc,ws,wh),
                        "producer":(rf,rm,rb,rc,rs,rh),"padded":(pf,pm,pb,pc,ps,ph)}
                if (magic == 0xd9 and wm == 0xda and count == wc == 460800 and
                    rm == 0xdd and pm == 0xdc and pc == rc == 460800 and
                    (total, ordered, ws, wh, ps, ph, rs, rh) ==
                    (expected_sum, expected_hash, expected_sum, expected_write_hash,
                     expected_sum,expected_write_hash,expected_sum,expected_write_hash)):
                    break
                time.sleep(.04)
            else:
                raise ValueError(f"display scan mismatch for {name}: got={last}, "
                                 f"expected sum={expected_sum:08x} scan_hash={expected_hash:08x} write_hash={expected_write_hash:08x} "
                                 f"raw_sum={raw_sum:08x} raw_hash={raw_hash:08x}")
            record = {"step": step + 1, "bmp": name, "source_size": size,
                      "source_words": int(header["X-Frame-Words"]), "index": index,
                      "scan_frame": frame, "bank": bank, "scan_words": count,
                      "scan_sum": f"{total:08x}", "scan_ordered_hash": f"{ordered:08x}",
                      "write_bank":wb,"write_words":wc,"write_sum":f"{ws:08x}","write_hash":f"{wh:08x}",
                      "producer_words":rc,"producer_sum":f"{rs:08x}","producer_hash":f"{rh:08x}",
                      "padded_words":pc,"padded_sum":f"{ps:08x}","padded_hash":f"{ph:08x}"}
            records.append(record)
            print("PASS", json.dumps(record), flush=True)
        if len({r["bmp"] for r in records}) < min(args.steps, 6):
            raise ValueError("coverage did not include the expected unique BMPs")
        args.output.write_text(json.dumps({"results": records}, indent=2), encoding="utf-8")
        print("PASS: commit and source D verified (no display pixel assertion)" if args.source_only else
              "PASS: source integrity plus actual display SDRAM scan count/sum/order verified", flush=True)
    finally:
        args.output.write_text(json.dumps({"results":records,"error":repr(sys.exc_info()[1]) if sys.exc_info()[1] else None},indent=2),encoding="utf-8")
        sock.close()

if __name__ == "__main__":
    main()
