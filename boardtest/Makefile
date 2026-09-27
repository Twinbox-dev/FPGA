# boardtest/Makefile — 板级 sd_card_bmp（3a 音画同步版）Verilator 验证台
# 用法：
#   make          # 构建 build_board/sim_board
#   make run      # 跑主卡（img/card.img，从仓库根跑：make -C boardtest run）
#   make run CARD=../img/card_mbr.img
#   make clean

VERILATOR ?= verilator
CARD      ?= ../img/card.img

VSRCS := vsrc/board_top.v vsrc/sd_card_bmp.v vsrc/sd_adapter.v \
         vsrc/fat32_ro.v vsrc/bmp_dec.v vsrc/wav_reader.v \
         vsrc/sd_spi.v vsrc/stub_sd_card_top.v
CSRCS := csrc/board_sim.cpp csrc/sd_card_model.cpp csrc/fat32_golden.cpp

SIM := build_board/sim_board

$(SIM): $(VSRCS) $(CSRCS)
	$(VERILATOR) --cc --exe --build -Wno-fatal -Wno-WIDTH -Wno-UNOPTFLAT \
	  --top-module board_top $(VSRCS) $(CSRCS) --Mdir build_board -o sim_board \
	  -CFLAGS "-O3 -march=native"

# 全量回归：7 张卡各起一个进程并行跑（16 核机器墙钟≈最慢单卡）。
# 用法：make regress（或 ../scripts/run_all_sims.sh）；日志在 logs/
regress: $(SIM)
	../scripts/run_all_sims.sh

.PHONY: run clean regress
run: $(SIM)
	./$(SIM) $(CARD)

clean:
	rm -rf build_board

# 读/写引擎真实 RTL 级自检（boardtest 主仿真用 C++ 模型替代这两个引擎，
# 写翻转/会话抢占类 bug 在主仿真不可见——2026-09-27 板级两连 bug 后补）
readeng:
	verilator --binary --timing -Wno-fatal -Wno-WIDTH -Wno-UNOPTFLAT 		--top-module tb_readeng vsrc/tb_readeng.v 		../board/user_source/hdl_source/SD/frame_fifo_read.v 		../board/user_source/hdl_source/SD/frame_fifo_write.v 		-o sim_readeng --Mdir build_readeng
	./build_readeng/sim_readeng

# video_delay 565 解包/2:1 串行化自检（视频读通道不在主仿真内，
# 相邻像素互换 bug 漏网于此——2026-09-27 补）
vdelay:
	verilator --binary --timing -Wno-fatal -Wno-WIDTH -Wno-UNOPTFLAT 		--top-module tb_vdelay vsrc/tb_vdelay.v 		../board/user_source/hdl_source/SD/video_delay.v 		-o sim_vdelay --Mdir build_vdelay
	./build_vdelay/sim_vdelay
