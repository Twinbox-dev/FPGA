#!/usr/bin/env bash
# 生成诊断卡 img/card_diag.img（供 boardtest 回归；62MB / 8KB 簇 / superfloppy）
# 与桌面 diag_audio/（上板用，5 秒）同构但 WAV 仅 0.5 秒——仿真按真实时间
# 播放一整圈做逐字节比对，音频时长直接决定仿真时长（5s→0.5s ≈ 10×）。
# 内容判别力不变：0x80 静音 / 1kHz 正弦 / 500Hz 正弦 / 无配对 / 0xFF 直流，
# 上板听效时仍用桌面 5 秒版。
# 依赖: dosfstools + mtools + python3。在仓库根目录运行。
set -euo pipefail
command -v mkfs.vfat >/dev/null || { echo "缺 mkfs.vfat"; exit 1; }
command -v mcopy    >/dev/null || { echo "缺 mcopy"; exit 1; }

DIAG_SRC="${1:-/mnt/c/Users/23506/Desktop/diag_audio}"   # 上板用 5s 版（取 BMP）
OUT=img/card_diag.img
SEC=24000          # 0.5s @24kHz
RATE=24000

# ---- 短 WAV（0.5s，判别式内容与桌面版一致）----
python3 - "$DIAG_SRC" "$SEC" "$RATE" <<'EOF'
import math, os, struct, sys
src, sec, rate = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
os.makedirs('img/diag_sim', exist_ok=True)
def wav(name, gen):
    data = bytes(gen(i) for i in range(sec))
    fmt = struct.pack('<HHIIHH', 1, 1, rate, rate, 1, 8)
    riff = b'WAVE' + b'fmt ' + struct.pack('<I', 16) + fmt \
         + b'data' + struct.pack('<I', len(data)) + data
    open(f'img/diag_sim/{name}', 'wb').write(b'RIFF' + struct.pack('<I', len(riff)) + riff)
wav('TST0.WAV', lambda i: 0x80)                                   # 静音
wav('TST1.WAV', lambda i: int(round(128 + 100 * math.sin(2*math.pi*1000*i/rate))))
wav('TST2.WAV', lambda i: int(round(128 + 100 * math.sin(2*math.pi*500*i/rate))))
wav('TST4.WAV', lambda i: 0xFF)                                   # 直流
print('generated 0.5s TST0/1/2/4.WAV')
EOF

# ---- 组卡：BMP 用上板同款，WAV 用短版；目录序 = TST0..4.BMP 后 TST0,1,2,4.WAV ----
dd if=/dev/zero of="$OUT" bs=1M count=62 status=none
mkfs.vfat -F 32 -s 16 -n DIAG "$OUT"
mcopy -i "$OUT" "$DIAG_SRC"/TST0.BMP "$DIAG_SRC"/TST1.BMP "$DIAG_SRC"/TST2.BMP \
      "$DIAG_SRC"/TST3.BMP "$DIAG_SRC"/TST4.BMP \
      img/diag_sim/TST0.WAV img/diag_sim/TST1.WAV img/diag_sim/TST2.WAV \
      img/diag_sim/TST4.WAV ::
mdir -i "$OUT" :: | tail -n +4
