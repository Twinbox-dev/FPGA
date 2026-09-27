#!/usr/bin/env bash
# scripts/prep_media.sh — 素材准备：任意图片/音频 → 系统规格 → 同名配对
#
# 设计立场（2026-09-23 决定）：**不在 FPGA 里做兼容，在入卡前把格式收窄**。
#   现实素材格式极杂（JPG/PNG/HEIC、MP3/AAC/44.1k/单声道…），硬件侧全兼容
#   等于把解码器和重采样器搬进控制路径——开发地狱且占资源。图片早已走这条
#   路（必须是 640x480x24bit 非压缩 BMP），音频照抄：统一转 24kHz/8bit/单声道
#   （板载 ×2 上采样到 HDMI 核 48k；u8→s16 = (u8−128)<<8）。
#   硬件侧只负责：格式不对时**响亮地拒绝**（fmt_err/头校验），不负责将就。
#
# 用法:
#   ./scripts/prep_media.sh IMG001 照片.jpg 音效.mp3    # 一对图+音，同名配对
#   ./scripts/prep_media.sh IMG002 风景.png             # 只有图片
#   ./scripts/prep_media.sh --list                      # 看当前素材
#   ./scripts/gen_card.sh                               # 打包进卡镜像
#
# 输出: img/bmp/<名字>.BMP + img/wav/<名字>.WAV
#   同名 = 配对关系（切到该图时播放同名音频，见 design.md §7）
#   名字须为全大写 8.3 主名（≤8 字符），避免 LFN 干扰
set -euo pipefail

command -v ffmpeg >/dev/null || { echo "缺 ffmpeg: sudo apt install ffmpeg"; exit 1; }

if [ "${1:-}" = "--list" ]; then
    echo "== 图片 (img/bmp) =="
    ls -la img/bmp/*.BMP 2>/dev/null | awk '{printf "  %-24s %8s B\n", $9, $5}' || echo "  （空）"
    echo "== 音频 (img/wav) =="
    ls -la img/wav/*.WAV 2>/dev/null | awk '{printf "  %-24s %8s B\n", $9, $5}' || echo "  （空）"
    echo "== 配对情况 =="
    for b in img/bmp/*.BMP; do
        [ -e "$b" ] || continue
        n=$(basename "$b" .BMP)
        if [ -f "img/wav/$n.WAV" ]; then
            echo "  $n: 图 + 音 ✓"
        else
            echo "  $n: 仅图（切到它时静音）"
        fi
    done
    exit 0
fi

NAME="${1:-}"
IMG_SRC="${2:-}"
AUD_SRC="${3:-}"

if [ -z "$NAME" ]; then
    echo "用法: $0 <名字(≤8字符大写)> [图片源] [音频源]"
    echo "      $0 --list"
    exit 1
fi

# 名字校验：8.3 主名，避免 Windows 生成 LFN 项（解析器会跳过 LFN，但
# 保持 8.3 能让目录结构最干净）
if [ ${#NAME} -gt 8 ] || ! [[ "$NAME" =~ ^[A-Z0-9_]+$ ]]; then
    echo "名字须为 ≤8 字符的大写字母/数字/下划线（当前: '$NAME'）"
    exit 1
fi

mkdir -p img/bmp img/wav

# ---- 图片: 任意格式 → 640x480 24bit 非压缩 BMP ----
# 缩放策略: 等比缩放后 letterbox 补黑边（不裁剪，保持完整构图）
if [ -n "$IMG_SRC" ]; then
    [ -f "$IMG_SRC" ] || { echo "找不到图片: $IMG_SRC"; exit 1; }
    ffmpeg -y -loglevel error -i "$IMG_SRC" \
        -vf "scale=640:480:force_original_aspect_ratio=decrease,pad=640:480:(ow-iw)/2:(oh-ih)/2:black" \
        -pix_fmt bgr24 -f image2 -vcodec bmp \
        "img/bmp/$NAME.BMP"
    sz=$(stat -c%s "img/bmp/$NAME.BMP")
    echo "图片 → img/bmp/$NAME.BMP ($sz B)"
    if [ "$sz" -ne 921654 ]; then
        echo "  ⚠ 大小非 921654（标准 640x480x24bit），bmp_dec 可能拒绝——检查 ffmpeg 输出格式"
    fi
fi

# ---- 音频: 任意格式(含 mp3) → 24kHz 8bit 单声道 PCM WAV（板级规格）----
if [ -n "$AUD_SRC" ]; then
    [ -f "$AUD_SRC" ] || { echo "找不到音频: $AUD_SRC"; exit 1; }
    ffmpeg -y -loglevel error -i "$AUD_SRC" \
        -ar 24000 -ac 1 -c:a pcm_u8 -f wav \
        "img/wav/$NAME.WAV"
    sz=$(stat -c%s "img/wav/$NAME.WAV")
    secs=$(python3 -c "print(f'{max(0,$sz-44)/24000:.2f}')")
    echo "音频 → img/wav/$NAME.WAV ($sz B, ${secs}s @24k/8bit/mono)"
    # 音频乒乓缓冲各 716800 字 ≈ 2.8MB ≈ 119s @24KB/s；规范 ≤90s
    if [ "$sz" -gt 2867200 ]; then
        echo "  ⚠ 超过 2.8MB（单缓冲容量 ≈119s），播放会被截断"
    fi
fi

echo
echo "完成。下一步: ./scripts/gen_card.sh 打包入卡"
