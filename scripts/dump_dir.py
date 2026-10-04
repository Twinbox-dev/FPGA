#!/usr/bin/env python3
"""诊断：解析截取的 FAT32 镜像（MBR 卡，前段截取）——目录布局 + 走 FAT 链验覆盖。
用法: python3 dump_dir.py img/card_user_real.img [截取字节上限]
目录项列出后，对每个文件沿 FAT 簇链走全程，报告最大簇号是否落在截取范围内。"""
import struct, sys

img = open(sys.argv[1], 'rb').read()
cap = int(sys.argv[2]) if len(sys.argv) > 2 else len(img)

# MBR → 分区1 起始 LBA
p1 = img[446:446 + 16]
lba_start = struct.unpack_from('<I', p1, 8)[0]
ptype = p1[4]
print(f"分区1: type={ptype:#04x} lba_start={lba_start}")
pb = img[lba_start * 512:]
bps = struct.unpack_from('<H', pb, 11)[0]
spc = pb[13]
rsvd = struct.unpack_from('<H', pb, 14)[0]
nfats = pb[16]
fatsz = struct.unpack_from('<I', pb, 36)[0]
rootclus = struct.unpack_from('<I', pb, 44)[0]
print(f"bps={bps} spc={spc} rsvd={rsvd} nfats={nfats} fatsz={fatsz} rootclus={rootclus}")
data_sec_abs = lba_start + rsvd + nfats * fatsz
print(f"数据区绝对扇区={data_sec_abs} ({data_sec_abs * 512 / 1048576:.1f} MiB)，"
      f"簇={spc * bps}B，截取内簇数≈{(cap - data_sec_abs * 512) // (spc * bps)}")

fat_off = (lba_start + rsvd) * 512

def fat_entry(c):
    return struct.unpack_from('<I', img, fat_off + c * 4)[0] & 0x0FFFFFFF

def clus_bytes(c, n):
    off = (data_sec_abs + (c - 2) * spc) * 512
    return img[off:off + n]

# 根目录链（根目录也是簇链）
def walk_chain(c0, is_dir=False):
    chain, c = [], c0
    while 2 <= c < 0x0FFFFFF8:
        chain.append(c)
        c = fat_entry(c)
        if len(chain) > 100000:
            break
    return chain

root_chain = walk_chain(rootclus)
print(f"根目录链: {len(root_chain)} 簇 {root_chain[:4]}{'...' if len(root_chain) > 4 else ''}")

entries = []
for c in root_chain:
    off = (data_sec_abs + (c - 2) * spc) * 512
    for i in range(0, spc * bps, 32):
        e = img[off + i:off + i + 32]
        if len(e) < 32 or e[0] == 0:
            break
        if e[11] == 0x0F:
            continue
        clus = (struct.unpack_from('<H', e, 20)[0] << 16) | struct.unpack_from('<H', e, 26)[0]
        size = struct.unpack_from('<I', e, 28)[0]
        name = e[0:11].decode('ascii', 'replace')
        attr = e[11]
        kind = 'DIR' if attr & 0x10 else 'FILE'
        entries.append((name, attr, clus, size))
        print(f"  {name} attr={attr:#04x} {kind} clus={clus} size={size}")

maxc = 0
ok = True
for name, attr, clus, size in entries:
    if attr & 0x10 or size == 0:
        continue
    ch = walk_chain(clus)
    need = ((size + spc * bps - 1) // (spc * bps))
    m = max(ch) if ch else 0
    maxc = max(maxc, m)
    inb = all((data_sec_abs + (x - 2) * spc) * 512 + spc * 512 <= cap for x in ch)
    consistent = len(ch) >= need
    if not inb or not consistent:
        ok = False
    print(f"  {name}: 链{len(ch)}簇(需{need}) 最大簇={m} 全在截取内={inb}")
print(f"最大簇={maxc}，覆盖校验={'OK' if ok else 'FAIL'}")
