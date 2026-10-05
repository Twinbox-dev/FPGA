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

.PHONY: run clean regress readeng framepath memdump writeprobe vdelay axis uart ethfront cmdarb pulsebar
run: $(SIM)
	./$(SIM) $(CARD)

clean:
	rm -rf build_board

# 读/写引擎真实 RTL 级自检（boardtest 主仿真用 C++ 模型替代这两个引擎，
# 写翻转/会话抢占类 bug 在主仿真不可见——2026-09-27 板级两连 bug 后补）
readeng:
	verilator --binary --timing -Wno-fatal -Wno-WIDTH -Wno-UNOPTFLAT 		--top-module tb_readeng vsrc/tb_readeng.v 		../board/user_source/hdl_source/SD/frame_fifo_read.v 		../board/user_source/hdl_source/SD/frame_fifo_write.v 		-o sim_readeng --Mdir build_readeng
	./build_readeng/sim_readeng

# 真实帧读写封装 + 工程异步 FIFO，跨 100/125/75MHz 验证字序（SDRAM 口为模型）。
framepath:
	verilator --binary --timing -Wno-fatal -Wno-WIDTH -Wno-UNOPTFLAT --top-module tb_framepath vsrc/tb_framepath.v ../board/user_source/hdl_source/SD/frame_read_write.v ../board/user_source/hdl_source/SD/frame_fifo_read.v ../board/user_source/hdl_source/SD/frame_fifo_write.v ../board/user_source/hdl_source/IP/afifo_16_32_256.v ../board/user_source/hdl_source/IP/afifo_32_16_256.v -o sim_framepath --Mdir build_framepath
	./build_framepath/sim_framepath

# SDRAM 返回口被动抓取窗：视频会话同步、音频字过滤、满帧/异常收口。
memdump:
	verilator --binary --timing -Wno-fatal -Wno-WIDTH --top-module tb_memdump vsrc/tb_memdump.v ../board/user_source/hdl_source/top_tf_hdmi_audio.v -o sim_memdump --Mdir build_memdump
	./build_memdump/sim_memdump

# 写口双流窗口：跳过涂黑会话，输出与 App_wr_en 同拍的数据/地址和收口。
writeprobe:
	verilator --binary --timing -Wno-fatal -Wno-WIDTH --top-module tb_writeprobe vsrc/tb_writeprobe.v ../board/user_source/hdl_source/top_tf_hdmi_audio.v -o sim_writeprobe --Mdir build_writeprobe
	./build_writeprobe/sim_writeprobe

# video_delay 565 解包/2:1 串行化自检（视频读通道不在主仿真内，
# 相邻像素互换 bug 漏网于此——2026-09-27 补）
vdelay:
	verilator --binary --timing -Wno-fatal -Wno-WIDTH -Wno-UNOPTFLAT 		--top-module tb_vdelay vsrc/tb_vdelay.v 		../board/user_source/hdl_source/SD/video_delay.v 		-o sim_vdelay --Mdir build_vdelay
	./build_vdelay/sim_vdelay

# 720p AXI 行结束：TLAST 必须落在第 1280 个有效像素，而不是旧 640 宽的位置。
axis:
	verilator --binary --timing -Wno-fatal -Wno-WIDTH --top-module tb_axis vsrc/tb_axis.v ../board/user_source/hdl_source/video_rgb_to_axis_640x480.v -o sim_axis --Mdir build_axis
	./build_axis/sim_axis

# UART 前端 + 控制核心自检（成对校验/虚拟按键/状态包/音量——2026-09-29 拆分后）
uart:
	verilator --binary --timing -Wno-fatal -Wno-WIDTH -Wno-UNOPTFLAT 		--top-module tb_uart vsrc/tb_uart.v 		../board/user_source/hdl_source/SD/uart_link.v 		../board/user_source/hdl_source/SD/ctrl_core.v 		-o sim_uart --Mdir build_uart
	./build_uart/sim_uart

# 以太网应用层自检（eth_front）：RX 解命令/握手/TX 整帧。
# 以太网子系统下面三层（加密 UDP 栈、TEMAC 门级网表、PLL/ODDR 等厂商原语）
# Verilator 编不了，只测我们写的应用层——不可仿真的边界（UDP 栈的应用侧接口）
# 由本 TB 扮演，方法同 SD 卡的 stub_sd_card_top.v / 串口的 tb_uart.v。
ethfront:
	verilator --binary --timing -Wno-fatal -Wno-WIDTH -Wno-UNOPTFLAT --top-module tb_ethfront vsrc/tb_ethfront.v ../board/user_source/hdl_source/ETH/eth_front.v -o sim_ethfront --Mdir build_ethfront
	./build_ethfront/sim_ethfront

# 命令仲裁自检（cmd_arb：多传输前端 → ctrl_core 的唯一汇合点）。
# 这段胶水原本只在顶层、不在任何仿真范围内，"命令晚一拍"的 bug 只能上板发现。
cmdarb:
	verilator --binary --timing -Wno-fatal -Wno-WIDTH -Wno-UNOPTFLAT --top-module tb_cmd_arb vsrc/tb_cmd_arb.v ../board/user_source/hdl_source/SD/ctrl_core.v -o sim_cmdarb --Mdir build_cmdarb
	./build_cmdarb/sim_cmdarb

# 音频脉动条自检（pulse_bar：包络 + 渲染都在主仿真盲区——显示通路/音频出口，
# 按 tb_vdelay/tb_uart 先例补独立自检）
pulsebar:
	verilator --binary --timing -Wno-fatal -Wno-WIDTH -Wno-UNOPTFLAT --top-module tb_pulsebar vsrc/tb_pulsebar.v ../board/user_source/hdl_source/SD/pulse_bar.v -o sim_pulsebar --Mdir build_pulsebar
	./build_pulsebar/sim_pulsebar
