#!/usr/bin/env python3
"""Stream configured RGB565 video rows to the display board's direct HDMI path."""

from __future__ import annotations

import argparse
import binascii
import collections
import json
import os
import secrets
import select
import signal
import shutil
import socket
import struct
import subprocess
import sys
import time
from pathlib import Path
from typing import Optional

WIDTH = 720
HEIGHT = 360
BYTES_PER_PIXEL = 2
ROW_BYTES = WIDTH * BYTES_PER_PIXEL
FRAME_BYTES = WIDTH * HEIGHT * BYTES_PER_PIXEL
ROW_HEADER = struct.Struct("<2sBBHHHH")
FEEDBACK_HEADER = struct.Struct("<2sBBHBB")
ROW_MAGIC = b"VD"
FEEDBACK_MAGIC = b"VA"
VERSION = 1
CREDIT = 1
NACK = 2
STATUS = 3
READY = 9
AUDIO_SAMPLES = 396
SESSION_START = 1
WINDOW = 32
DATA_PORT = 1
FEEDBACK_PORT = 4


def make_row_packet(frame_id: int, y: int, pixels: bytes, flags: int = 0,
                    *, width: int = WIDTH, height: int = HEIGHT) -> tuple[int, bytes]:
    if len(pixels) != width*BYTES_PER_PIXEL:
        raise ValueError(f"row must be {width*BYTES_PER_PIXEL} bytes, got {len(pixels)}")
    if flags & ~SESSION_START:
        raise ValueError("only SESSION_START is currently defined")
    if flags and y != 0:
        raise ValueError("SESSION_START is valid only on row zero")
    sequence = (frame_id * height + y) & 0xFFFF
    header = ROW_HEADER.pack(ROW_MAGIC, VERSION, flags, frame_id & 0xFFFF,
                             y, sequence, width)
    body = header + pixels
    crc = binascii.crc_hqx(body, 0xFFFF)
    return sequence, body + struct.pack("<H", crc)


def make_audio_packet(frame_id:int, samples:bytes)->bytes:
    if len(samples)!=AUDIO_SAMPLES:raise ValueError("audio block must contain 396 unsigned 8-bit mono samples")
    body=struct.pack('<2sBBHH',b'AD',1,0,frame_id&65535,AUDIO_SAMPLES)+samples
    return body+struct.pack('<H',binascii.crc_hqx(body,0xffff))


def read_exact(stream, size: int) -> Optional[bytes]:
    chunks = bytearray()
    while len(chunks) < size:
        block = stream.read(size - len(chunks))
        if not block:
            return None if not chunks else bytes(chunks)
        chunks.extend(block)
    return bytes(chunks)


