"""Helpers for turning browser-decoded images into the display wire format."""
from __future__ import annotations

import io
import os
import shutil
import struct
import subprocess
import tempfile
import wave
from pathlib import Path

MAGIC = b"\xaa\xbb\xcc\xdd"
MAX_WIDTH = 1280
MAX_HEIGHT = 720
MAX_AUDIO_SAMPLES = 2_351_104
PC_AUDIO_MAX_SECONDS = 60
PC_AUDIO_MAX_SAMPLES = 24_000 * PC_AUDIO_MAX_SECONDS
MAX_AUDIO_UPLOAD_BYTES = 512 * 1024 * 1024
IMAGE_PACKET_WORDS = 253
AUDIO_PACKET_SAMPLES = 1012
WINDOWS_FFMPEG = Path(r"D:\SDK\ffmpeg\ffmpeg.exe")


def image_packet(kind: int, payload: bytes = b"") -> bytes:
    return MAGIC + struct.pack("<HH", kind, len(payload)) + payload


def control_packet(kind: int, payload: bytes = b"") -> bytes:
    return MAGIC + struct.pack(">HH", kind, len(payload)) + payload


def unpack_display_packet(data: bytes):
    """Decode the two documented headers used by display-board responses."""
    if len(data) < 8 or data[:4] != MAGIC:
        return None
    if data[4] == 0 and data[5] in (0x48, 0x4A):
        kind, length = struct.unpack_from(">HH", data, 4)
    elif data[5] == 0 and data[4] in (0x20, 0x24, 0x33):
        kind, length = struct.unpack_from("<HH", data, 4)
    else:
        return None
    payload = data[8:]
    if len(payload) != length:
        return None
    return kind, payload


def rgb24_to_native_words(rgb_top_down: bytes, width: int, height: int) -> tuple[bytes, int]:
    """Pack top-down RGB888 into bottom-up little-endian RGB565 pairs.

    The display link carries one 32-bit word per two pixels; the first pixel
    occupies bits 15:0 and the second occupies bits 31:16. An odd final pixel
    leaves the upper halfword zero.
    """
    if not (1 <= width <= MAX_WIDTH and 1 <= height <= MAX_HEIGHT):
        raise ValueError("image dimensions must be within 1..1280 × 1..720")
    expected = width * height * 3
    if len(rgb_top_down) != expected:
        raise ValueError(f"RGB data length {len(rgb_top_down)} does not match {width}×{height}")

    pixel_count = width * height
    words = bytearray(((pixel_count + 1) // 2) * 4)
    checksum = 0
    for pair in range((pixel_count + 1) // 2):
        packed = 0
        for half in range(2):
            pixel_index = pair * 2 + half
            if pixel_index >= pixel_count:
                break
            bottom_up_y, x = divmod(pixel_index, width)
            source = ((height - 1 - bottom_up_y) * width + x) * 3
            red, green, blue = rgb_top_down[source:source + 3]
            rgb565 = ((red >> 3) << 11) | ((green >> 2) << 5) | (blue >> 3)
            packed |= rgb565 << (half * 16)
        struct.pack_into("<I", words, pair * 4, packed)
        checksum = (checksum + packed) & 0xFFFFFFFF
    return bytes(words), checksum


def load_pcm_wav(data: bytes, max_samples: int | None = None) -> bytes:
    """Validate the existing 24 kHz, unsigned 8-bit mono PCM wire format."""
    try:
        with wave.open(io.BytesIO(data), "rb") as src:
            params = src.getparams()
            if (params.nchannels, params.sampwidth, params.framerate, params.comptype) != (
                    1, 1, 24000, "NONE"):
                raise ValueError("WAV must be uncompressed 24 kHz / 8-bit / mono PCM")
            if max_samples is None and params.nframes > MAX_AUDIO_SAMPLES:
                raise ValueError(f"WAV is too long; maximum is {MAX_AUDIO_SAMPLES} samples")
            frame_count = params.nframes if max_samples is None else min(params.nframes, max_samples)
            pcm = src.readframes(frame_count)
            if len(pcm) != frame_count:
                raise ValueError("WAV ended before its declared sample count")
            return pcm
    except (wave.Error, EOFError) as exc:
        raise ValueError(f"invalid WAV: {exc}") from exc


def resolve_ffmpeg() -> str:
    """Find the user's local FFmpeg without downloading or installing tools."""
    configured = os.environ.get("FFMPEG")
    if configured and Path(configured).is_file():
        return configured
    on_path = shutil.which("ffmpeg")
    if on_path:
        return on_path
    if WINDOWS_FFMPEG.is_file():
        return str(WINDOWS_FFMPEG)
    raise ValueError("找不到 FFmpeg；请将 ffmpeg 加入 PATH 或设置 FFMPEG 环境变量")


def transcode_audio_stream(stream, filename: str = "audio.mp4") -> bytes:
    """Extract at most 60 seconds and convert it to the FPGA's PCM WAV format."""
    ffmpeg = resolve_ffmpeg()
    suffix = Path(filename or "audio.mp4").suffix.lower()
    if not suffix or len(suffix) > 12 or not suffix[1:].isalnum():
        suffix = ".bin"

    with tempfile.TemporaryDirectory(prefix="fpga-audio-") as temp_dir:
        input_path = Path(temp_dir) / f"input{suffix}"
        output_path = Path(temp_dir) / "audio.wav"
        total = 0
        with input_path.open("wb") as target:
            while True:
                chunk = stream.read(1024 * 1024)
                if not chunk:
                    break
                total += len(chunk)
                if total > MAX_AUDIO_UPLOAD_BYTES:
                    raise ValueError("音频/MP4 文件超过 512 MB")
                target.write(chunk)
        if total == 0:
            raise ValueError("音频文件为空")

        command = [
            ffmpeg, "-hide_banner", "-loglevel", "error", "-y",
            "-i", str(input_path), "-map", "0:a:0", "-vn", "-t", str(PC_AUDIO_MAX_SECONDS),
            "-ac", "1", "-ar", "24000", "-c:a", "pcm_u8", "-f", "wav", str(output_path),
        ]
        options = {"capture_output": True, "text": True, "timeout": 180, "check": False}
        if os.name == "nt":
            options["creationflags"] = getattr(subprocess, "CREATE_NO_WINDOW", 0)
        try:
            result = subprocess.run(command, **options)
        except (OSError, subprocess.TimeoutExpired) as exc:
            raise ValueError(f"FFmpeg 处理失败：{exc}") from exc
        if result.returncode != 0 or not output_path.is_file():
            detail = (result.stderr or "未找到可解码的音轨").strip()
            raise ValueError(f"FFmpeg 无法提取音频：{detail[-500:]}")
        return load_pcm_wav(output_path.read_bytes(), max_samples=PC_AUDIO_MAX_SAMPLES)

