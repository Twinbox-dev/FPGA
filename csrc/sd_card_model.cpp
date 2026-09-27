// csrc/sd_card_model.cpp — SD 卡 SPI 模式从机模型实现
#include "sd_card_model.h"
#include <cstdio>

bool SdCardModel::load(const char *path) {
    FILE *f = fopen(path, "rb");
    if (!f) return false;
    fseek(f, 0, SEEK_END);
    long sz = ftell(f);
    fseek(f, 0, SEEK_SET);
    if (sz <= 0 || (sz % 512) != 0) {
        fclose(f);
        return false;
    }
    img.resize((size_t)sz);
    size_t rd = fread(img.data(), 1, (size_t)sz, f);
    fclose(f);
    return rd == (size_t)sz;
}

uint8_t SdCardModel::eval(uint8_t cs_n, uint8_t sclk, uint8_t mosi) {
    bool cs_fall = (prev_cs == 1) && (cs_n == 0);
    bool cs_rise = (prev_cs == 0) && (cs_n == 1);
    prev_cs = cs_n;

    if (cs_rise) {
        // CS 拉高：中止一切未完成传输
        txq.clear();
        tx_cnt = 0;
        rx_bits = 0;
        cmd_len = 0;
        miso_out = 1;
        tx_sh = 0xFF;
    }
    if (cs_n) {
        // 未选中：不响应时钟，miso 上拉为高
        prev_sclk = sclk;
        return 1;
    }

    if (cs_fall) {
        // CS 拉低：立即摆出首字节 MSB（模式 0 首个上升沿前必须有效）
        tx_sh = txq.empty() ? 0xFF : txq.front();
        if (!txq.empty()) txq.pop_front();
        miso_out = (uint8_t)(tx_sh >> 7);
        tx_sh = (uint8_t)(tx_sh << 1);
        tx_cnt = 1;
    }

    if (!prev_sclk && sclk) {
        // 上升沿：采样 MOSI
        rx_sh = (uint8_t)((rx_sh << 1) | (mosi & 1));
        if (++rx_bits == 8) {
            rx_bits = 0;
            on_byte(rx_sh);
        }
    }
    else if (prev_sclk && !sclk) {
        // 下降沿：摆出 MISO 下一位
        if (tx_cnt == 8) {
            // 当前字节摆完：装载下一字节
            tx_sh = txq.empty() ? 0xFF : txq.front();
            if (!txq.empty()) txq.pop_front();
            tx_cnt = 0;
        }
        miso_out = (uint8_t)(tx_sh >> 7);
        tx_sh = (uint8_t)(tx_sh << 1);
        tx_cnt++;
    }
    prev_sclk = sclk;
    return miso_out;
}

void SdCardModel::on_byte(uint8_t b) {
    if (cmd_len == 0) {
        if ((b & 0xC0) != 0x40) return;    // 非命令起始（0xFF 填充等），忽略
        cmdbuf[0] = b;
        cmd_len = 1;
    }
    else if (cmd_len < 6) {
        cmdbuf[cmd_len++] = b;
        if (cmd_len == 6) {
            cmd_len = 0;
            uint32_t arg = ((uint32_t)cmdbuf[1] << 24) | ((uint32_t)cmdbuf[2] << 16)
                         | ((uint32_t)cmdbuf[3] << 8) | (uint32_t)cmdbuf[4];
            on_command(cmdbuf[0] & 0x3F, arg, cmdbuf[5]);
        }
    }
}

void SdCardModel::on_command(uint8_t idx, uint32_t arg, uint8_t crc) {
    cmds_seen++;
    if (verbose) {
        std::printf("[card] CMD%u arg=%08x crc=%02x\n", idx, arg, crc);
    }

    // ---- 故障注入（在协议处理之前）----
    if (dead_card) return;                          // 死卡：什么都不回
    if (inject_cmd_drop) {                          // 丢下一条命令
        inject_cmd_drop = false;
        return;
    }
    if (inject_drop_idx != 0 && idx == inject_drop_idx) {
        inject_drop_idx = 0;                        // 丢下一条索引匹配的命令
        return;
    }

    switch (idx) {
    case 0:
        // GO_IDLE_STATE（CRC 必须正确 0x95，错了不应答——真卡行为）
        if (crc != 0x95) return;
        ready = false;
        hcs = false;
        busy_left = acmd41_busy_polls;
        reply1(0x01);
        break;

    case 8:
        // SEND_IF_COND（CRC 必须正确 0x87）
        if (arg == 0x000001AAu && crc == 0x87) {
            reply1(0x01);
            txq.push_back(0x00);
            txq.push_back(0x00);
            txq.push_back(0x01);
            txq.push_back(0xAA);
        }
        else {
            reply1(0x05);                           // 非法命令（v1 旧卡）
        }
        break;

    case 55:
        // APP_CMD
        acmd_next = true;
        reply1(ready ? 0x00 : 0x01);
        break;

    case 41:
        // ACMD41（须先 CMD55；HCS 位决定寻址模式）
        if (!acmd_next) {
            reply1(0x04);                           // 未跟在 CMD55 后：非法
            break;
        }
        acmd_next = false;
        if (busy_left > 0) {
            busy_left--;
            reply1(0x01);                           // 还在初始化
        }
        else {
            ready = true;
            hcs = (arg & 0x40000000u) != 0;
            reply1(0x00);                           // 就绪
        }
        break;

    case 58:
        // READ_OCR（CCS 位反映 HCS 协商结果）
        reply1(0x00);
        txq.push_back(hcs ? 0xC0 : 0x80);
        txq.push_back(0xFF);
        txq.push_back(0x80);
        txq.push_back(0x00);
        break;

    case 17: {
        // READ_SINGLE_BLOCK（寻址模式按 HCS 协商结果解释）
        if (!ready) {
            reply1(0x01);
            break;
        }
        if (first_read_lba == 0xFFFFFFFFu) {
            first_read_lba = arg;    // 记录首个读请求（= 主机硬编码的起始扇区）
        }
        uint64_t byte_addr;
        if (hcs) {
            byte_addr = (uint64_t)arg * 512;        // 块寻址
        }
        else {
            if (arg % 512 != 0) {                   // SDSC 字节寻址须对齐
                reply1(0x40);
                break;
            }
            byte_addr = arg;
        }
        if (byte_addr / 512 >= sector_count()) {
            reply1(0x40);                           // 越界：参数错
            break;
        }
        reply1(0x00);
        for (int i = 0; i < token_delay_bytes; i++) {
            txq.push_back(0xFF);
        }
        txq.push_back(0xFE);                        // 数据起始令牌
        const uint8_t *p = &img[byte_addr];
        for (int i = 0; i < 512; i++) {
            txq.push_back(p[i]);
        }
        txq.push_back(0x00);                        // CRC16（SPI 模式主机不校验）
        txq.push_back(0x00);
        sectors_read++;
        break;
    }

    default:
        // 未知命令（如 CMD55 写错成别的索引）→ 非法命令
        reply1(uint8_t(0x04 | (ready ? 0x00 : 0x01)));
    }
}
