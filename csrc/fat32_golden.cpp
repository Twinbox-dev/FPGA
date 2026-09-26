// csrc/fat32_golden.cpp — FAT32 只读解析 golden 参考模型实现
#include "fat32_golden.h"
#include <algorithm>

static uint16_t le16(const uint8_t *p) {
    return (uint16_t)(p[0] | (p[1] << 8));
}

static uint32_t le32(const uint8_t *p) {
    return (uint32_t)p[0] | ((uint32_t)p[1] << 8) | ((uint32_t)p[2] << 16) | ((uint32_t)p[3] << 24);
}

GoldenFs fat32_parse_golden(const std::vector<uint8_t> &img) {
    GoldenFs g;

    auto sec = [&](uint64_t lba) -> const uint8_t * {
        if ((lba + 1) * 512 > img.size()) return nullptr;
        return img.data() + lba * 512;
    };

    // ---- 挂载：双路径 ----
    const uint8_t *s0 = sec(0);
    if (!s0) return g;

    uint32_t part = 0;
    const uint8_t *bpb = nullptr;
    if (s0[0] == 0xEB || s0[0] == 0xE9) {
        g.superfloppy = true;          // LBA0 即 BPB
        bpb = s0;
    }
    else {
        if (!(s0[510] == 0x55 && s0[511] == 0xAA)) return g;
        uint8_t type = s0[0x1C2];      // 第一个分区项（单分区约定）
        if (type != 0x0B && type != 0x0C) return g;
        part = le32(s0 + 0x1C6);
        if (part == 0) return g;
        bpb = sec(part);
        if (!bpb) return g;
    }

    // ---- BPB ----
    if (le16(bpb + 11) != 512) return g;           // bytes/sector
    g.spc = bpb[13];
    uint32_t rsvd = le16(bpb + 14);
    uint32_t nfats = bpb[16];
    uint32_t fatsz = le32(bpb + 36);
    if (g.spc == 0 || (g.spc & (g.spc - 1)) != 0 || nfats == 0 || fatsz == 0) return g;
    g.part_lba = part;
    g.fat_start = part + rsvd;
    g.first_data = part + rsvd + nfats * fatsz;
    g.root_cluster = le32(bpb + 44);
    g.ok = true;

    auto fat_entry = [&](uint32_t c) -> uint32_t {
        uint64_t off = (uint64_t)c * 4;
        const uint8_t *s = sec(g.fat_start + off / 512);
        return s ? le32(s + off % 512) : 0;
    };
    auto clus_lba = [&](uint32_t c) -> uint64_t {
        return (uint64_t)g.first_data + (uint64_t)(c - 2) * g.spc;
    };

    // ---- 根目录扫描（簇链）----
    bool scan_done = false;
    uint32_t c = g.root_cluster;
    int chain_guard = 0;
    while (!scan_done && c >= 2 && c < 0x0FFFFFF8 && chain_guard++ < 10000) {
        for (uint32_t s = 0; s < g.spc && !scan_done; s++) {
            const uint8_t *d = sec(clus_lba(c) + s);
            if (!d) {
                scan_done = true;
                break;
            }
            for (int e = 0; e < 16; e++) {
                const uint8_t *en = d + e * 32;
                if (en[0] == 0x00) { scan_done = true; break; }   // 目录结束
                if (en[0] == 0xE5) continue;                      // 已删除
                uint8_t attr = en[11];
                if (attr & 0x18) continue;        // bit3: LFN/卷标，bit4: 子目录
                bool is_bmp = (en[8] == 'B' && en[9] == 'M' && en[10] == 'P');
                bool is_wav = (en[8] == 'W' && en[9] == 'A' && en[10] == 'V');
                if (is_bmp || is_wav) {
                    GoldenFile f;
                    f.is_wav = is_wav;
                    for (int k = 0; k < 8; k++) f.name[k] = en[k];   // 主名（8.3 短名）
                    f.first_cluster = ((uint32_t)le16(en + 20) << 16) | le16(en + 26);
                    f.size = le32(en + 28);
                    // 沿簇链收集（截至 size），并统计碎片段数
                    uint32_t fc = f.first_cluster;
                    uint32_t prev = 0xFFFFFFFFu;
                    int g2 = 0;
                    while (fc >= 2 && fc < 0x0FFFFFF8 && g2++ < 100000
                           && f.data.size() < f.size) {
                        if (fc != prev + 1) f.fragments++;
                        prev = fc;
                        for (uint32_t k = 0; k < g.spc && f.data.size() < f.size; k++) {
                            const uint8_t *ds = sec(clus_lba(fc) + k);
                            if (!ds) { g2 = 1000000; break; }
                            size_t take = std::min<size_t>(512, f.size - f.data.size());
                            f.data.insert(f.data.end(), ds, ds + take);
                        }
                        fc = fat_entry(fc);
                    }
                    g.bmps.push_back(std::move(f));
                }
            }
        }
        c = fat_entry(c);               // 根目录下一簇（EOC 则退出）
    }
    return g;
}

// ---- WAV golden：独立实现 RIFF chunk 链遍历 ----
GoldenWav wav_parse_golden(const std::vector<uint8_t> &f) {
    GoldenWav w;
    if (f.size() < 12) return w;
    if (!(f[0] == 'R' && f[1] == 'I' && f[2] == 'F' && f[3] == 'F')) return w;
    if (!(f[8] == 'W' && f[9] == 'A' && f[10] == 'V' && f[11] == 'E')) return w;

    size_t p = 12;
    bool fmt_seen = false;
    size_t data_off = 0, data_len = 0;

    while (p + 8 <= f.size()) {
        const uint8_t *id = f.data() + p;
        uint32_t sz = le32(f.data() + p + 4);
        size_t body = p + 8;
        if (body + sz > f.size()) sz = (uint32_t)(f.size() - body);  // 截断保护

        if (id[0] == 'f' && id[1] == 'm' && id[2] == 't' && id[3] == ' ' && sz >= 16) {
            w.channels = le16(f.data() + body + 2);
            w.rate     = le32(f.data() + body + 4);
            w.bits     = le16(f.data() + body + 14);
            uint16_t tag = le16(f.data() + body);
            fmt_seen = (tag == 1);
        }
        else if (id[0] == 'd' && id[1] == 'a' && id[2] == 't' && id[3] == 'a') {
            data_off = body;
            data_len = sz;
            break;                                   // data 之后的块不关心
        }
        p = body + sz + (sz & 1);                    // RIFF 块按偶数对齐
    }

    if (!fmt_seen || data_len == 0) return w;
    if (w.rate != 48000 || w.bits != 16 || (w.channels != 1 && w.channels != 2))
        return w;                                    // 不支持的格式：ok 保持 false

    w.data_bytes = (uint32_t)data_len;
    size_t stride = (size_t)w.channels * 2;
    for (size_t i = 0; i + stride <= data_len; i += stride) {
        int16_t l = (int16_t)le16(f.data() + data_off + i);
        int16_t r = (w.channels == 2)
                  ? (int16_t)le16(f.data() + data_off + i + 2)
                  : l;
        w.left.push_back(l);
        w.right.push_back(r);
    }
    w.ok = true;
    return w;
}