def make_pattern_base(width: int = WIDTH, height: int = HEIGHT) -> bytes:
    # Seven static color bars plus a checker boundary; a bright vertical marker
    # is moved in software for each frame without rebuilding the whole image.
    bars = (0xF800, 0xFFE0, 0x07FF, 0x07E0, 0xF81F, 0xF800, 0x001F, 0x0000)
    image = bytearray(width*height*BYTES_PER_PIXEL)
    bar_width=max(1,width//8)
    for y in range(height):
        for x in range(width):
            color = bars[min(x // bar_width, len(bars) - 1)]
            if (x % bar_width == 0) or (y % max(1,height//8) == 0):
                color = 0xFFFF
            struct.pack_into("<H", image, 2 * (y * width + x), color)
    return bytes(image)


def make_pattern_frame(base: bytes, frame_id: int, width: int = WIDTH, height: int = HEIGHT) -> bytes:
    image = bytearray(base)
    marker_x = (frame_id * 7) % width
    marker_y = (frame_id * 3) % height
    for y in range(height):
        struct.pack_into("<H", image, 2 * (y * width + marker_x), 0xFFFF)
    row_start = 2 * marker_y * width
    for x in range(width):
        struct.pack_into("<H", image, row_start + 2 * x, 0xFFFF)
    return bytes(image)


class Sender:
    def __init__(self, bind_ip: str, board_ip: str, initial_sequence: int, quiet: bool = False,
                 *, data_port: int = DATA_PORT, feedback_port: int = FEEDBACK_PORT,
                 feedback_timeout: float = 3.0, startup_timeout=None, trace_timing=False, status_callback=None,
                 width: int = WIDTH, height: int = HEIGHT, window: int = WINDOW, send_buffer: int = 0, require_ready: bool = False):
        self.board = (socket.gethostbyname(board_ip), data_port)
        self.sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        if not 0<=send_buffer<=4*1024*1024:
            self.sock.close();raise ValueError('send_buffer must be 0..4 MiB')
        if send_buffer:self.sock.setsockopt(socket.SOL_SOCKET,socket.SO_SNDBUF,send_buffer)
        self.socket_buffers=dict(send=self.sock.getsockopt(socket.SOL_SOCKET,socket.SO_SNDBUF),
                                 receive=self.sock.getsockopt(socket.SOL_SOCKET,socket.SO_RCVBUF))
        self.send_would_block=0
        try:
            self.sock.bind((bind_ip, feedback_port))
        except OSError:
            self.sock.close()
            raise
        self.sock.setblocking(False)
        self.consumed_sequence = 0
        self.initial_sequence = initial_sequence & 0xFFFF
        self.have_credit = False
        self.require_ready=require_ready;self.ready_received=False;self.initial_frame=None
        self.diagnostic_mode = None
        self.reported_free = 0
        self.cache: collections.OrderedDict[int, bytes] = collections.OrderedDict()
        self.sent_rows = 0
        self.retries = 0
        self.missing_cache = 0
        self.credit_messages = 0
        self.skipped_rows = 0
        self.quiet = quiet
        self.last_wait_notice = time.monotonic()
        self.last_credit_progress = self.last_wait_notice
        self.feedback_timeout = feedback_timeout
        self.startup_timeout=feedback_timeout if startup_timeout is None else startup_timeout
        self.last_bootstrap_retry=self.last_wait_notice
        self.status_callback = status_callback
        self.width, self.height = width, height
        self.row_bytes = width*BYTES_PER_PIXEL
        self.frame_bytes = self.row_bytes*height
        self.window = window
        self.trace_timing=trace_timing
        self._absolute_credit_advance=0
        self._last_credit_timing=None
        self._last_feedback_poll=None
        self.credit_timing=dict(clock=time.get_clock_info("perf_counter").implementation,clock_resolution=time.get_clock_info("perf_counter").resolution,active_samples=0,max_gap_ms=0.0,max_excess_ms=0.0,
            gap_over_0_5ms=0,gap_over_1ms=0,gap_over_2ms=0,outliers=[])
        self.started_at = None
        self.receiver_stats = {}
        self._stats_previous = {}
        self.receiver_reasons = {}
        self.receiver_health={};self.receiver_hybrid = {};self.receiver_readback = {};self.receiver_audio={}
        self._audio_previous={};self.sent_audio_blocks=0
        self._hybrid_previous = {};self._readback_previous = {}
        self.receiver_reason_initial = {}
        self._reasons_previous = {}
        self.credit_clock=dict(samples=0,last_tick=None,elapsed_ticks=0,first_pc=None,
                               min_offset_ms=None,max_offset_ms=None,largest_transitions=[])
        self._last_credit_clock_offset=None

    def report(self, state: str):
        if self.status_callback:
            self.status_callback(state=state, rows=self.sent_rows, retries=self.retries,
                                 skipped_rows=self.skipped_rows, credits=self.credit_messages,
                                 have_credit=self.have_credit,ready_received=self.ready_received,socket_buffers=self.socket_buffers,send_would_block=self.send_would_block,receiver_stats=self.receiver_stats,receiver_reasons=self.receiver_reasons,receiver_hybrid=self.receiver_hybrid,receiver_readback=self.receiver_readback,receiver_audio=self.receiver_audio,receiver_health=self.receiver_health,audio_blocks=self.sent_audio_blocks,credit_clock=self.credit_clock,credit_timing=self.credit_timing)

    def close(self):
        self.sock.close()

    def process_feedback(self):
        poll_now=time.perf_counter() if self.trace_timing else 0
        poll_gap=0 if self._last_feedback_poll is None else poll_now-self._last_feedback_poll
        self._last_feedback_poll=poll_now
        changed = False
        pending_nacks = set()
        # Bound feedback work so a NACK burst cannot starve new pixel rows.
        # Coalesce duplicates and apply all queued credits before retransmits.
        for _ in range(64):
            try:
                packet, source = self.sock.recvfrom(2048)
            except BlockingIOError:
                break
            if source != self.board or len(packet) not in (FEEDBACK_HEADER.size,12,32):
                continue
            magic, version, opcode, sequence, credits, _reserved = FEEDBACK_HEADER.unpack_from(packet)
            if magic != FEEDBACK_MAGIC or version != VERSION:
                continue
            if opcode in (3,4,7,8) and len(packet)==32:self.diagnostic_mode=int(bool(_reserved&128))
            if opcode==10 and len(packet)==32:
                names=('accepted','bad_packets','good_blocks','missing_frames','bad_blocks','duplicates')
                for name,value in zip(names,struct.unpack_from('<6I',packet,8)):
                    value&=65535
                    self.receiver_audio[name]=self.receiver_audio.get(name,value)+((value-self._audio_previous[name])&65535 if name in self._audio_previous else 0)
                    self._audio_previous[name]=value
                continue
            if opcode in (7,8) and len(packet)==32:
                values=[x&65535 for x in struct.unpack_from('<6I',packet,8)]
                names=("spills","prefetches","fast_rows","crc_bad","tag_bad","port_fault") if opcode==7 else ("good","bad","last_actual","last_expected","last_sequence","reserved")
                target=self.receiver_hybrid if opcode==7 else self.receiver_readback
                previous=self._hybrid_previous if opcode==7 else self._readback_previous
                for index,(name,value) in enumerate(zip(names,values)):
                    if opcode==7 or index<2:
                        target[name]=target.get(name,value)+((value-previous[name])&65535 if name in previous else 0)
                        previous[name]=value
                    else:target[name]=value
                continue
            if opcode == 4 and len(packet)==32:
                values=struct.unpack_from("<6I",packet,8)
                names=("late_begin","late_commit","future","occupied","bad_crc","inactive")
                for name,value in zip(names,values):
                    value&=65535
                    if name in self._reasons_previous:self.receiver_reasons[name]+=(value-self._reasons_previous[name])&65535
                    else:
                        self.receiver_reasons[name]=value
                        self.receiver_reason_initial[name]=value
                    self._reasons_previous[name]=value
                continue
            if opcode == STATUS and len(packet)==32:
                values=struct.unpack_from("<6I",packet,8)
                names=("parser_accepted","parser_rejected","store_accepted","store_rejected","duplicates","underflows")
                bits=16 if (_reserved&127)==16 else 32
                mask=(1<<bits)-1
                for name,value in zip(names,values):
                    value&=mask
                    if name in self._stats_previous:
                        self.receiver_stats[name]+=(value-self._stats_previous[name])&mask
                    else:
                        self.receiver_stats[name]=value
                    self._stats_previous[name]=value
                self.receiver_stats.update(consumed_sequence=sequence,free_rows=credits,counter_bits=bits)
                continue
            if len(packet)!=FEEDBACK_HEADER.size and not (opcode==CREDIT and len(packet)==12 and _reserved==4):
                continue
            if opcode == READY and len(packet)==8:
                ready_frame=credits|(_reserved<<8)
                if self.require_ready and not self.ready_received and sequence==self.initial_sequence and ready_frame==self.initial_frame:
                    self.ready_received=True;self.consumed_sequence=sequence
                    self.have_credit=True;self.last_credit_progress=time.monotonic();changed=True
                continue
            if self.require_ready and not self.ready_received and opcode in (CREDIT,NACK):continue
            if opcode == CREDIT:
                if len(packet)==8:
                    self.diagnostic_mode=int(bool(_reserved&1))
                    if self.diagnostic_mode:continue  # Never feed an external stream into an active local test.
                    self.receiver_health=dict(video_missing=bool(_reserved&2),audio_missing=bool(_reserved&4))
                base = self.consumed_sequence if self.have_credit else self.initial_sequence
                advance = (sequence - base) & 0xFFFF
                # Ignore reordered/backward credits, including a previous session.
                if advance >= 0x8000:
                    continue
                if len(packet)==12:self._record_credit_clock(struct.unpack_from('<I',packet,8)[0],time.perf_counter(),sequence)
                if not self.have_credit or advance:
                    now=time.monotonic()
                    if self.trace_timing:self._record_credit_timing(advance,time.perf_counter(),poll_gap)
                    self.last_credit_progress = now
                self.consumed_sequence = sequence
                self.have_credit = True
                self.reported_free = credits
                self.credit_messages += 1
                changed = True
            elif opcode == NACK:
                pending_nacks.add(sequence)
        for sequence in pending_nacks:
            if self.have_credit and ((sequence - self.consumed_sequence) & 0xFFFF) >= 0x8000:
                continue
            row_packet = self.cache.get(sequence)
            if row_packet is None:
                self.missing_cache += 1
                if not self.quiet:
                    print(f"NACK seq={sequence}, row no longer in PC cache", flush=True)
            else:
                self._send(row_packet)
                self.retries += 1
                if not self.quiet:
                    print(f"retransmit row seq={sequence} to {self.board[0]}", flush=True)
        return changed

    def _record_credit_clock(self,tick,pc_now,sequence):
        clock=self.credit_clock
        if clock['last_tick'] is None:
            clock['first_pc']=pc_now
        else:clock['elapsed_ticks']+=(tick-clock['last_tick'])&0xffffffff
        clock['last_tick']=tick;clock['samples']+=1
        # Offset has an unknown constant transport latency. Its variation shows
        # extra delivery delay relative to the FPGA's own send clock.
        offset=(pc_now-clock['first_pc']-clock['elapsed_ticks']/125000000)*1000
        clock['min_offset_ms']=offset if clock['min_offset_ms'] is None else min(clock['min_offset_ms'],offset)
        clock['max_offset_ms']=offset if clock['max_offset_ms'] is None else max(clock['max_offset_ms'],offset)
        previous=self._last_credit_clock_offset
        if previous is not None and offset-previous>0.5:
            clock['largest_transitions'].append(dict(sequence=sequence,extra_delay_ms=offset-previous,pc_elapsed_ms=(pc_now-clock['first_pc'])*1000))
            clock['largest_transitions'].sort(key=lambda x:x['extra_delay_ms'],reverse=True)
            del clock['largest_transitions'][32:]
        self._last_credit_clock_offset=offset

    def _record_credit_timing(self,advance,now,poll_gap):
        self._absolute_credit_advance+=advance
        phase=self._absolute_credit_advance%self.height
        previous=self._last_credit_timing
        if previous is not None:
            last_now,last_absolute,last_phase=previous
            lines=self._absolute_credit_advance-last_absolute
            # Phase zero is the long vertical blank, not a missing feedback
            # deadline. Only measure forward progress within the same image.
            if 0<last_phase<phase and 0<lines<self.height:
                gap_ms=(now-last_now)*1000
                expected_ms=lines*(1650/75000000)*1000
                excess_ms=gap_ms-expected_ms
                stats=self.credit_timing
                stats["active_samples"]+=1
                stats["max_gap_ms"]=max(stats["max_gap_ms"],gap_ms)
                stats["max_excess_ms"]=max(stats["max_excess_ms"],excess_ms)
                for threshold,key in ((0.5,"gap_over_0_5ms"),(1,"gap_over_1ms"),(2,"gap_over_2ms")):
                    if gap_ms>threshold:stats[key]+=1
                if gap_ms>0.5:
                    stats["outliers"].append(dict(pc_gap_ms=round(gap_ms,3),lines=lines,
                        ideal_line_ms=round(expected_ms,3),excess_ms=round(excess_ms,3),
                        poll_gap_ms=round(poll_gap*1000,3),phase=phase))
                    if len(stats["outliers"])>32:del stats["outliers"][0]
        self._last_credit_timing=(now,self._absolute_credit_advance,phase)

    def can_send(self, sequence: int) -> bool:
        base = self.consumed_sequence if self.have_credit else self.initial_sequence
        distance = (sequence - base) & 0xFFFF
        return distance < self.window

    def wait_for_ready(self):
        # Only the CRC-protected session row may precede READY. The display may
        # need a frame boundary and drain of an existing image/audio transfer.
        while not self.ready_received:
            self.process_feedback()
            if self.ready_received:return
            now=time.monotonic()
            if now-self.last_credit_progress>=self.startup_timeout:
                raise TimeoutError("Display did not grant video memory ownership/READY")
            if now-self.last_bootstrap_retry>=.1:
                first=self.cache.get(self.initial_sequence)
                if first is not None:self._send(first);self.retries+=1
                self.last_bootstrap_retry=now
            select.select([self.sock],[],[],.02)

    def wait_for_window(self, sequence: int):
        if self.require_ready and not self.ready_received and sequence!=self.initial_sequence:self.wait_for_ready()
        # Spend already granted credit in a burst instead of making an empty
        # recvfrom syscall before and after every row.
        base = self.consumed_sequence if self.have_credit else self.initial_sequence
        distance = (sequence - base) & 0xFFFF
        # Already-consumed rows can never become useful again. Do not perform
        # another recvfrom/poll for every obsolete row during catch-up.
        if distance >= 0x8000:
            return False
        if distance < self.window:
            return True
        while True:
            self.process_feedback()
            base = self.consumed_sequence if self.have_credit else self.initial_sequence
            distance = (sequence - base) & 0xFFFF
            if distance >= 0x8000:
                # Scanout cannot wait: discard expired rows and catch up rather
                # than blocking forever on a credit that can never arrive.
                return False
            if distance < self.window:
                return True
            now = time.monotonic()
            self.report("waiting")
            limit=self.feedback_timeout if self.have_credit else self.startup_timeout
            if not self.have_credit and now-self.last_bootstrap_retry>=0.1:
                # SRAM configuration can complete before PHY/ARP is ready.
                # Reissue the initial cached window until actual credit arrives.
                # SESSION_START is idempotent for the same session identifier.
                for initial_packet in tuple(self.cache.values()):
                    self._send(initial_packet)
                    self.retries+=1
                self.last_bootstrap_retry=now
            if now - self.last_credit_progress >= limit:
                raise TimeoutError(
                    f"No advancing display credit for {limit:g}s "
                    f"(next={sequence}, consumed={base}); check the matching display bit, "
                    "PC NIC address, and UDP feedback port")
            if not self.quiet and now - self.last_wait_notice >= 2.0:
                distance = (sequence - self.consumed_sequence) & 0xFFFF
                print(f"waiting for line credit: next={sequence} consumed={self.consumed_sequence} "
                      f"distance={distance} free={self.reported_free}", flush=True)
                self.last_wait_notice = now
            # Wait for the next FPGA credit datagram. A 0.5 ms sleep is
            # quantized by Windows to about 1 ms, far longer than one video line.
            select.select([self.sock], [], [], 0.05)

    def _send(self, packet: bytes):
        if self.started_at is None:
            self.started_at = time.monotonic()
            self.last_credit_progress = self.started_at
        while True:
            try:
                self.sock.sendto(packet, self.board)
                return
            except BlockingIOError:
                self.send_would_block+=1
                self.process_feedback()
                select.select([], [self.sock], [], 0.01)

    def send_frame(self, frame_id: int, pixels: bytes, start_session: bool = False, audio_samples: Optional[bytes] = None):
        if audio_samples is not None and len(audio_samples)!=AUDIO_SAMPLES:raise ValueError("audio block must contain 396 samples")
        if len(pixels) != self.frame_bytes:
            raise ValueError(f"frame must be {self.frame_bytes} bytes, got {len(pixels)}")
        if start_session and self.require_ready:
            self.initial_frame=frame_id&65535;self.ready_received=False;self.have_credit=False
            self.cache.clear()
        for y in range(self.height):
            sequence = (frame_id*self.height+y) & 0xFFFF
            if not self.wait_for_window(sequence):
                self.skipped_rows += 1
                continue
            # Do payload slicing, CRC and allocation only for useful rows.
            row = pixels[y * self.row_bytes:(y + 1) * self.row_bytes]
            flags = SESSION_START if start_session and y == 0 else 0
            sequence, packet = make_row_packet(frame_id, y, row, flags, width=self.width,height=self.height)
            self.cache[sequence] = packet
            self.cache.move_to_end(sequence)
            while len(self.cache) > 512:
                self.cache.popitem(last=False)
            self._send(packet)
            self.sent_rows += 1
            if start_session and y==0 and self.require_ready:self.wait_for_ready()
            if y==0 and audio_samples is not None:
                self._send(make_audio_packet(frame_id,audio_samples));self.sent_audio_blocks+=1
            if (y & 7) == 7:
                self.process_feedback()
            self.report("sending" if self.have_credit else "waiting")

    def print_summary(self, frame_id: int):
        if not self.quiet and (frame_id % 60 == 0):
            print(f"frame={frame_id} sent_rows={self.sent_rows} retries={self.retries} "
                  f"credits={self.credit_messages} uncached_nacks={self.missing_cache}",
                  flush=True)


def ffmpeg_frames(path: Path, ffmpeg: str, width: int = WIDTH, height: int = HEIGHT, prefetch: int = 0, fps: str = "60", loop: bool = True):
    import queue
    import threading
    if not path.is_file():
        raise FileNotFoundError(path)
    if not 0 <= prefetch <= 16:
        raise ValueError("prefetch depth must be between 0 and 16")
    command=[ffmpeg,"-hide_banner","-loglevel","error"]
    if loop:
        command.extend(["-stream_loop", "-1"])
    command += ["-i",str(path),"-an","-vf",
        (f"fps={fps},scale={width}:{height}:force_original_aspect_ratio=decrease:"
         f"flags=neighbor,pad={width}:{height}:(ow-iw)/2:(oh-ih)/2:black"),
        "-pix_fmt","rgb565le","-f","rawvideo","pipe:1"]
    process=subprocess.Popen(command,stdout=subprocess.PIPE)
    assert process.stdout is not None
    stop=threading.Event()
    ready=threading.Event()
    frames=queue.Queue(maxsize=max(1,prefetch))
    worker=None
    def read_frame():
        frame=read_exact(process.stdout,width*height*BYTES_PER_PIXEL)
        if frame is None:
            code=process.wait()
            if code:raise RuntimeError(f"FFmpeg decoding failed (exit {code}); see sender log")
            return None
        if len(frame)!=width*height*BYTES_PER_PIXEL:
            raise RuntimeError(f"ffmpeg ended mid-frame: {len(frame)} bytes")
        return frame
    def publish(kind,value):
        if kind!="frame":ready.set()
        while not stop.is_set():
            try:
                frames.put((kind,value),timeout=0.05)
                if frames.qsize()>=prefetch:ready.set()
                return True
            except queue.Full:pass
        return False
    def decode_worker():
        try:
            while not stop.is_set():
                frame=read_frame()
                if frame is None:publish("eof",None);return
                if not publish("frame",frame):return
        except Exception as exc:
            publish("error",exc)
        finally:ready.set()
    try:
        if not prefetch:
            while True:
                frame=read_frame()
                if frame is None:return
                yield frame
        else:
            # Bounded PC RAM queue isolates decoder/pipe stalls from line-credit
            # deadlines. Warm it before arming the first FPGA session.
            worker=threading.Thread(target=decode_worker,name="video-decode",daemon=True)
            worker.start()
            if not ready.wait(timeout=10):raise TimeoutError("FFmpeg prefetch did not start within 10s")
            while True:
                kind,value=frames.get(timeout=10)
                if kind=="eof":return
                if kind=="error":raise value
                yield value
    finally:
        stop.set()
        if process.poll() is None:process.terminate()
        try:process.wait(timeout=2)
        except subprocess.TimeoutExpired:
            process.kill();process.wait()
        if worker is not None:worker.join(timeout=2)
        process.stdout.close()


def ffmpeg_audio_frames(path:Path,ffmpeg:str,loop:bool=True):
    command=[ffmpeg,'-hide_banner','-loglevel','error']
    if loop:
        command.extend(['-stream_loop','-1'])
    command += ['-i',str(path),'-map','0:a:0','-vn',
                '-af','aresample=24000:async=1:first_pts=0','-ac','1','-ar','24000','-f','u8','pipe:1']
    process=subprocess.Popen(command,stdout=subprocess.PIPE)
    try:
        while True:
            block=read_exact(process.stdout,AUDIO_SAMPLES)
            if block is None or len(block)!=AUDIO_SAMPLES:
                if loop or process.wait() != 0:
                    raise RuntimeError('PCM decoder ended; check that the input has an audio track or disable audio')
                # An audio track may end before video. Fill its final partial
                # block and remaining frames with unsigned PCM silence.
                yield (block or b'').ljust(AUDIO_SAMPLES, b'\x80')
                while True:
                    yield bytes([0x80])*AUDIO_SAMPLES
            yield block
    finally:
        if process.poll() is None:process.terminate()
        try:process.wait(timeout=2)
        except subprocess.TimeoutExpired:process.kill();process.wait()
        if process.stdout:process.stdout.close()


class StatusFile:
    """Small, throttled progress mailbox for the web process; no video data."""
    def __init__(self, path: Optional[Path], interval: float = 0.25):
        self.path = path
        self.interval = interval
        self.data = {"state": "starting", "frames": 0, "rows": 0, "credits": 0}
        self.last_write = 0.0

    def update(self, *, force=False, **values):
        self.data.update(values)
        now = time.monotonic()
        if self.path is None or (not force and (self.interval <= 0 or now - self.last_write < self.interval)):
            return
        self.data["updated_at"] = time.time()
        temporary = self.path.with_suffix(self.path.suffix + ".tmp")
        temporary.write_text(json.dumps(self.data), encoding="utf-8")
        try:
            os.replace(temporary, self.path)
        except PermissionError:
            # A Windows status reader may briefly hold the previous file open.
            # Retry on the next progress update; this must not stop the stream.
            return
        self.last_write = now


def parse_args():
    demo_root = Path(__file__).resolve().parents[1]
    profile=json.loads(Path(__file__).with_name("direct_video_profile.json").read_text())
    parser = argparse.ArgumentParser(description=__doc__)
    source = parser.add_mutually_exclusive_group()
    source.add_argument("--pattern", action="store_true", help="send a moving color-bar test pattern")
    source.add_argument("--input", type=Path,
                        help="video file decoded by the installed ffmpeg; supply an explicit path")
    parser.add_argument("--board-ip", default="192.168.137.2")
    parser.add_argument("--bind-ip", default="192.168.137.1",
                        help="PC NIC IPv4 address; bind to the dedicated FPGA NIC")
    parser.add_argument("--ffmpeg", default="ffmpeg", help="ffmpeg executable or full path")
    parser.add_argument("--prefetch", type=int, choices=range(17), default=0, help="bounded decoded PC frames; 0 disables for A/B")
    parser.add_argument("--frames", type=int, default=120,
                        help="number of frames to send; use 0 for unlimited")
    parser.add_argument("--once", action="store_true", help="stop at end of input rather than loop it")
    parser.add_argument("--session-id", type=lambda s: int(s, 0), default=None,
                        help="playback session seed; defaults to a random value")
    parser.add_argument("--quiet", action="store_true")
    parser.add_argument("--status-file", type=Path, help="JSON progress mailbox for the web backend")
    parser.add_argument("--status-interval",type=float,default=0.25,help="live status interval; 0 writes only initial/final state")
    parser.add_argument("--send-buffer",type=int,default=0,help="optional per-socket SO_SNDBUF bytes; 0 keeps OS default")
    parser.add_argument("--feedback-timeout", type=float, default=3.0)
    parser.add_argument("--startup-timeout", type=float, default=10.0)
    parser.add_argument("--trace-timing",action="store_true",help="enable QPC feedback diagnostic counters")
    parser.add_argument("--data-port", type=int, default=DATA_PORT)
    parser.add_argument("--feedback-port", type=int, default=FEEDBACK_PORT)
    parser.add_argument("--width", type=int, default=profile["width"], help="must match the synthesized display profile")
    parser.add_argument("--height", type=int, default=profile["height"], help="must match the synthesized display profile")
    parser.add_argument("--audio",action="store_true",help="stream 24kHz mono audio with the video frame timeline")
    parser.add_argument("--require-ready",action="store_true",help="wait for receiver memory ownership before sending row one")
    parser.add_argument("--window",type=int,default=profile["window"],
                        help="row queue depth; must match the synthesized display profile")
    parser.add_argument("--self-test", action="store_true")
    return parser.parse_args()


def main():
    args = parse_args()
    if not (2 <= args.width <= WIDTH and args.width % 2 == 0 and 1 <= args.height <= HEIGHT):
        raise ValueError("width must be even and within 2..720; height must be within 1..360")
    if args.self_test:
        pixels = bytes([0x34, 0x12]) * args.width
        sample_y=min(9,args.height-1)
        seq, packet = make_row_packet(7, sample_y, pixels,width=args.width,height=args.height)
        assert len(packet) == 14+2*args.width
        assert seq == 7 * args.height + sample_y
        assert ROW_HEADER.unpack_from(packet)[0] == ROW_MAGIC
        _, _, flags, _, row, _, _ = ROW_HEADER.unpack_from(packet)
        assert flags == 0 and row == sample_y
        expected_crc = binascii.crc_hqx(packet[:-2], 0xFFFF)
        assert struct.unpack_from("<H", packet, len(packet)-2)[0] == expected_crc
        _, start_packet = make_row_packet(7, 0, pixels, SESSION_START,width=args.width,height=args.height)
        assert ROW_HEADER.unpack_from(start_packet)[2] == SESSION_START
        assert struct.unpack_from("<H", start_packet, len(start_packet)-2)[0] == binascii.crc_hqx(start_packet[:-2], 0xFFFF)
        print(f"PASS sender packet: {len(packet)} bytes, {args.width} RGB565 pixels, CRC16-CCITT-FALSE")
        return 0

    if not 2 <= args.window <= 4096:
        raise ValueError("--window must match the FPGA depth, within 2..4096")
    if not args.pattern and args.input is None:
        raise ValueError("supply --input VIDEO_PATH or --pattern")
    if args.frames < 0:
        raise ValueError("--frames must be 0 or positive")
    if args.feedback_timeout <= 0:
        raise ValueError("--feedback-timeout must be positive")
    def request_stop(_signum, _frame):
        raise KeyboardInterrupt
    signal.signal(signal.SIGTERM, request_stop)
    if hasattr(signal, "SIGBREAK"):
        signal.signal(signal.SIGBREAK, request_stop)
    session_id = secrets.randbelow(1 << 16) if args.session_id is None else args.session_id & 0xFFFF
    initial_sequence = (session_id * args.height) & 0xFFFF
    status = StatusFile(args.status_file,args.status_interval)
    status.update(width=args.width, height=args.height, force=True)
    sender = None
    source = None
    audio_source = None
    exit_code = 0
    frame_no = 0
    first_frame = True
    try:
        sender = Sender(args.bind_ip, args.board_ip, initial_sequence, args.quiet,
                        data_port=args.data_port, feedback_port=args.feedback_port,
                        feedback_timeout=args.feedback_timeout, startup_timeout=args.startup_timeout, trace_timing=args.trace_timing, status_callback=status.update,
                        width=args.width,height=args.height,window=args.window,send_buffer=args.send_buffer,require_ready=args.require_ready)
        if args.pattern:
            base = make_pattern_base(args.width,args.height)
            while args.frames == 0 or frame_no < args.frames:
                frame_id = (session_id + frame_no) & 0xFFFF
                sender.send_frame(frame_id, make_pattern_frame(base, frame_no,args.width,args.height), first_frame)
                sender.print_summary(frame_no)
                first_frame = False
                frame_no += 1
                status.update(frames=frame_no)
                sender.process_feedback()
        else:
            ffmpeg = shutil.which(args.ffmpeg) if not Path(args.ffmpeg).is_file() else args.ffmpeg
            if not ffmpeg:
                raise FileNotFoundError(f"ffmpeg not found: {args.ffmpeg}")
            source = ffmpeg_frames(args.input, ffmpeg,args.width,args.height,prefetch=args.prefetch,fps="2000/33" if args.audio else "60",loop=not args.once)
            if args.audio:audio_source=ffmpeg_audio_frames(args.input,ffmpeg,loop=not args.once)
            for frame in source:
                if args.frames and frame_no >= args.frames:
                    break
                frame_id = (session_id + frame_no) & 0xFFFF
                sender.send_frame(frame_id, frame, first_frame,next(audio_source) if audio_source is not None else None)
                sender.print_summary(frame_no)
                first_frame = False
                frame_no += 1
                status.update(frames=frame_no)
    except KeyboardInterrupt:
        pass
    except Exception as exc:
        exit_code = 1
        status.update(state="error", error=str(exc), force=True)
        print(f"direct_video_sender: {exc}", file=sys.stderr, flush=True)
    finally:
        if audio_source is not None:audio_source.close()
        if source is not None:
            source.close()
        if sender is not None:
            sender.report("error" if exit_code else "stopped")
            sender.close()
        status.update(state="error" if exit_code else "stopped", frames=frame_no, force=True)
    if sender is not None:
        print(f"stopped after {frame_no} frames; rows={sender.sent_rows}, retries={sender.retries}, "
              f"expired_rows={sender.skipped_rows}, uncached_nacks={sender.missing_cache}", flush=True)
    return exit_code


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as exc:
        print(f"direct_video_sender: {exc}", file=sys.stderr)
        raise
