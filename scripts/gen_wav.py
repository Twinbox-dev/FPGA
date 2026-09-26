#!/usr/bin/env python3
"""生成确定性测试 WAV（纯标准库）。

用法: python3 scripts/gen_wav.py [-o 输出目录]
生成:
  TONE1.WAV    48kHz/16bit/立体声 1 秒（L=1kHz 正弦, R=440Hz 正弦）标准 44 字节头
  TONELIST.WAV 同格式 0.5 秒，但 fmt 与 data 之间插入 LIST/INFO 块
               —— 专测 chunk 链遍历（不能按固定偏移找 data）
  BADRATE.WAV  22050Hz，用于格式拒绝测试
所有波形确定性可再生，是 wav_reader golden 比对的样本基准。
"""
import math
import os
import struct
import sys


def write_wav(path, rate, channels, nframes, sample_fn, extra_list=False):
    """sample_fn(frame_idx, ch) -> int16"""
    data = bytearray()
    for i in range(nframes):
        for c in range(channels):
            data += struct.pack('<h', sample_fn(i, c))

    bits = 16
    fmt_body = struct.pack('<HHIIHH',
                           1,                                  # PCM
                           channels,
                           rate,
                           rate * channels * bits // 8,        # byteRate
                           channels * bits // 8,               # blockAlign
                           bits)
    chunks = b'fmt ' + struct.pack('<I', len(fmt_body)) + fmt_body

    if extra_list:
        # LIST/INFO 块：解析器必须靠 ckSize 跳过它才能找到 data
        info = b'INFO' + b'INAM' + struct.pack('<I', 8) + b'SIMTEST\x00'
        chunks += b'LIST' + struct.pack('<I', len(info)) + info

    chunks += b'data' + struct.pack('<I', len(data)) + bytes(data)
    riff = b'WAVE' + chunks
    with open(path, 'wb') as f:
        f.write(b'RIFF' + struct.pack('<I', len(riff)) + riff)
    return 8 + len(riff)


def main():
    out = sys.argv[sys.argv.index('-o') + 1] if '-o' in sys.argv else 'img/wav'
    os.makedirs(out, exist_ok=True)

    RATE = 48000

    def tone(i, c):
        # 左 1kHz（半幅），右 440Hz（四分之一幅）
        if c == 0:
            return int(16383 * math.sin(2 * math.pi * 1000 * i / RATE))
        return int(8191 * math.sin(2 * math.pi * 440 * i / RATE))

    n = write_wav(os.path.join(out, 'IMG001.WAV'), RATE, 2, RATE, tone)
    print(f'generated {out}/IMG001.WAV ({n} B, 1s, 配 IMG001.BMP)')

    n = write_wav(os.path.join(out, 'IMG002.WAV'), RATE, 2, RATE // 2, tone,
                  extra_list=True)
    print(f'generated {out}/IMG002.WAV ({n} B, 0.5s, 含 LIST 块, 配 IMG002.BMP)')

    n = write_wav(os.path.join(out, 'ZBADRATE.WAV'), 22050, 2, 2205, tone)
    print(f'generated {out}/BADRATE.WAV ({n} B, 22050Hz 拒绝测试)')


if __name__ == '__main__':
    main()
