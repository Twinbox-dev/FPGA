#!/usr/bin/env python3
"""FAT32 镜像内 WAV 原地截断（缩短仿真时长用，只动指定文件）。

保留目录结构、簇布局、删除项、其余文件不动。步骤：
  1. 找 8.3 目录项 → 首簇 + 原长
  2. 重写文件头 RIFF/data 块大小（按自身 fmt 算 目标秒 的帧数）
  3. 目录项 size 改小
  4. FAT 链截断（需要簇数 = ceil(新长/簇字节)），多余链项清零，两个 FAT 同步
     （数据区不擦——真卡也这样，簇不可达即"删除"）

用法: truncate_wav_in_img.py <镜像> <8.3名,如 0.WAV> <目标秒>
"""
import struct, sys

img_path, name83, secs = sys.argv[1], sys.argv[2].upper(), float(sys.argv[3])
img = bytearray(open(img_path, 'rb').read())

def le16(o): return struct.unpack_from('<H', img, o)[0]
def le32(o): return struct.unpack_from('<I', img, o)[0]
def w32(o, v): struct.pack_into('<I', img, o, v)

# ---- 分区偏移（MBR 或 superfloppy）----
part = 0
if img[0x1FE] == 0x55 and img[0x1FF] == 0xAA and le32(0x1BE + 8) != 0:
    part = le32(0x1BE + 8) * 512
    print(f"MBR 分区 @ LBA{le32(0x1BE+8)}")

bpb = part
if img[bpb+0x52:bpb+0x57] != b'FAT32':
    raise SystemExit(f"非 FAT32 签名 @+0x52={img[bpb+0x52:bpb+0x57]!r}")
spc      = img[bpb+13]
rsvd     = le16(bpb+14)
nfats    = img[bpb+16]
fatsz    = le32(bpb+36)
root_clu = le32(bpb+44)
CL       = spc * 512
fat0     = part + rsvd * 512
data0    = part + (rsvd + nfats * fatsz) * 512
print(f"spc={spc} rsvd={rsvd} nfats={nfats} fatsz={fatsz} CL={CL} root_clu={root_clu}")

def clu_off(c): return data0 + (c - 2) * CL
def fat_ent(c): return le32(fat0 + c * 4) & 0x0FFFFFFF
def set_fat(c, v):
    for k in range(nfats):
        o = fat0 + k * fatsz * 512 + c * 4
        w32(o, (le32(o) & 0xF0000000) | (v & 0x0FFFFFFF))

EOC = 0x0FFFFFF8

def chain(c):
    out = []
    while 2 <= c < EOC and c not in out:
        out.append(c); c = fat_ent(c)
    return out

# ---- 根目录找 8.3 项 ----
want = name83.split('.')
short = (want[0].ljust(8) + want[1].ljust(3)).encode()
ent_off = None
for c in chain(root_clu):
    base = clu_off(c)
    for i in range(CL // 32):
        e = base + i * 32
        if img[e] == 0x00: break
        if img[e] == 0xE5 or (img[e+11] & 0x0F) == 0x0F: continue
        if bytes(img[e:e+11]) == short and not (img[e+11] & 0x08):
            ent_off = e
            break
    if ent_off is not None: break
if ent_off is None:
    raise SystemExit(f"找不到 {name83}")
attr = img[ent_off+11]
if attr & 0x10: raise SystemExit("目标是目录")
first = (le16(ent_off+20) << 16) | le16(ent_off+26)
old_sz = le32(ent_off+28)
print(f"{name83}: 首簇={first} 原长={old_sz}")

# ---- 文件头 fmt / data 块 ----
fo = clu_off(first)
if img[fo:fo+4] != b'RIFF':
    raise SystemExit("文件头非 RIFF")
o = fo + 12
data_off = None
channels = rate = bits = None
while o + 8 <= fo + 256:
    cid = bytes(img[o:o+4]); csz = le32(o+4)
    if cid == b'fmt ':
        channels = le16(o+10); rate = le32(o+12); bits = le16(o+22)
    elif cid == b'data':
        data_off = o + 8; data_sz_off = o + 4
        break
    o += 8 + csz + (csz & 1)
if data_off is None or not channels:
    raise SystemExit("fmt/data 块解析失败")
frames = int(rate * secs)
new_data = frames * channels * bits // 8
new_sz = (data_off - fo) + new_data
need = (new_sz + CL - 1) // CL
w32(fo + 4, new_sz - 8)            # RIFF size
w32(data_sz_off, new_data)         # data chunk size
w32(ent_off + 28, new_sz)          # 目录项 size
print(f"fmt: {rate}Hz {bits}bit {channels}ch → {frames} 帧, 新长={new_sz}, 需簇={need}")

# ---- FAT 链截断 ----
ch = chain(first)
print(f"原链 {len(ch)} 簇")
if len(ch) > need:
    set_fat(ch[need-1], 0x0FFFFFFF)
    for c in ch[need:]:
        set_fat(c, 0)
    print(f"截断：保留 {need} 簇，清 {len(ch)-need} 簇链项")
else:
    print("链已不长于目标，无需截断")

open(img_path, 'wb').write(img)
print("写回完成")
