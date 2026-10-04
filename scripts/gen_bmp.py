#!/usr/bin/env python3
"""生成确定性测试 BMP（纯标准库，无 PIL 依赖）。

用法: python3 scripts/gen_bmp.py [-o 输出目录]
生成 4 张 1280x720 24bit 测试图（渐变/条纹/棋盘/对角）+ 1 张 1281x721 非法尺寸图
（后者专测 BMP 解析器的行填充与尺寸拒绝路径）。
所有图确定性再生，是 golden difftest 的像素基准来源。
"""
import os
import struct
import sys


def write_bmp(path, w, h, pix):
    """pix(x, y) -> (r, g, b)。BMP 自底向上存储，行尾 4 字节对齐填充。"""
    pad = (4 - (w * 3) % 4) % 4
    row_size = w * 3 + pad
    data_size = row_size * h
    # BITMAPFILEHEADER (14B) + BITMAPINFOHEADER (40B)
    header = struct.pack('<2sIHHI', b'BM', 54 + data_size, 0, 0, 54)
    info = struct.pack('<IiiHHIIiiII', 40, w, h, 1, 24, 0, data_size,
                       2835, 2835, 0, 0)
    with open(path, 'wb') as f:
        f.write(header)
        f.write(info)
        for y in range(h - 1, -1, -1):        # 自底向上
            row = bytearray()
            for x in range(w):
                r, g, b = pix(x, y)
                row += bytes((b, g, r))       # BGR 字节序
            row += b'\x00' * pad
            f.write(row)


def main():
    out = sys.argv[sys.argv.index('-o') + 1] if '-o' in sys.argv else 'img/bmp'
    os.makedirs(out, exist_ok=True)
    W, H = 1280, 720
    pats = {
        'IMG001.BMP':  lambda x, y: (x * 255 // W, 0, 0),
        'IMG002.BMP': lambda x, y: (0, 255 if (x // 80) % 2 else 64, 0),
        'IMG003.BMP': lambda x, y: (0, 0, 255 if (x // 8 + y // 8) % 2 else 32),
        'IMG004.BMP':  lambda x, y: ((x + y) * 255 // (W + H),
                                           255 - (x + y) * 255 // (W + H), 128),
    }
    for name, fn in pats.items():
        write_bmp(os.path.join(out, name), W, H, fn)
        print('generated', os.path.join(out, name))
    # ---- 多分辨率信箱适配测试（2026-10-03）----
    # IMG005: 640x480（赛题原生格式，居中黑边）；IMG006: 333x217（奇数宽，
    # 行填充字节 + 奇数 x0 边界）；ZODD: 500x300 奇形；ZBADSIZE: 1281x721 超界拒绝
    write_bmp(os.path.join(out, 'IMG005.BMP'), 640, 480,
              lambda x, y: (255 - y * 255 // 480, x * 255 // 640, 64))
    print('generated', os.path.join(out, 'IMG005.BMP'), '(640x480 信箱)')
    write_bmp(os.path.join(out, 'IMG006.BMP'), 333, 217,
              lambda x, y: ((x * 7 + y * 13) % 256, (x + y) % 256, 200))
    print('generated', os.path.join(out, 'IMG006.BMP'), '(333x217 奇宽+行填充)')
    write_bmp(os.path.join(out, 'XODD.BMP'), 500, 300,
              lambda x, y: (128, (x * 255 // 500), (y * 255 // 300)))
    print('generated', os.path.join(out, 'XODD.BMP'), '(500x300 信箱)')
    write_bmp(os.path.join(out, 'ZBADSIZE.BMP'), 1281, 721,
              lambda x, y: (255, 255, 0))
    print('generated', os.path.join(out, 'ZBADSIZE.BMP'), '(1281x721, 拒绝测试)')


if __name__ == '__main__':
    main()
