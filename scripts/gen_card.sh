#!/usr/bin/env bash
# 生成 4 种 FAT32 测试卡镜像（供 csrc/sd_card_model 加载，均 62MB / 8KB 簇）：
#   img/card.img        superfloppy，主卡（mkfs.vfat 整盘直格，无分区表）
#   img/card_mbr.img    MBR 卡（分区起始 LBA 2048，Windows 典型对齐布局）
#   img/card_frag.img   碎片卡（S01/S02/S03 → 删 S01/S03 → 拷入 IMG004，
#                       IMG004 的簇链必然绕过 S02 占用的洞 → 非连续簇链）
#   img/card_empty.img  空卡（只格式化，无文件）
# 依赖: dosfstools(mkfs.vfat) + mtools(mcopy/mdel/mdir)。在仓库根目录运行。
set -euo pipefail

command -v mkfs.vfat >/dev/null || { echo "缺 mkfs.vfat: sudo apt install dosfstools"; exit 1; }
command -v mcopy    >/dev/null || { echo "缺 mcopy: sudo apt install mtools"; exit 1; }

# 测试素材始终重新生成（幂等，确定性）
python3 scripts/gen_bmp.py
python3 scripts/gen_wav.py

mkfs_img() {   # $1=输出, 其余=要拷入的文件
    local out=$1
    shift
    dd if=/dev/zero of="$out" bs=1M count=62 status=none
    mkfs.vfat -F 32 -s 16 -n CONTEST "$out"
    if [ $# -gt 0 ]; then
        mcopy -i "$out" "$@" ::
    fi
}

# ---- 1. 主卡（superfloppy）：图片在前，音频在后（目录序=创建序）----
mkfs_img img/card.img img/bmp/*.BMP img/wav/*.WAV

# ---- 2. MBR 卡 ----
mkfs_img img/fs.tmp img/bmp/*.BMP img/wav/*.WAV
python3 - <<'EOF'
import os, struct
fs_sectors = os.path.getsize('img/fs.tmp') // 512
mbr = bytearray(512)                        # 446B 引导区全零（数据卡无需引导代码）
struct.pack_into('<B', mbr, 0x1BE + 0, 0x00)          # 引导标志
struct.pack_into('<B', mbr, 0x1BE + 4, 0x0C)          # 类型: FAT32 LBA
struct.pack_into('<I', mbr, 0x1BE + 8, 2048)          # 起始 LBA（1MB 对齐）
struct.pack_into('<I', mbr, 0x1BE + 12, fs_sectors)   # 分区大小
mbr[0x1FE], mbr[0x1FF] = 0x55, 0xAA                   # 签名
open('img/mbr.bin', 'wb').write(mbr)
EOF
cat img/mbr.bin > img/card_mbr.img
dd if=/dev/zero bs=512 count=2047 >> img/card_mbr.img 2>/dev/null
cat img/fs.tmp >> img/card_mbr.img

# ---- 3. 碎片卡：填满盘 → 删中间洞 → 拷 IMG004，迫使簇链跨洞 ----
# 布局: junk_a(大) | junk_s(100簇,删) | junk_b(50簇) | 尾部空闲(~60簇)
# IMG004 需 113 簇，洞(100)和尾(~60)都装不下 → 簇链必然两段，与分配策略无关
mkfs_img img/card_frag.img
python3 - <<'EOF'
import struct
img = open('img/card_frag.img', 'rb').read()
def le16(o): return struct.unpack_from('<H', img, o)[0]
def le32(o): return struct.unpack_from('<I', img, o)[0]
spc, rsvd, nfats, fatsz, totsec = img[13], le16(14), img[16], le32(36), le32(32)
data_clusters = (totsec - rsvd - nfats * fatsz) // spc - 1   # 减根目录簇
CL = spc * 512
hole, tail, jb = 100, 60, 50
a = data_clusters - hole - tail - jb - 2
def w(path, clusters):
    with open(path, 'wb') as f:
        f.seek(clusters * CL - 512)
        f.write(b'\0' * 512)      # 稀疏文件：seek 到末尾写一页
w('img/junk_a.bin', a)
w('img/junk_s.bin', hole)
w('img/junk_b.bin', jb)
print(f"碎片卡: junk_a={a}簇 junk_s={hole}簇(将删) junk_b={jb}簇 尾空闲≈{tail}簇, IMG004=113簇")
EOF
mcopy -i img/card_frag.img img/junk_a.bin img/junk_s.bin img/junk_b.bin ::
mdel -i img/card_frag.img ::junk_s.bin
mcopy -i img/card_frag.img img/bmp/IMG004.BMP ::
rm -f img/junk_a.bin img/junk_s.bin img/junk_b.bin

# ---- 4. 空卡 ----
mkfs_img img/card_empty.img

rm -f img/fs.tmp img/mbr.bin

for c in img/card.img img/card_mbr.img img/card_frag.img img/card_empty.img; do
    echo "== $c =="
    mdir -i "$c" :: | tail -n +4
done
