# =============================================================================
# 模块仿真验证工作区 Makefile（风格沿用 ~/ysyx-workbench/npc/E5）
# -----------------------------------------------------------------------------
# 用法:
#   make              # = make sim，编译并运行纯仿真
#   make sim          # 纯仿真（sim_main.cpp 或 main.cpp -DSIM_ONLY）
#   make run          # nvboard 图形版本（需已 export NVBOARD_HOME）
#   make wave         # 带波形跑仿真并打开查看器
#   make lint         # 只做语法 / lint 检查
#   make clean        # 清理构建产物
#   make help         # 显示帮助
#
# 可用变量:
#   MODULE  顶层模块名，缺省 top（单元测试可 MODULE=fat32_ro，配 csrc/fat32_ro-main.cpp）
#   CARD    卡镜像路径，缺省 img/card.img（变体: card_mbr / card_frag / card_empty）
#   WAVES   0 关 | 1 VCD | 2 FST（wave 目标默认置 1）
#   VIEWER  wave 用的查看器，缺省 surfer，找不到则 gtkwave
# =============================================================================

MODULE ?= top
CARD   ?= img/card.img
WAVES  ?= 0

# ---- 文件列表：默认识别当前目录 vsrc/ tb/ csrc/ ----
VSRCS = $(wildcard vsrc/*.v vsrc/*.sv tb/*.v tb/*.sv)

# C++ 入口（E5 惯例）：csrc/<MODULE>-main.cpp 优先，否则 csrc/main.cpp
# 其余 csrc/*.cpp 一并编译（TB 模型以后可拆文件，如 sd_card_model.cpp）
MAIN_CPP := $(firstword $(foreach f,csrc/$(MODULE)-main.cpp csrc/main.cpp,$(if $(wildcard $(f)),$(f),)))
EXTRA_CSRCS := $(filter-out csrc/main.cpp csrc/sim_main.cpp csrc/%-main.cpp,$(wildcard csrc/*.cpp))

# 仿真入口：有独立 sim_main.cpp 就用；否则复用 main.cpp 加 -DSIM_ONLY，
# 同一份 cpp 用 #ifdef SIM_ONLY 区分仿真与 nvboard 模式（同 E5/8_vga）
SIM_CPP := $(if $(wildcard csrc/sim_main.cpp),csrc/sim_main.cpp,$(MAIN_CPP))
ifeq ($(SIM_CPP),$(MAIN_CPP))
  SIM_CFLAGS := -CFLAGS "-DSIM_ONLY"
else
  SIM_CFLAGS :=
endif

ifneq ($(filter-out help clean lint,$(MAKECMDGOALS)),)
ifeq ($(strip $(MAIN_CPP)),)
$(error 找不到 C++ 入口：需要 csrc/main.cpp 或 csrc/$(MODULE)-main.cpp)
endif
endif

# ---- 构建目录：sim 与 nvboard 分开，避免互相覆盖 ----
# 波形模式编进目录后缀：切换 WAVES 必然重编（否则 make 认为二进制已是最新，
# 会拿着无波形的旧程序去跑），切回来还能复用缓存
ifeq ($(WAVES),1)
  TRACE_SUFFIX := _vcd
else ifeq ($(WAVES),2)
  TRACE_SUFFIX := _fst
else
  TRACE_SUFFIX :=
endif
BUILD_DIR := build
SIMBIN := $(BUILD_DIR)/sim$(TRACE_SUFFIX)/$(MODULE)
BIN    := $(BUILD_DIR)/nvboard$(TRACE_SUFFIX)/$(MODULE)

VERILATOR_FLAGS = -Wall --cc --exe --build -j $(shell nproc) -Wno-DECLFILENAME --top-module $(MODULE)
ifeq ($(WAVES),1)
    VERILATOR_FLAGS += --trace
else ifeq ($(WAVES),2)
    VERILATOR_FLAGS += --trace-fst
endif

# ---- nvboard 相关（run 目标用）----
NVBOARD_SRCS := $(wildcard $(NVBOARD_HOME)/src/*.cpp)
SDL_CFLAGS   := $(shell sdl2-config --cflags)
SDL_LIBS     := $(shell sdl2-config --libs) -lSDL2_image -lSDL2_ttf
NVBOARD_LIB  := $(abspath $(BUILD_DIR)/nvboard.a)

ifneq ($(filter run,$(MAKECMDGOALS)),)
ifeq ($(strip $(NVBOARD_HOME)),)
$(error NVBOARD_HOME 未设置，无法构建 nvboard 版本)
endif
endif

# ---- wave 目标的波形文件与查看器 ----
ifeq ($(WAVES),2)
WAVE_FILE := dump.fst
else
WAVE_FILE := dump.vcd
endif
VIEWER ?= $(if $(shell command -v surfer 2>/dev/null),surfer,gtkwave)

.DEFAULT_GOAL := sim

# ---- 构建 nvboard 静态库 ----
$(NVBOARD_LIB): $(NVBOARD_SRCS)
	mkdir -p $(BUILD_DIR)/nvboard
	cd $(BUILD_DIR)/nvboard && g++ -I$(NVBOARD_HOME)/include $(SDL_CFLAGS) -c $(NVBOARD_SRCS)
	ar rcs $@ $(BUILD_DIR)/nvboard/*.o

# ---- 构建 nvboard 版本 ----
$(BIN): $(VSRCS) $(MAIN_CPP) $(EXTRA_CSRCS) $(NVBOARD_LIB)
	mkdir -p $(dir $@)
	verilator $(VERILATOR_FLAGS) $(VSRCS) $(MAIN_CPP) $(EXTRA_CSRCS) $(NVBOARD_LIB) \
		--Mdir $(BUILD_DIR)/obj_$(MODULE)$(TRACE_SUFFIX) -o $(abspath $@) \
		-CFLAGS "-I$(NVBOARD_HOME)/usr/include $(SDL_CFLAGS)" \
		-LDFLAGS "$(SDL_LIBS)"

# ---- 构建纯仿真版本 ----
$(SIMBIN): $(VSRCS) $(SIM_CPP) $(EXTRA_CSRCS)
	mkdir -p $(dir $@)
	verilator $(VERILATOR_FLAGS) $(VSRCS) $(SIM_CPP) $(EXTRA_CSRCS) \
		--Mdir $(BUILD_DIR)/obj_$(MODULE)_sim$(TRACE_SUFFIX) -o $(abspath $@) \
		$(SIM_CFLAGS)

# ---- 用户目标 ----
run: $(BIN)
	@$(BIN) $(CARD)

sim: $(SIMBIN)
	@$(SIMBIN) $(CARD)

# wave: 带波形跑一遍仿真，然后打开查看器（WAVES=2 则用 FST）
wave:
	$(MAKE) sim WAVES=$(if $(filter 2,$(WAVES)),2,1)
	$(VIEWER) $(WAVE_FILE)

lint: $(VSRCS)
	@verilator --lint-only -Wall -Wno-DECLFILENAME --top-module $(MODULE) $(VSRCS)

# ---- 自动发现全部测试入口：top 骨架 + 各 csrc/<模块>-main.cpp ----
TEST_MODULES := top $(patsubst csrc/%-main.cpp,%,$(wildcard csrc/*-main.cpp))

# regress: 模块单测（top 除外）+ 全部卡变体，聚合退出码
regress:
	@rc=0; \
	for m in $(filter-out top,$(TEST_MODULES)); do \
	  echo "===== regress: MODULE=$$m ====="; \
	  $(MAKE) -s sim MODULE=$$m || rc=1; \
	done; \
	for c in img/card*.img; do \
	  [ -e "$$c" ] || continue; \
	  echo "===== regress: CARD=$$c ====="; \
	  $(MAKE) -s sim MODULE=top CARD=$$c || rc=1; \
	done; \
	echo "===== regress result: $$([ $$rc -eq 0 ] && echo ALL PASS || echo FAIL) ====="; \
	exit $$rc

clean:
	rm -rf $(BUILD_DIR) *.vcd *.fst

help:
	@echo "Usage: make [MODULE=<top>] [WAVES=0|1|2] <target>"
	@echo ""
	@echo "Targets:"
	@echo "  sim     Compile and run simulation (headless, MODULE 选模块)"
	@echo "  run     Compile and run nvboard version (needs NVBOARD_HOME)"
	@echo "  wave    Run sim with waveform, then open viewer (surfer/gtkwave)"
	@echo "  lint    Run verilator lint check only"
	@echo "  regress Run all module tests (auto-discovered) and aggregate"
	@echo "  clean   Remove build outputs"
	@echo "  help    Show this help message"

.PHONY: run sim wave lint regress clean help
