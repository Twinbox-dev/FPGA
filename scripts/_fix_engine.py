#!/usr/bin/env python3
"""修复 frame_fifo_write 尾部收尾挂死（v2：子串锚点，不带行首空白）。"""
p = 'board/user_source/hdl_source/SD/frame_fifo_write.v'
s = open(p, encoding='utf-8').read()

# 1) 弹出门槛：精确计数
old = "if(App_wr_en_r && burst_cnt + App_wr_en < BURST_SIZE && (burst_cnt + write_cnt + App_wr_en < write_len_latch))begin"
assert old in s, '弹出门槛锚点'
s = s.replace(old, "if(App_wr_en_r && burst_cnt < BURST_SIZE && (write_cnt < write_len_latch))begin")

# 2) wr_burst_finish：计数到达 len 也算 burst 结束
old = "assign wr_burst_finish = (burst_cnt >= BURST_SIZE);"
assert old in s, 'wr_burst_finish 锚点'
s = s.replace(old, "assign wr_burst_finish = (burst_cnt >= BURST_SIZE) || (App_wr_en && (write_cnt >= write_len_latch));")

# 3) write_cnt 逐字计数：FSM 块 case 前加无条件自增
old = "\telse \n\tcase(state)"
if old not in s:
    # 兼容不同的空白形态
    import re
    m = re.search(r'\telse\s*\n\tcase\(state\)', s)
    assert m, 'FSM case 锚点'
    old = m.group(0)
s = s.replace(old, old.replace("case(state)",
    "begin\n\t\t// write_cnt 逐字精确计数（2026-10-04 尾部收尾修复）：尾部不满一个 burst\n\t\t// 的弹出也入账，收尾清空条件 (write_len_latch <= rdusedw + write_cnt)\n\t\t// 才能在最后一个字到达时成立（原按 burst 结算永远差一个字的账）\n\t\twrite_cnt <= write_cnt + App_wr_en;\n\tcase(state)", 1), 1)

# 4) 删除 wr_burst_finish 处的 +BURST_SIZE 结算（改逐字后由无条件自增覆盖）
old = "\t\t\t\t\t//write counter + burst length\n\t\t\t\t\twrite_cnt <= write_cnt + BURST_SIZE[ADDR_BITS - 1:0];"
assert old in s, 'burst 结算锚点'
s = s.replace(old, "\t\t\t\t\t//write_cnt 逐字计数（见 FSM 头部），不再按 burst 结算")

open(p, 'w', encoding='utf-8').write(s)
print('引擎收尾修复落盘')
