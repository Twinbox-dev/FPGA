#!/usr/bin/env python3
"""生成确定性测试 WAV（纯标准库）。板级音频规格：24kHz / 8bit / 单声道（无符号样本）。

用法: python3 scripts/gen_wav.py [-o 输出目录]
生成:
  IMG001.WAV    24kHz/8bit/mono 1 秒（1kHz 正弦，半幅，u8=128 直流偏置）标准 44 字节头
  IMG002.WAV    24kHz/8bit/mono 0.5 秒（440Hz），fmt 与 data 之间插入 LIST/INFO 块
               —— 专测 chunk 链遍历（不能按固定偏移找 data）
  ZBADRATE.WAV  22050Hz/8bit/mono，采样率拒绝测试
  ZBADBITS.WAV  24kHz/16bit/mono，位深拒绝测试
  ZBADCH.WAV    24kHz/8bit/立体声，声道拒绝测试
所有波形确定性可再生，是 boardtest wav_reader golden 比对的样本基准。
"""
import math
import os
import struct
import sys

RATE = 24000  # 板级统一采样率（HDMI 核 48k，板载 ×2 上采样）


def write_wav(path, rate, channels, bits, nframes, sample_fn, extra_list=False):
    """sample_fn(frame_idx, ch) -> int，8bit 时取低 8 位按无符号存储（0..255）。"""
    data = bytearray()
    for i in range(nframes):
        for c in range(channels):
            v = sample_fn(i, c)
            if bits == 8:
                data += struct.pack('<B', max(0, min(255, v)))
            else:
                data += struct.pack('<h', max(-32768, min(32767, v)))

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

    def tone(rate, freq, amp=0.5):
        # u8 无符号：128 为直流零点，正弦峰峰值 amp*255
        return lambda i, c: int(round(128 + 127 * amp
                                      * math.sin(2 * math.pi * freq * i / rate)))

    n = write_wav(os.path.join(out, 'IMG001.WAV'), RATE, 1, 8, RATE,
                  tone(RATE, 1000))
    print(f'generated {out}/IMG001.WAV ({n} B, 1s 24k/8b/mono, 配 IMG001.BMP)')

    n = write_wav(os.path.join(out, 'IMG002.WAV'), RATE, 1, 8, RATE // 2,
                  tone(RATE, 440), extra_list=True)
    print(f'generated {out}/IMG002.WAV ({n} B, 0.5s 含 LIST 块, 配 IMG002.BMP)')

    n = write_wav(os.path.join(out, 'ZBADRATE.WAV'), 22050, 1, 8, 2205,
                  tone(22050, 1000))
    print(f'generated {out}/ZBADRATE.WAV ({n} B, 22050Hz 拒绝测试)')

    n = write_wav(os.path.join(out, 'ZBADBITS.WAV'), RATE, 1, 16, RATE // 4,
                  tone(RATE, 1000))
    print(f'generated {out}/ZBADBITS.WAV ({n} B, 16bit 拒绝测试)')

    n = write_wav(os.path.join(out, 'ZBADCH.WAV'), RATE, 2, 8, RATE // 4,
                  tone(RATE, 1000))
    print(f'generated {out}/ZBADCH.WAV ({n} B, 立体声拒绝测试)')


if __name__ == '__main__':
    main()
