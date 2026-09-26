# boardtest/Makefile — 板级 sd_card_bmp（3a 音画同步版）Verilator 验证台
# 用法：
#   make          # 构建 build_board/sim_board
#   make run      # 跑主卡（img/card.img，从仓库根跑：make -C boardtest run）
#   make run CARD=../img/card_mbr.img
#   make clean

VERILATOR ?= verilator
CARD      ?= ../img/card.img

VSRCS := vsrc/board_top.v vsrc/sd_card_bmp.v vsrc/sd_adapter.v \
         vsrc/fat32_ro.v vsrc/bmp_dec.v \
         vsrc/sd_spi.v vsrc/stub_sd_card_top.v
CSRCS := csrc/board_sim.cpp csrc/sd_card_model.cpp csrc/fat32_golden.cpp

SIM := build_board/sim_board

$(SIM): $(VSRCS) $(CSRCS)
	$(VERILATOR) --cc --exe --build -Wno-fatal -Wno-WIDTH -Wno-UNOPTFLAT \
	  --top-module board_top $(VSRCS) $(CSRCS) --Mdir build_board -o sim_board

.PHONY: run clean
run: $(SIM)
	./$(SIM) $(CARD)

clean:
	rm -rf build_board
