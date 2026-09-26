// csrc/fat32_golden.h — FAT32 只读解析 golden 参考模型（TB 侧，独立实现）
//
// 与 vsrc/fat32_ro.v 实现同一份规格（docs/design.md §5），但代码完全独立：
// 双路径挂载（superfloppy/MBR）、BPB、根目录扫描（跳 LFN/卷标/目录/E5）、
// 簇链收集。测试据此断言 RTL 的行为（文件数、文件内容、碎片化程度）。
#pragma once
#include <cstdint>
#include <vector>

struct GoldenFile {
    uint32_t first_cluster = 0;
    uint32_t size = 0;
    uint32_t fragments = 0;          // 簇链中连续段数（=1 即连续）
    bool     is_wav = false;         // 扩展名类型：false=BMP true=WAV
    std::vector<uint8_t> data;       // 文件内容（沿簇链收集，截至 size）
};

// WAV 解析结果（golden：独立实现 RIFF chunk 链遍历）
struct GoldenWav {
    bool ok = false;                 // fmt 合格（PCM/48k/16bit/1~2ch）且有 data
    uint16_t channels = 0;
    uint32_t rate = 0;
    uint16_t bits = 0;
    uint32_t data_bytes = 0;
    std::vector<int16_t> left;       // 逐帧样本（单声道时左右同值）
    std::vector<int16_t> right;
};

GoldenWav wav_parse_golden(const std::vector<uint8_t> &file);

struct GoldenFs {
    bool ok = false;                 // 挂载 + BPB 合法
    bool superfloppy = false;
    uint32_t part_lba = 0;
    uint32_t fat_start = 0;
    uint32_t first_data = 0;
    uint32_t root_cluster = 0;
    uint8_t spc = 0;                 // 每簇扇区数
    std::vector<GoldenFile> bmps;    // 目录顺序的 .BMP/.WAV 文件（含类型位）
};

GoldenFs fat32_parse_golden(const std::vector<uint8_t> &img);
