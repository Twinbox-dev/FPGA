// csrc/sd_card_model.h — SD 卡 SPI 模式从机模型（引脚级）
//
// 与 DUT 的 4 根 SPI 线逐拍交互（每个 eval 调一次），从卡镜像按扇区应答：
//   CMD0 / CMD8 / CMD55 / ACMD41 / CMD58 / CMD17
// 按真实卡的习惯建模：
//   R1 前有 1 字节 Ncr；ACMD41 前 N 次回 busy；数据令牌前有 N 字节 0xFF；
//   CMD0/CMD8 校验 CRC（错则不应答 / 回非法命令）——抓 DUT 常量写错；
//   ACMD41 记录 HCS 位：HCS=1 块寻址，HCS=0 退化字节寻址（真卡兼容行为）
//   —— DUT 丢 HCS 位时读出的数据会错，由 golden 比对抓出
//
// 故障注入：丢命令（任意/按索引）、死卡——测 DUT 的超时重试与错误处理。
// 上板时本模型被真卡替换，RTL 不变。
#pragma once
#include <cstdint>
#include <deque>
#include <vector>

class SdCardModel {
public:
    // ---- 行为配置 / 故障注入 ----
    int     acmd41_busy_polls = 3;    // 前 N 次 ACMD41 回 busy（模拟上电慢的卡）
    int     token_delay_bytes = 4;    // CMD17 数据令牌前的 0xFF 字节数
    bool    inject_cmd_drop   = false; // 丢掉下一条命令（不作答）
    uint8_t inject_drop_idx   = 0;    // 丢掉下一条索引匹配的命令（0 = 关闭）
    bool    dead_card         = false; // 完全不应答任何命令（测重试耗尽）
    bool    verbose           = false;

    bool load(const char *path);                 // 卡镜像（512B 扇区对齐）
    uint64_t sector_count() const { return img.size() / 512; }

    // 每个 eval 调一次：输入 DUT 引脚电平，返回 miso 电平
    uint8_t eval(uint8_t cs_n, uint8_t sclk, uint8_t mosi);

    // 观测
    uint64_t sectors_read = 0;
    uint64_t cmds_seen = 0;
    uint32_t first_read_lba = 0xFFFFFFFFu;   // 首条 CMD17 的 LBA（TB 据此定位 golden）

private:
    std::vector<uint8_t> img;
    std::deque<uint8_t>  txq;        // 待发字节队列（空则持续发 0xFF）

    // 物理层
    uint8_t prev_cs = 1, prev_sclk = 0;
    uint8_t rx_sh = 0;
    int     rx_bits = 0;
    uint8_t tx_sh = 0xFF;
    int     tx_cnt = 0;              // 当前输出字节已摆出的位数
    uint8_t miso_out = 1;

    // 协议层
    bool ready = false;              // ACMD41 完成
    bool acmd_next = false;          // CMD55 已发
    bool hcs = false;                // ACMD41 的 HCS 位 → 寻址模式
    int  busy_left = 0;
    uint8_t cmdbuf[6];
    int cmd_len = 0;

    void on_byte(uint8_t b);
    void on_command(uint8_t idx, uint32_t arg, uint8_t crc);
    void reply1(uint8_t r1) {
        txq.push_back(0xFF);         // Ncr = 1 字节
        txq.push_back(r1);
    }
};
