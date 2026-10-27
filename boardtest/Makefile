# boardtest/Makefile — 板级 sd_card_bmp（3a 音画同步版）Verilator 验证台
# 用法：
#   make          # 构建 build_board/sim_board
#   make run      # 跑主卡（img/card.img，从仓库根跑：make -C boardtest run）
#   make run CARD=../img/card_mbr.img
#   make clean

VERILATOR ?= verilator
CARD      ?= ../img/card.img
CARDS     ?= card card_mbr card_empty card_frag card_diag card_user card_user_2wav

VSRCS := vsrc/board_top.v vsrc/sd_card_bmp.v vsrc/sd_adapter.v \
         vsrc/fat32_ro.v vsrc/bmp_dec.v vsrc/wav_reader.v \
         vsrc/sd_spi.v vsrc/stub_sd_card_top.v
CSRCS := csrc/board_sim.cpp csrc/sd_card_model.cpp csrc/fat32_golden.cpp

SIM := build_board/sim_board
SIM_LEAN := build_board_lean/sim_board

$(SIM): $(VSRCS) $(CSRCS)
	$(VERILATOR) --cc --exe --build -Wno-fatal -Wno-WIDTH -Wno-UNOPTFLAT \
	  --top-module board_top $(VSRCS) $(CSRCS) --Mdir build_board -o sim_board \
	  -CFLAGS "-O3 -march=native"

$(SIM_LEAN): $(VSRCS) $(CSRCS)
	$(VERILATOR) --cc --exe --build -DFPGA_LEAN_LIST_DIAG -Wno-fatal -Wno-WIDTH -Wno-UNOPTFLAT \
	  --top-module board_top $(VSRCS) $(CSRCS) --Mdir build_board_lean -o sim_board \
	  -CFLAGS "-O3 -march=native"

lean-smoke: $(SIM_LEAN)
	SIM_LEAN_LIST=1 SIM_SMOKE=1 ./$(SIM_LEAN) ../img/card_diag.img

# 全量回归：7 张卡各起一个进程并行跑（16 核机器墙钟≈最慢单卡）。
# 用法：make regress（或 ../scripts/run_all_sims.sh）；日志在 logs/
regress: $(SIM)
	CARDS="$(CARDS)" ../scripts/run_all_sims.sh

# Checks mount, first BMP and WAV scan only; run regress before merging.
smoke: $(SIM)
	SIM_SMOKE=1 CARDS=card_diag ../scripts/run_all_sims.sh

# Pairing table, boot audio and the first image/audio switch.
paircheck: $(SIM)
	SIM_PAIR=1 CARDS=card_diag ../scripts/run_all_sims.sh

.PHONY: run clean regress smoke paircheck lean-smoke readeng framepath arbrace memdump writeprobe vdelay axis uart ethfront media-net-lite media-net-lite-app dualboardcmd mediamux cmdarb pulsebar spectrum-unit gt911-unit media-protocol media-writer media-control media-tx media-audio-playback media-display-path ctrlset media-frame-format media-frame-pad media-bmp-format media-tx-gap media-packet-drain media-single-step media-button
run: $(SIM)
	./$(SIM) $(CARD)

clean:
	rm -rf build_board

# 读/写引擎真实 RTL 级自检（boardtest 主仿真用 C++ 模型替代这两个引擎，
# 写翻转/会话抢占类 bug 在主仿真不可见——2026-09-27 板级两连 bug 后补）
readeng:
	verilator --binary --timing -Wno-fatal -Wno-WIDTH -Wno-UNOPTFLAT 		--top-module tb_readeng vsrc/tb_readeng.v 		../board_display/user_source/hdl_source/SD/frame_fifo_read.v 		../board_display/user_source/hdl_source/SD/frame_fifo_write.v 		-o sim_readeng --Mdir build_readeng
	./build_readeng/sim_readeng

# 真实帧读写封装 + 工程异步 FIFO，跨 100/100/75MHz 验证字序（SDRAM 口为模型）。
framepath:
	verilator --binary --timing -Wno-fatal -Wno-WIDTH -Wno-UNOPTFLAT --top-module tb_framepath vsrc/tb_framepath.v ../board_display/user_source/hdl_source/SD/frame_read_write.v ../board_display/user_source/hdl_source/SD/frame_fifo_read.v ../board_display/user_source/hdl_source/SD/frame_fifo_write.v ../board_display/user_source/hdl_source/IP/afifo_16_32_256.v ../board_display/user_source/hdl_source/IP/afifo_32_16_256.v -o sim_framepath --Mdir build_framepath
	./build_framepath/sim_framepath

# 写突发判决寄存后一拍重查读忙；旧代码在读忙升起时仍会启动写突发。
arbrace:
	verilator --binary --timing -Wno-fatal -Wno-WIDTH --top-module tb_arbrace vsrc/tb_arbrace.v ../board_display/user_source/hdl_source/SD/frame_fifo_write.v -o sim_arbrace --Mdir build_arbrace
	./build_arbrace/sim_arbrace

# SDRAM 返回口被动抓取窗：视频会话同步、音频字过滤、满帧/异常收口。
memdump:
	verilator --binary --timing -Wno-fatal -Wno-WIDTH --top-module tb_memdump vsrc/tb_memdump.v ../board_display/user_source/hdl_source/top_tf_hdmi_audio.v -o sim_memdump --Mdir build_memdump
	./build_memdump/sim_memdump

# 写口双流窗口：跳过涂黑会话，输出与 App_wr_en 同拍的数据/地址和收口。
writeprobe:
	verilator --binary --timing -Wno-fatal -Wno-WIDTH --top-module tb_writeprobe vsrc/tb_writeprobe.v ../board_display/user_source/hdl_source/top_tf_hdmi_audio.v -o sim_writeprobe --Mdir build_writeprobe
	./build_writeprobe/sim_writeprobe

# video_delay 565 解包/2:1 串行化自检（视频读通道不在主仿真内，
# 相邻像素互换 bug 漏网于此——2026-09-27 补）
vdelay:
	verilator --binary --timing -Wno-fatal -Wno-WIDTH -Wno-UNOPTFLAT 		--top-module tb_vdelay vsrc/tb_vdelay.v 		../board_display/user_source/hdl_source/SD/video_delay.v 		-o sim_vdelay --Mdir build_vdelay
	./build_vdelay/sim_vdelay

# 720p AXI 行结束：TLAST 必须落在第 1280 个有效像素，而不是旧 640 宽的位置。
axis:
	verilator --binary --timing -Wno-fatal -Wno-WIDTH --top-module tb_axis vsrc/tb_axis.v ../board_display/user_source/hdl_source/video_rgb_to_axis_640x480.v -o sim_axis --Mdir build_axis
	./build_axis/sim_axis

# UART 前端 + 控制核心自检（成对校验/虚拟按键/状态包/音量——2026-09-29 拆分后）
uart:
	verilator --binary --timing -Wno-fatal -Wno-WIDTH -Wno-UNOPTFLAT 		--top-module tb_uart vsrc/tb_uart.v 		../board_display/user_source/hdl_source/SD/uart_link.v 		../board_display/user_source/hdl_source/SD/ctrl_core.v 		-o sim_uart --Mdir build_uart
	./build_uart/sim_uart

# 以太网应用层自检（eth_front）：RX 解命令/握手/TX 整帧。
# 以太网子系统下面三层（加密 UDP 栈、TEMAC 门级网表、PLL/ODDR 等厂商原语）
# Verilator 编不了，只测我们写的应用层——不可仿真的边界（UDP 栈的应用侧接口）
# 由本 TB 扮演，方法同 SD 卡的 stub_sd_card_top.v / 串口的 tb_uart.v。
ethfront:
	verilator --binary --timing -Wno-fatal -Wno-WIDTH -Wno-UNOPTFLAT --top-module tb_ethfront vsrc/tb_ethfront.v ../board_display/user_source/hdl_source/ETH/eth_front.v -o sim_ethfront --Mdir build_ethfront
	./build_ethfront/sim_ethfront

# Dual-peer media-board UDP-lite stack, including 1022-byte receive/transmit.
media-net-lite:
	$(VERILATOR) --binary --timing -Wno-fatal -Wno-WIDTH -Wno-TIMESCALEMOD --top-module tb_media_udp_lite vsrc/tb_media_udp_lite.sv ../board_media/user_source/hdl_source/ETH/media_udp_lite.v -o sim_media_udp_lite --Mdir build_media_udp_lite
	./build_media_udp_lite/sim_media_udp_lite

# Exercise the real media eth_front command parser and response stream.
media-net-lite-app:
	$(VERILATOR) --binary --timing -Wno-fatal -Wno-WIDTH -Wno-UNOPTFLAT -Wno-TIMESCALEMOD --top-module tb_media_udp_lite_ethfront vsrc/tb_media_udp_lite_ethfront.sv ../board_media/user_source/hdl_source/ETH/media_udp_lite.v ../board_media/user_source/hdl_source/ETH/eth_front.v -o sim_media_udp_lite_ethfront --Mdir build_media_udp_lite_ethfront
	./build_media_udp_lite_ethfront/sim_media_udp_lite_ethfront

# 两板应用层命令往返：PC 帧 -> 媒体板桥 -> 显示板命令邮箱。
dualboardcmd:
	$(VERILATOR) --binary --timing -Wno-fatal -Wno-WIDTH -Wno-UNOPTFLAT --top-module tb_dual_board_cmd vsrc/tb_dual_board_cmd.v ../board_media/user_source/hdl_source/media_probe_bridge.v ../board_media/user_source/hdl_source/ETH/eth_front.v -o sim_dual_board_cmd --Mdir build_dual_board_cmd
	./build_dual_board_cmd/sim_dual_board_cmd

# 媒体分片编解码：边界 253 字、CRC、损坏/截断包拒收。
mediamux:
	$(VERILATOR) --binary --timing -Wno-fatal -Wno-WIDTH --top-module tb_media_tx_mux vsrc/tb_media_tx_mux.v ../board_display/user_source/hdl_source/ETH/media_tx_mux.v -o sim_media_tx_mux --Mdir build_media_tx_mux
	./build_media_tx_mux/sim_media_tx_mux

# 命令仲裁自检（cmd_arb：多传输前端 → ctrl_core 的唯一汇合点）。
# 这段胶水原本只在顶层、不在任何仿真范围内，"命令晚一拍"的 bug 只能上板发现。
cmdarb:
	verilator --binary --timing -Wno-fatal -Wno-WIDTH -Wno-UNOPTFLAT --top-module tb_cmd_arb vsrc/tb_cmd_arb.v ../board_display/user_source/hdl_source/SD/ctrl_core.v -o sim_cmdarb --Mdir build_cmdarb
	./build_cmdarb/sim_cmdarb

# 音频脉动条自检（pulse_bar：包络 + 渲染都在主仿真盲区——显示通路/音频出口，
# 按 tb_vdelay/tb_uart 先例补独立自检）
pulsebar:
	verilator --binary --timing -Wno-fatal -Wno-WIDTH -Wno-UNOPTFLAT --top-module tb_pulsebar vsrc/tb_pulsebar.v ../board_display/user_source/hdl_source/SD/pulse_bar.v -o sim_pulsebar --Mdir build_pulsebar
	./build_pulsebar/sim_pulsebar

# Transition unit checks are incremental; each executable rebuilds only when
# its testbench or RTL dependency changes. transitionpair exercises the SD
# image/WAV commit with a simulated video-domain completion toggle.
TSD := ../board_display/user_source/hdl_source/SD
build_transition_blender/sim_transition_blender: vsrc/tb_transition_blender.v $(TSD)/transition_blender.v
	$(VERILATOR) --binary --timing -Wno-fatal -Wno-WIDTH --top-module tb_transition_blender $^ --Mdir build_transition_blender -o sim_transition_blender

build_transition_line/sim_transition_line: vsrc/tb_transition_line_read.v $(TSD)/transition_line_read.v
	$(VERILATOR) --binary --timing -Wno-fatal -Wno-WIDTH --top-module tb_transition_line_read $^ --Mdir build_transition_line -o sim_transition_line

build_transition_ctrl/sim_transition_ctrl: vsrc/tb_transition_ctrl.v $(TSD)/transition_ctrl.v
	$(VERILATOR) --binary --timing -Wno-fatal -Wno-WIDTH --top-module tb_transition_ctrl $^ --Mdir build_transition_ctrl -o sim_transition_ctrl

build_transition_video/sim_transition_video: vsrc/tb_transition_video.v $(TSD)/transition_blender.v $(TSD)/video_delay.v
	$(VERILATOR) --binary --timing -Wno-fatal -Wno-WIDTH --top-module tb_transition_video $^ --Mdir build_transition_video -o sim_transition_video

build_transition_fetch/sim_transition_fetch: vsrc/tb_transition_fetch.v $(TSD)/transition_ctrl.v $(TSD)/transition_line_read.v $(TSD)/transition_line_buf.v
	$(VERILATOR) --binary --timing -Wno-fatal -Wno-WIDTH --top-module tb_transition_fetch $^ --Mdir build_transition_fetch -o sim_transition_fetch

build_transition_framepath/sim_transition_framepath: vsrc/tb_transition_framepath.v $(TSD)/transition_line_read.v $(TSD)/frame_read_write.v $(TSD)/frame_fifo_read.v $(TSD)/frame_fifo_write.v ../board_display/user_source/hdl_source/IP/afifo_16_32_256.v ../board_display/user_source/hdl_source/IP/afifo_32_16_256.v
	$(VERILATOR) --binary --timing -Wno-fatal -Wno-WIDTH -Wno-UNOPTFLAT --top-module tb_transition_framepath $^ --Mdir build_transition_framepath -o sim_transition_framepath

build_multiview_transition_fetch/sim_multiview_transition_fetch: vsrc/tb_multiview_transition_fetch.sv $(TSD)/transition_ctrl.v $(TSD)/transition_line_read.v $(TSD)/transition_line_buf.v
	$(VERILATOR) --binary --timing -Wno-fatal -Wno-WIDTH --top-module tb_multiview_transition_fetch $^ --Mdir build_multiview_transition_fetch -o sim_multiview_transition_fetch

.PHONY: transition-unit transitionpair
transition-unit: build_transition_blender/sim_transition_blender build_transition_line/sim_transition_line build_transition_ctrl/sim_transition_ctrl build_transition_video/sim_transition_video build_transition_fetch/sim_transition_fetch build_transition_framepath/sim_transition_framepath build_multiview_transition_fetch/sim_multiview_transition_fetch
	./build_transition_blender/sim_transition_blender
	./build_transition_line/sim_transition_line
	./build_transition_ctrl/sim_transition_ctrl
	./build_transition_video/sim_transition_video
	./build_transition_fetch/sim_transition_fetch
	./build_transition_framepath/sim_transition_framepath
	./build_multiview_transition_fetch/sim_multiview_transition_fetch

transitionpair: $(SIM)
	SIM_TRANSITION=1 SIM_PAIR=1 ./$(SIM) ../img/card_diag.img

# HDMI-only subtitle/OSD units. Kept independent of the full SD-card image test.
OSD_FONT := $(TSD)/font_rom.v $(TSD)/font.mem
build_font_rom_2r/sim_font_rom_2r: vsrc/tb_font_rom_2r.v $(OSD_FONT)
	$(VERILATOR) --binary --timing -Wno-fatal -Wno-WIDTH --top-module tb_font_rom_2r $(filter %.v,$^) --Mdir build_font_rom_2r -o sim_font_rom_2r
build_subtitle_cmd/sim_subtitle_cmd: vsrc/tb_subtitle_cmd.v $(TSD)/subtitle_cmd.v
	$(VERILATOR) --binary --timing -Wno-fatal -Wno-WIDTH --top-module tb_subtitle_cmd $^ --Mdir build_subtitle_cmd -o sim_subtitle_cmd
build_subtitle_ctrl/sim_subtitle_ctrl: vsrc/tb_subtitle_ctrl.v $(TSD)/subtitle_cmd.v $(TSD)/ctrl_core.v
	$(VERILATOR) --binary --timing -Wno-fatal -Wno-WIDTH --top-module tb_subtitle_ctrl $^ --Mdir build_subtitle_ctrl -o sim_subtitle_ctrl
build_subtitle_store/sim_subtitle_store: vsrc/tb_subtitle_store.v $(TSD)/subtitle_store.v
	$(VERILATOR) --binary --timing -Wno-fatal -Wno-WIDTH --top-module tb_subtitle_store $^ --Mdir build_subtitle_store -o sim_subtitle_store
build_subtitle_scroll/sim_subtitle_scroll: vsrc/tb_subtitle_scroll.v $(TSD)/subtitle_scroll.v
	$(VERILATOR) --binary --timing -Wno-fatal -Wno-WIDTH --top-module tb_subtitle_scroll $^ --Mdir build_subtitle_scroll -o sim_subtitle_scroll
build_subtitle_text/sim_subtitle_text: vsrc/tb_subtitle_text.v $(TSD)/subtitle_text_renderer.v $(OSD_FONT)
	$(VERILATOR) --binary --timing -Wno-fatal -Wno-WIDTH --unroll-count 1 --top-module tb_subtitle_text $(filter %.v,$^) --Mdir build_subtitle_text -o sim_subtitle_text
build_osd_visibility/sim_osd_visibility: vsrc/tb_osd_visibility.v $(TSD)/osd_visibility.v
	$(VERILATOR) --binary --timing -Wno-fatal -Wno-WIDTH --top-module tb_osd_visibility $^ --Mdir build_osd_visibility -o sim_osd_visibility
build_osd_composite/sim_osd_composite: vsrc/tb_osd_composite.v $(TSD)/osd_composite.v
	$(VERILATOR) --binary --timing -Wno-fatal -Wno-WIDTH --top-module tb_osd_composite $^ --Mdir build_osd_composite -o sim_osd_composite
build_osd_panel/sim_osd_panel: vsrc/tb_osd_panel_levels.v $(TSD)/osd_panel_levels.v $(OSD_FONT)
	$(VERILATOR) --binary --timing -Wno-fatal -Wno-WIDTH --top-module tb_osd_panel_levels $(filter %.v,$^) --Mdir build_osd_panel -o sim_osd_panel
.PHONY: osd-unit
osd-unit: build_font_rom_2r/sim_font_rom_2r build_subtitle_cmd/sim_subtitle_cmd build_subtitle_ctrl/sim_subtitle_ctrl build_subtitle_store/sim_subtitle_store build_subtitle_scroll/sim_subtitle_scroll build_subtitle_text/sim_subtitle_text build_osd_visibility/sim_osd_visibility build_osd_composite/sim_osd_composite build_osd_panel/sim_osd_panel
	./build_font_rom_2r/sim_font_rom_2r
	./build_subtitle_cmd/sim_subtitle_cmd
	./build_subtitle_ctrl/sim_subtitle_ctrl
	./build_subtitle_store/sim_subtitle_store
	./build_subtitle_scroll/sim_subtitle_scroll
	./build_subtitle_text/sim_subtitle_text
	./build_osd_visibility/sim_osd_visibility
	./build_osd_composite/sim_osd_composite
	./build_osd_panel/sim_osd_panel

build_spectrum_dft/sim_spectrum_dft: vsrc/tb_spectrum_dft.v $(TSD)/spectrum_dft.v $(TSD)/spectrum_sample_buf.v $(TSD)/spectrum_twiddle_512.mem
	$(VERILATOR) --binary --timing -Wno-fatal -Wno-WIDTH --top-module tb_spectrum_dft $(filter %.v,$^) --Mdir build_spectrum_dft -o sim_spectrum_dft
build_spectrum_overlay/sim_spectrum_overlay: vsrc/tb_spectrum_overlay.v $(TSD)/spectrum_overlay.v
	$(VERILATOR) --binary --timing -Wno-fatal -Wno-WIDTH --top-module tb_spectrum_overlay $^ --Mdir build_spectrum_overlay -o sim_spectrum_overlay
.PHONY: spectrum-unit
spectrum-unit: build_spectrum_dft/sim_spectrum_dft build_spectrum_overlay/sim_spectrum_overlay
	./build_spectrum_dft/sim_spectrum_dft
	./build_spectrum_overlay/sim_spectrum_overlay

# GT911 is independent of the SD-card model. The I2C test covers both 0x5D
# direct ACK and fallback to 0x14; the video test checks cursor alignment.
build_gt911_trackpad/sim_gt911_trackpad: vsrc/tb_gt911_trackpad.v $(TSD)/gt911_trackpad.v $(TSD)/gt911_i2c_byte.v $(TSD)/gt911_cursor_overlay.v
	$(VERILATOR) --binary --timing -Wno-fatal -Wno-WIDTH --top-module tb_gt911_trackpad $^ --Mdir build_gt911_trackpad -o sim_gt911_trackpad

build_gt911_cursor/sim_gt911_cursor: vsrc/tb_gt911_cursor.v $(TSD)/gt911_cursor_overlay.v
	$(VERILATOR) --binary --timing -Wno-fatal -Wno-WIDTH --top-module tb_gt911_cursor $^ --Mdir build_gt911_cursor -o sim_gt911_cursor

.PHONY: gt911-unit sd-native media-sd-image-source media-uart-arbiter bt-uart-unit
gt911-unit: build_gt911_trackpad/sim_gt911_trackpad build_gt911_cursor/sim_gt911_cursor
	./build_gt911_trackpad/sim_gt911_trackpad
	./build_gt911_cursor/sim_gt911_cursor

# Native 4-bit SD host and pin-level card model. The first run reads LBA0 from
# the real image and injects a dropped response, delayed response and CRC error;
# later runs cover 25 MHz fallback and SDSC byte-addressing.
SD_NATIVE_RTL := ../board_media/user_source/hdl_source/SD/sd_native_cmd.v \
	../board_media/user_source/hdl_source/SD/sd_native_host.v \
	../board_media/user_source/hdl_source/SD/sd_native_adapter.v
build_sd_native_host/sim_sd_native_host: vsrc/tb_sd_native_host.sv vsrc/sd_native_card_model.sv $(SD_NATIVE_RTL)
	$(VERILATOR) --binary --build-jobs 4 --timing -Wno-fatal -Wno-WIDTH -Wno-UNUSEDSIGNAL -Wno-BLKSEQ \
	  --top-module tb_sd_native_host $^ --Mdir build_sd_native_host -o sim_sd_native_host

sd-native: build_sd_native_host/sim_sd_native_host build_sd_native_host_25/sim_sd_native_host_25
	./build_sd_native_host/sim_sd_native_host +CARD=../img/card_user_real.img +DROP_READ_RESPONSE=1 +BAD_CRC_ONCE=1 +READ_RESPONSE_DELAY=8
	./build_sd_native_host/sim_sd_native_host +CARD=../img/card_user_real.img +HS=0
	./build_sd_native_host/sim_sd_native_host +CARD=../img/card_user_real.img +HC=0
	./build_sd_native_host/sim_sd_native_host +CARD=../img/card_user_real.img +V1=1
	./build_sd_native_host/sim_sd_native_host +CARD=../img/card_user_real.img +DROP_CMD55=1
	./build_sd_native_host_25/sim_sd_native_host_25 +CARD=../img/card_user_real.img +DROP_READ_RESPONSE=1 +BAD_CRC_ONCE=1 +READ_RESPONSE_DELAY=8

build_sd_native_host_25/sim_sd_native_host_25: vsrc/tb_sd_native_host.sv vsrc/sd_native_card_model.sv $(SD_NATIVE_RTL)
	$(VERILATOR) --binary --build-jobs 4 --timing -Wno-fatal -Wno-WIDTH -Wno-UNUSEDSIGNAL -Wno-BLKSEQ \
	  --top-module tb_sd_native_host -GFORCE_25MHZ=1 $^ --Mdir build_sd_native_host_25 -o sim_sd_native_host_25

SD_IMAGE_SOURCE_RTL := ../board_media/user_source/hdl_source/SD/sd_native_cmd.v \
	../board_media/user_source/hdl_source/SD/sd_native_host.v \
	../board_media/user_source/hdl_source/SD/sd_native_adapter.v \
	../board_media/user_source/hdl_source/SD/fat32_ro.v \
	../board_media/user_source/hdl_source/SD/bmp_dec.v \
	../board_media/user_source/hdl_source/SD/wav_reader.v \
	../board_media/user_source/hdl_source/media_frame_format.v \
	../board_media/user_source/hdl_source/media_image_source.v
build_media_sd_image_source/sim_media_sd_image_source: vsrc/tb_media_sd_image_source.sv vsrc/sd_native_card_model.sv $(SD_IMAGE_SOURCE_RTL)
	$(VERILATOR) --binary --build-jobs 4 --timing -Wno-fatal -Wno-WIDTH -Wno-UNUSEDSIGNAL -Wno-BLKSEQ \
	  --top-module tb_media_sd_image_source $^ --Mdir build_media_sd_image_source -o sim_media_sd_image_source

media-sd-image-source: build_media_sd_image_source/sim_media_sd_image_source
	python3 diagnostics/export_card_pcm.py
	./build_media_sd_image_source/sim_media_sd_image_source +CARD=../img/card_user_real.img +CARD_FULL_IMAGE=1

# Keep the historical parser untouched as the cycle-accurate reference.
build_wav_reader_compact/wav_reader_reference.v: vsrc/wav_reader.v
	mkdir -p build_wav_reader_compact
	python3 -c "from pathlib import Path; Path('$@').write_text(Path('$<').read_text().replace('module wav_reader (', 'module wav_reader_reference (', 1))"

build_wav_reader_compact/sim_wav_reader_compact: vsrc/tb_wav_reader_compact.sv \
	../board_media/user_source/hdl_source/SD/wav_reader.v build_wav_reader_compact/wav_reader_reference.v
	$(VERILATOR) --binary --build-jobs 4 --timing --unroll-count 1 -Wno-fatal -Wno-WIDTH \
	  --top-module tb_wav_reader_compact $^ --Mdir build_wav_reader_compact -o sim_wav_reader_compact

.PHONY: wav-reader-unit
wav-reader-unit: build_wav_reader_compact/sim_wav_reader_compact
	./build_wav_reader_compact/sim_wav_reader_compact

build_media_uart_arbiter/sim_media_uart_arbiter: vsrc/tb_media_uart_arbiter.sv ../board_media/user_source/hdl_source/media_uart_arbiter.v
	$(VERILATOR) --binary --timing -Wno-fatal -Wno-WIDTH --top-module tb_media_uart_arbiter $^ --Mdir build_media_uart_arbiter -o sim_media_uart_arbiter

media-uart-arbiter: build_media_uart_arbiter/sim_media_uart_arbiter
	./build_media_uart_arbiter/sim_media_uart_arbiter

build_media_bt_control/sim_media_bt_control: vsrc/tb_media_bt_control.sv \
	../board_media/user_source/hdl_source/uart_link.v \
	../board_media/user_source/hdl_source/media_uart_arbiter.v \
	../board_media/user_source/hdl_source/media_control_core.v \
	../board_media/user_source/hdl_source/subtitle_cmd.v
	$(VERILATOR) --binary --build-jobs 4 --timing -Wno-fatal -Wno-WIDTH -Wno-UNUSEDSIGNAL \
	  --top-module tb_media_bt_control $^ --Mdir build_media_bt_control -o sim_media_bt_control

bt-uart-unit: build_media_uart_arbiter/sim_media_uart_arbiter build_media_bt_control/sim_media_bt_control
	./build_media_uart_arbiter/sim_media_uart_arbiter
	./build_media_bt_control/sim_media_bt_control



.PHONY: media-protocol media-writer media-control media-tx media-audio-playback media-display-path media-image-tx media-route media-command media-reply media-subtitle-roundtrip media-eth-subtitle-rx ctrlset
media-protocol:
	$(VERILATOR) --binary --timing --top-module tb_media_protocol_rx vsrc/tb_media_protocol_rx.sv ../board_display/user_source/hdl_source/ETH/media_protocol_rx.v --Mdir build_media_protocol -o sim_media_protocol_rx
	./build_media_protocol/sim_media_protocol_rx
media-writer:
	$(VERILATOR) --binary --timing --top-module tb_media_transaction_writer vsrc/tb_media_transaction_writer.sv ../board_display/user_source/hdl_source/ETH/media_transaction_writer.v ../board_display/user_source/hdl_source/ETH/eth_front.v --Mdir build_media_writer -o sim_media_transaction_writer
	./build_media_writer/sim_media_transaction_writer
media-control:
	$(VERILATOR) --binary --timing --top-module tb_media_display_control_rx vsrc/tb_media_display_control_rx.sv ../board_display/user_source/hdl_source/ETH/media_display_control_rx.v --Mdir build_media_control -o sim_media_display_control_rx
	./build_media_control/sim_media_display_control_rx
media-tx:
	$(VERILATOR) --binary --timing --top-module tb_media_display_tx vsrc/tb_media_display_tx.sv ../board_display/user_source/hdl_source/ETH/media_display_tx.v --Mdir build_media_tx -o sim_media_display_tx
	./build_media_tx/sim_media_display_tx

# The media-side 1280x720 formatter, including black borders and sector/FIFO backpressure.
media-frame-format:
	$(VERILATOR) --binary --timing -Wno-fatal -Wno-WIDTH --top-module tb_media_frame_format vsrc/tb_media_frame_format.sv ../board_media/user_source/hdl_source/media_frame_format.v --Mdir build_media_frame_format -o sim_media_frame_format
	./build_media_frame_format/sim_media_frame_format

media-frame-pad:
	$(VERILATOR) --binary --timing -Wno-fatal -Wno-WIDTH --top-module tb_media_frame_pad vsrc/tb_media_frame_pad.sv ../board_display/user_source/hdl_source/ETH/media_frame_pad.v --Mdir build_media_frame_pad -o sim_media_frame_pad
	./build_media_frame_pad/sim_media_frame_pad

build_bmp_frame_format/sim_bmp_frame_format: vsrc/tb_bmp_frame_format.sv ../board_media/user_source/hdl_source/SD/bmp_dec.v ../board_media/user_source/hdl_source/media_frame_format.v
	$(VERILATOR) --binary --timing -Wno-fatal -Wno-WIDTH --top-module tb_bmp_frame_format $^ --Mdir build_bmp_frame_format -o sim_bmp_frame_format

media-bmp-format: build_bmp_frame_format/sim_bmp_frame_format
	./build_bmp_frame_format/sim_bmp_frame_format +BMP=../img/golden/IMG0.BMP
	./build_bmp_frame_format/sim_bmp_frame_format +BMP=../img/golden/IMG3.BMP
	./build_bmp_frame_format/sim_bmp_frame_format +BMP=../img/golden/IMG4.BMP
	./build_bmp_frame_format/sim_bmp_frame_format +BMP=../img/golden/IMG5.BMP
media-audio-playback:
	$(VERILATOR) --binary --timing --top-module tb_media_audio_playback vsrc/tb_media_audio_playback.sv ../board_display/user_source/hdl_source/SD/media_audio_playback.v --Mdir build_media_audio_playback -o sim_media_audio_playback
	./build_media_audio_playback/sim_media_audio_playback
media-display-path:
	$(VERILATOR) --binary --timing --top-module tb_media_display_path vsrc/tb_media_display_path.sv ../board_display/user_source/hdl_source/ETH/media_protocol_rx.v ../board_display/user_source/hdl_source/ETH/media_frame_pad.v ../board_display/user_source/hdl_source/ETH/media_transaction_writer.v ../board_display/user_source/hdl_source/ETH/media_display_tx.v ../board_display/user_source/hdl_source/ETH/media_tx_mux.v ../board_display/user_source/hdl_source/ETH/eth_front.v --Mdir build_media_display_path -o sim_media_display_path
	./build_media_display_path/sim_media_display_path

.PHONY: display-mux-lifetime
display-mux-lifetime:
	$(VERILATOR) --binary --timing -Wno-fatal -Wno-WIDTH --top-module tb_media_tx_mux_lifetime vsrc/tb_media_tx_mux_lifetime.sv ../board_display/user_source/hdl_source/ETH/media_tx_mux.v --Mdir build_display_mux_lifetime -o sim_display_mux_lifetime
	./build_display_mux_lifetime/sim_display_mux_lifetime

# Full native 1280x720 transaction: packet parser -> display-side padding ->
# SDRAM writer -> RESULT 0 / committed RESULT 2 response path.
build_media_display_full_frame/sim_media_display_full_frame: vsrc/tb_media_display_full_frame.sv \
	../board_display/user_source/hdl_source/ETH/media_protocol_rx.v \
	../board_display/user_source/hdl_source/ETH/media_frame_pad.v \
	../board_display/user_source/hdl_source/ETH/media_transaction_writer.v \
	../board_display/user_source/hdl_source/ETH/media_display_tx.v \
	../board_display/user_source/hdl_source/ETH/eth_front.v
	$(VERILATOR) --binary --build-jobs 4 --timing -Wno-fatal -Wno-WIDTH --top-module tb_media_display_full_frame $^ --Mdir build_media_display_full_frame -o sim_media_display_full_frame

build_media_display_narrow_frame/sim_media_display_narrow_frame: vsrc/tb_media_display_full_frame.sv \
	../board_display/user_source/hdl_source/ETH/media_protocol_rx.v \
	../board_display/user_source/hdl_source/ETH/media_frame_pad.v \
	../board_display/user_source/hdl_source/ETH/media_transaction_writer.v \
	../board_display/user_source/hdl_source/ETH/media_display_tx.v \
	../board_display/user_source/hdl_source/ETH/eth_front.v
	$(VERILATOR) --binary --build-jobs 4 --timing -Wno-fatal -Wno-WIDTH --top-module tb_media_display_full_frame -GIMAGE_WIDTH=504 -GIMAGE_HEIGHT=720 -GTOTAL_WORDS=181440 $^ --Mdir build_media_display_narrow_frame -o sim_media_display_narrow_frame

.PHONY: media-display-full-frame
media-display-full-frame: build_media_display_full_frame/sim_media_display_full_frame build_media_display_narrow_frame/sim_media_display_narrow_frame
	./build_media_display_full_frame/sim_media_display_full_frame
	./build_media_display_narrow_frame/sim_media_display_narrow_frame

build_media_pair_504/sim_media_pair_504: vsrc/tb_media_pair_504.sv \
	../board_media/user_source/hdl_source/media_image_tx.v \
	../board_display/user_source/hdl_source/ETH/media_protocol_rx.v \
	../board_display/user_source/hdl_source/ETH/media_frame_pad.v \
	../board_display/user_source/hdl_source/ETH/media_transaction_writer.v \
	../board_display/user_source/hdl_source/ETH/media_display_tx.v \
	../board_display/user_source/hdl_source/ETH/eth_front.v \
	../board_display/user_source/hdl_source/SD/frame_read_write.v \
	../board_display/user_source/hdl_source/SD/frame_fifo_read.v \
	../board_display/user_source/hdl_source/SD/frame_fifo_write.v \
	../board_display/user_source/hdl_source/IP/afifo_16_32_256.v \
	../board_display/user_source/hdl_source/IP/afifo_32_16_256.v
	$(VERILATOR) --binary --build-jobs 4 --timing -Wno-fatal -Wno-WIDTH --top-module tb_media_pair_504 $^ --Mdir build_media_pair_504 -o sim_media_pair_504

.PHONY: media-pair-504
media-pair-504: build_media_pair_504/sim_media_pair_504
	./build_media_pair_504/sim_media_pair_504

build_media_pair_bmp0/sim_media_pair_bmp0: vsrc/tb_media_pair_504.sv ../board_media/user_source/hdl_source/media_image_tx.v ../board_display/user_source/hdl_source/ETH/media_protocol_rx.v ../board_display/user_source/hdl_source/ETH/media_frame_pad.v ../board_display/user_source/hdl_source/ETH/media_transaction_writer.v ../board_display/user_source/hdl_source/ETH/media_display_tx.v ../board_display/user_source/hdl_source/ETH/eth_front.v ../board_display/user_source/hdl_source/SD/frame_read_write.v ../board_display/user_source/hdl_source/SD/frame_fifo_read.v ../board_display/user_source/hdl_source/SD/frame_fifo_write.v ../board_display/user_source/hdl_source/IP/afifo_16_32_256.v ../board_display/user_source/hdl_source/IP/afifo_32_16_256.v
	$(VERILATOR) --binary --build-jobs 4 --timing -Wno-fatal -Wno-WIDTH --top-module tb_media_pair_504 -GIMAGE_WIDTH=1280 -GIMAGE_HEIGHT=720 $^ --Mdir build_media_pair_bmp0 -o sim_media_pair_bmp0

.PHONY: media-pair-bmp0
media-pair-bmp0: build_media_pair_bmp0/sim_media_pair_bmp0
	./build_media_pair_bmp0/sim_media_pair_bmp0 +BMP=../img/golden/IMG0.BMP

.PHONY: display-digest
display-digest:
	$(VERILATOR) --binary --timing -Wno-fatal -Wno-WIDTH --top-module tb_display_frame_digest vsrc/tb_display_frame_digest.sv diagnostics/display_frame_digest.v --Mdir build_display_digest -o sim_display_digest
	./build_display_digest/sim_display_digest

.PHONY: view-geometry
view-geometry:
	$(VERILATOR) --binary --timing -Wno-fatal -Wno-WIDTH --top-module tb_view_scale_geometry vsrc/tb_view_scale_geometry.sv ../board_display/user_source/hdl_source/ETH/view_scale_geometry.v --Mdir build_view_geometry -o sim_view_geometry
	./build_view_geometry/sim_view_geometry

.PHONY: view-bilinear
view-bilinear:
	$(VERILATOR) --binary --build-jobs 4 --timing -Wno-fatal -Wno-WIDTH --top-module tb_view_bilinear_shrink vsrc/tb_view_bilinear_shrink.sv ../board_display/user_source/hdl_source/ETH/view_scale_geometry.v ../board_display/user_source/hdl_source/ETH/view_bilinear_shrink.v --Mdir build_view_bilinear -o sim_view_bilinear
	./build_view_bilinear/sim_view_bilinear

.PHONY: view-scan-address
view-scan-address:
	$(VERILATOR) --binary --build-jobs 4 --timing -Wno-fatal -Wno-WIDTH --top-module tb_view_scan_address vsrc/tb_view_scan_address.sv ../board_display/user_source/hdl_source/ETH/view_scan_address.v --Mdir build_view_scan_address -o sim_view_scan_address
	./build_view_scan_address/sim_view_scan_address

.PHONY: view-video-config
view-video-config:
	$(VERILATOR) --binary --build-jobs 4 --timing -Wno-fatal -Wno-WIDTH --top-module tb_view_video_config vsrc/tb_view_video_config.sv ../board_display/user_source/hdl_source/ETH/view_video_config.v --Mdir build_view_video_config -o sim_view_video_config
	./build_view_video_config/sim_view_video_config

.PHONY: view-write-address
view-write-address:
	$(VERILATOR) --binary --build-jobs 4 --timing -Wno-fatal -Wno-WIDTH --top-module tb_view_write_address vsrc/tb_view_write_address.sv ../board_display/user_source/hdl_source/ETH/view_write_address.v --Mdir build_view_write_address -o sim_view_write_address
	./build_view_write_address/sim_view_write_address

.PHONY: view-framepath
view-framepath:
	$(VERILATOR) --binary --build-jobs 4 --timing -Wno-fatal -Wno-WIDTH --top-module tb_view_framepath vsrc/tb_view_framepath.sv $(TSD)/frame_read_write.v $(TSD)/frame_fifo_read.v $(TSD)/frame_fifo_write.v ../board_display/user_source/hdl_source/ETH/view_scan_address.v ../board_display/user_source/hdl_source/ETH/view_write_address.v ../board_display/user_source/hdl_source/IP/afifo_16_32_256.v ../board_display/user_source/hdl_source/IP/afifo_32_16_256.v --Mdir build_view_framepath -o sim_view_framepath
	./build_view_framepath/sim_view_framepath

.PHONY: view-session
view-session:
	$(VERILATOR) --binary --build-jobs 4 --timing -Wno-fatal -Wno-WIDTH --top-module tb_view_session_manager vsrc/tb_view_session_manager.sv ../board_display/user_source/hdl_source/ETH/view_session_manager.v ../board_display/user_source/hdl_source/SD/transition_ctrl.v --Mdir build_view_session -o sim_view_session
	./build_view_session/sim_view_session

.PHONY: view-control-path
view-control-path:
	$(VERILATOR) --binary --build-jobs 4 --timing -Wno-fatal -Wno-WIDTH --top-module tb_view_control_path vsrc/tb_view_control_path.sv ../board_media/user_source/hdl_source/media_view_scheduler.v ../board_display/user_source/hdl_source/ETH/view_session_manager.v ../board_display/user_source/hdl_source/ETH/view_protocol_rx.v ../board_display/user_source/hdl_source/ETH/media_display_tx.v --Mdir build_view_control_path -o sim_view_control_path
	./build_view_control_path/sim_view_control_path

.PHONY: view-usb
view-usb:
	$(VERILATOR) --binary --build-jobs 4 --timing -Wno-fatal -Wno-WIDTH --top-module tb_media_usb_view_tx vsrc/tb_media_usb_view_tx.sv ../board_media/user_source/hdl_source/media_usb_view_tx.v ../board_media/user_source/hdl_source/uart_link.v --Mdir build_view_usb -o sim_view_usb
	./build_view_usb/sim_view_usb

.PHONY: view-image-pipeline
view-image-pipeline:
	$(VERILATOR) --binary --build-jobs 4 --timing -Wno-fatal -Wno-WIDTH --top-module tb_view_bilinear_shrink -GPIPELINE=1 vsrc/tb_view_bilinear_shrink.sv ../board_display/user_source/hdl_source/ETH/view_image_pipeline.v ../board_display/user_source/hdl_source/ETH/view_bilinear_shrink.v ../board_display/user_source/hdl_source/ETH/view_scale_geometry.v ../board_display/user_source/hdl_source/ETH/media_frame_pad.v --Mdir build_view_image_pipeline -o sim_view_image_pipeline
	./build_view_image_pipeline/sim_view_image_pipeline

.PHONY: view-image-jobs
view-image-jobs:
	$(VERILATOR) --binary --build-jobs 4 --timing -Wno-fatal -Wno-WIDTH --top-module tb_view_image_jobs vsrc/tb_view_image_jobs.sv ../board_media/user_source/hdl_source/media_image_tx.v --Mdir build_view_image_jobs -o sim_view_image_jobs
	./build_view_image_jobs/sim_view_image_jobs

.PHONY: view-commands
view-commands:
	$(VERILATOR) --binary --build-jobs 4 --timing -Wno-fatal -Wno-WIDTH --top-module tb_view_commands vsrc/tb_view_commands.sv ../board_media/user_source/hdl_source/media_control_core.v ../board_media/user_source/hdl_source/subtitle_cmd.v --Mdir build_view_commands -o sim_view_commands
	./build_view_commands/sim_view_commands

.PHONY: display-levels
display-levels:
	$(VERILATOR) --binary --build-jobs 4 --timing -Wno-fatal -Wno-WIDTH --top-module tb_display_levels_rgb vsrc/tb_display_levels_rgb.sv $(TSD)/display_levels_rgb.v --Mdir build_display_levels -o sim_display_levels
	./build_display_levels/sim_display_levels
media-image-tx:
	$(VERILATOR) --binary --timing -Wno-fatal -Wno-WIDTH --top-module tb_media_image_tx_flags vsrc/tb_media_image_tx_flags.sv ../board_media/user_source/hdl_source/media_image_tx.v --Mdir build_media_image_tx_flags -o sim_media_image_tx_flags
	./build_media_image_tx_flags/sim_media_image_tx_flags
media-route:
	$(VERILATOR) --binary --timing -Wno-fatal -Wno-WIDTH --top-module tb_media_udp_route ../board_media/sim/tb_media_udp_route.sv ../board_media/user_source/hdl_source/media_image_tx.v ../board_media/user_source/hdl_source/media_udp_route.v --Mdir build_media_route -o sim_media_udp_route
	./build_media_route/sim_media_udp_route

media-tx-gap:
	$(VERILATOR) --binary --timing -Wno-fatal -Wno-WIDTH --top-module tb_media_image_tx_gap vsrc/tb_media_image_tx_gap.sv ../board_media/user_source/hdl_source/media_image_tx.v --Mdir build_media_image_tx_gap -o sim_media_image_tx_gap
	./build_media_image_tx_gap/sim_media_image_tx_gap

media-packet-drain:
	$(VERILATOR) --binary --timing -Wno-fatal -Wno-WIDTH --top-module tb_media_packet_drain vsrc/tb_media_packet_drain.sv ../board_display/user_source/hdl_source/ETH/media_protocol_rx.v --Mdir build_media_packet_drain -o sim_media_packet_drain
	./build_media_packet_drain/sim_media_packet_drain

media-single-step:
	$(VERILATOR) --binary --timing -Wno-fatal -Wno-WIDTH --top-module tb_media_single_step vsrc/tb_media_single_step.sv ../board_media/user_source/hdl_source/media_control_core.v ../board_media/user_source/hdl_source/subtitle_cmd.v ../board_media/user_source/hdl_source/media_image_tx.v --Mdir build_media_single_step -o sim_media_single_step
	./build_media_single_step/sim_media_single_step

media-button:
	$(VERILATOR) --binary --timing -Wno-fatal -Wno-WIDTH --top-module tb_media_button_debounce vsrc/tb_media_button_debounce.sv ../board_media/user_source/hdl_source/media_button_debounce.v --Mdir build_media_button -o sim_media_button
	./build_media_button/sim_media_button
media-command:
	$(VERILATOR) --binary --timing -Wno-fatal -Wno-WIDTH --top-module tb_media_control_snapshot vsrc/tb_media_control_snapshot.sv ../board_media/user_source/hdl_source/media_control_core.v ../board_media/user_source/hdl_source/subtitle_cmd.v --Mdir build_media_command -o sim_media_control_snapshot
	./build_media_command/sim_media_control_snapshot
media-reply:
	$(VERILATOR) --binary --timing -Wno-fatal -Wno-WIDTH --top-module tb_media_control_reply_parse vsrc/tb_media_control_reply_parse.sv ../board_media/user_source/hdl_source/media_control_core.v ../board_media/user_source/hdl_source/subtitle_cmd.v --Mdir build_media_reply -o sim_media_control_reply_parse
	./build_media_reply/sim_media_control_reply_parse
media-subtitle-roundtrip:
	$(VERILATOR) --binary --timing -Wno-fatal -Wno-WIDTH --top-module tb_media_subtitle_roundtrip vsrc/tb_media_subtitle_roundtrip.sv ../board_media/user_source/hdl_source/media_control_core.v ../board_media/user_source/hdl_source/subtitle_cmd.v ../board_display/user_source/hdl_source/ETH/media_display_control_rx.v ../board_display/user_source/hdl_source/SD/subtitle_store.v --Mdir build_media_subtitle_roundtrip -o sim_media_subtitle_roundtrip
	./build_media_subtitle_roundtrip/sim_media_subtitle_roundtrip
media-eth-subtitle-rx:
	$(VERILATOR) --binary --timing -Wno-fatal -Wno-WIDTH --top-module tb_media_eth_subtitle_rx vsrc/tb_media_eth_subtitle_rx.sv ../board_media/user_source/hdl_source/ETH/eth_front.v ../board_media/user_source/hdl_source/media_control_core.v ../board_media/user_source/hdl_source/subtitle_cmd.v --Mdir build_media_eth_subtitle_rx -o sim_media_eth_subtitle_rx
	./build_media_eth_subtitle_rx/sim_media_eth_subtitle_rx

.PHONY: touch-command-path cv-unit

.PHONY: display-udp-lite
display-udp-lite:
	$(VERILATOR) --binary --build-jobs 4 --timing -Wno-fatal -Wno-WIDTH --top-module tb_display_udp_lite vsrc/tb_display_udp_lite.sv ../board_display/user_source/hdl_source/ETH/display_udp_lite.v ../board_display/user_source/hdl_source/ETH/media_tx_mux.v --Mdir build_display_udp_lite -o sim_display_udp_lite
	./build_display_udp_lite/sim_display_udp_lite

# HDMI-only CV pixel effects: all modes share a deterministic raster stimulus.
build_cv_pixel_effects/sim_cv_pixel_effects: vsrc/tb_cv_pixel_effects.sv $(TSD)/cv_pixel_effects.v
	$(VERILATOR) --binary --timing -Wno-fatal -Wno-WIDTH --top-module tb_cv_pixel_effects $^ --Mdir build_cv_pixel_effects -o sim_cv_pixel_effects

cv-unit: build_cv_pixel_effects/sim_cv_pixel_effects snow-unit
	./build_cv_pixel_effects/sim_cv_pixel_effects

touch-command-path:
	$(VERILATOR) --binary --timing -Wno-fatal -Wno-WIDTH --top-module tb_touch_command_path vsrc/tb_touch_command_path.sv ../board_display/user_source/hdl_source/ETH/media_display_tx.v ../board_media/user_source/hdl_source/ETH/eth_front.v --Mdir build_touch_command_path -o sim_touch_command_path
	./build_touch_command_path/sim_touch_command_path
ctrlset:
	$(VERILATOR) --binary --timing --top-module tb_ctrl_core_set vsrc/tb_ctrl_core_set.sv ../board_display/user_source/hdl_source/SD/ctrl_core.v --Mdir build_ctrlset -o sim_ctrl_core_set
	./build_ctrlset/sim_ctrl_core_set


# Single CDC path: parser/padder/writer in UDP clock, final SDRAM FIFO crosses.
.PHONY: view-direct-writer view-direct-full-frame view-direct-framepath
view-direct-writer:
	$(VERILATOR) --binary --build-jobs 4 --timing -Wno-fatal -Wno-WIDTH --top-module tb_media_transaction_writer -GDIRECT_STREAM=1 vsrc/tb_media_transaction_writer.sv ../board_display/user_source/hdl_source/ETH/media_transaction_writer.v ../board_display/user_source/hdl_source/ETH/eth_front.v --Mdir build_view_direct_writer -o sim_direct_writer
	./build_view_direct_writer/sim_direct_writer
	$(VERILATOR) --binary --build-jobs 4 --timing -Wno-fatal -Wno-WIDTH --top-module tb_media_display_path -GDIRECT_STREAM=1 vsrc/tb_media_display_path.sv ../board_display/user_source/hdl_source/ETH/media_protocol_rx.v ../board_display/user_source/hdl_source/ETH/media_frame_pad.v ../board_display/user_source/hdl_source/ETH/media_transaction_writer.v ../board_display/user_source/hdl_source/ETH/media_display_tx.v ../board_display/user_source/hdl_source/ETH/media_tx_mux.v ../board_display/user_source/hdl_source/ETH/eth_front.v --Mdir build_view_direct_path -o sim_direct_path
	./build_view_direct_path/sim_direct_path
view-direct-full-frame:
	$(VERILATOR) --binary --build-jobs 4 --timing -Wno-fatal -Wno-WIDTH --top-module tb_media_display_full_frame -GDIRECT_STREAM=1 -GIMAGE_WIDTH=504 vsrc/tb_media_display_full_frame.sv ../board_display/user_source/hdl_source/ETH/media_protocol_rx.v ../board_display/user_source/hdl_source/ETH/media_frame_pad.v ../board_display/user_source/hdl_source/ETH/media_transaction_writer.v ../board_display/user_source/hdl_source/ETH/media_display_tx.v ../board_display/user_source/hdl_source/ETH/eth_front.v --Mdir build_view_direct_full -o sim_direct_full
	./build_view_direct_full/sim_direct_full
	$(VERILATOR) --binary --build-jobs 4 --timing -Wno-fatal -Wno-WIDTH --top-module tb_media_display_full_frame -GDIRECT_STREAM=1 vsrc/tb_media_display_full_frame.sv ../board_display/user_source/hdl_source/ETH/media_protocol_rx.v ../board_display/user_source/hdl_source/ETH/media_frame_pad.v ../board_display/user_source/hdl_source/ETH/media_transaction_writer.v ../board_display/user_source/hdl_source/ETH/media_display_tx.v ../board_display/user_source/hdl_source/ETH/eth_front.v --Mdir build_view_direct_full_hd -o sim_direct_full_hd
	./build_view_direct_full_hd/sim_direct_full_hd
view-direct-framepath:
	$(VERILATOR) --binary --build-jobs 4 --timing -Wno-fatal -Wno-WIDTH --top-module tb_view_framepath -GUSE_STREAM_CLOCK=1 vsrc/tb_view_framepath.sv $(TSD)/frame_read_write.v $(TSD)/frame_fifo_read.v $(TSD)/frame_fifo_write.v ../board_display/user_source/hdl_source/ETH/view_scan_address.v ../board_display/user_source/hdl_source/ETH/view_write_address.v ../board_display/user_source/hdl_source/IP/afifo_16_32_256.v ../board_display/user_source/hdl_source/IP/afifo_32_16_256.v --Mdir build_view_direct_framepath -o sim_direct_framepath
	./build_view_direct_framepath/sim_direct_framepath

.PHONY: snow-unit
build_snow_field/sim_snow_field: vsrc/tb_snow_field.sv $(TSD)/cv_pixel_effects.v
	$(VERILATOR) --binary --timing -Wno-fatal -Wno-WIDTH --unroll-count 1 --top-module tb_snow_field $^ --Mdir build_snow_field -o sim_snow_field
snow-unit: build_snow_field/sim_snow_field
	./build_snow_field/sim_snow_field

# Video integration: drain-before-switch ownership and original WAV pause.
.PHONY: video-memory-lease media-audio-pause
video-memory-lease:
	$(VERILATOR) --binary --build-jobs 4 --timing -Wno-fatal -Wno-WIDTH --top-module tb_video_memory_lease vsrc/tb_video_memory_lease.sv ../board_display/user_source/hdl_source/ETH/video_memory_lease.v --Mdir build_video_memory_lease -o sim_video_memory_lease
	./build_video_memory_lease/sim_video_memory_lease

media-audio-pause:
	$(VERILATOR) --binary --build-jobs 4 --timing -Wno-fatal -Wno-WIDTH --top-module tb_media_audio_pause vsrc/tb_media_audio_pause.sv ../board_display/user_source/hdl_source/SD/media_audio_playback.v --Mdir build_media_audio_pause -o sim_media_audio_pause
	./build_media_audio_pause/sim_media_audio_pause

.PHONY: audio-demux
audio-demux:
	$(VERILATOR) --binary --build-jobs 4 --timing -Wno-fatal -Wno-WIDTH --top-module tb_audio_demux vsrc/tb_audio_demux.sv ../board_display/user_source/hdl_source/ETH/direct_video_packet_demux.v --Mdir build_audio_demux -o sim_audio_demux
	./build_audio_demux/sim_audio_demux


.PHONY: video-hybrid-integration
video-hybrid-integration:
	$(VERILATOR) --binary --build-jobs 4 --timing -Wno-fatal -Wno-WIDTH --top-module tb_video_hybrid_pipeline -GW=720 -GH=360 -GWIN=512 -GHD=4 -GHT=1650 -GVT=750 -GFRAMES=3 -GSTALL_NS=3000000 vsrc/tb_video_hybrid_pipeline.sv ../board_display/user_source/hdl_source/ETH/video_hybrid_pipeline.v ../board_display/user_source/hdl_source/ETH/video_row_tags.v ../board_display/user_source/hdl_source/ETH/video_head_cache.v ../board_display/user_source/hdl_source/ETH/video_row_ingress.v ../board_display/user_source/hdl_source/ETH/video_sdram_port.v ../board_display/user_source/hdl_source/ETH/direct_video_bram_32k_16.v ../board_display/user_source/hdl_source/ETH/direct_video_bram_9k_16.v --Mdir build_video_hybrid_integration -o sim_video_hybrid_integration
	./build_video_hybrid_integration/sim_video_hybrid_integration


.PHONY: video-hybrid-integration-crc
video-hybrid-integration-crc:
	$(VERILATOR) --binary --build-jobs 4 --timing -Wno-fatal -Wno-WIDTH --top-module tb_video_hybrid_pipeline -GINJECT_CRC=1 vsrc/tb_video_hybrid_pipeline.sv ../board_display/user_source/hdl_source/ETH/video_hybrid_pipeline.v ../board_display/user_source/hdl_source/ETH/video_row_tags.v ../board_display/user_source/hdl_source/ETH/video_head_cache.v ../board_display/user_source/hdl_source/ETH/video_row_ingress.v ../board_display/user_source/hdl_source/ETH/video_sdram_port.v ../board_display/user_source/hdl_source/ETH/direct_video_bram_32k_16.v ../board_display/user_source/hdl_source/ETH/direct_video_bram_9k_16.v --Mdir build_video_hybrid_integration_crc -o sim_video_hybrid_integration_crc
	./build_video_hybrid_integration_crc/sim_video_hybrid_integration_crc


.PHONY: video-hybrid-integration-tag
video-hybrid-integration-tag:
	$(VERILATOR) --binary --build-jobs 4 --timing -Wno-fatal -Wno-WIDTH --top-module tb_video_hybrid_pipeline -GINJECT_TAG=1 vsrc/tb_video_hybrid_pipeline.sv ../board_display/user_source/hdl_source/ETH/video_hybrid_pipeline.v ../board_display/user_source/hdl_source/ETH/video_row_tags.v ../board_display/user_source/hdl_source/ETH/video_head_cache.v ../board_display/user_source/hdl_source/ETH/video_row_ingress.v ../board_display/user_source/hdl_source/ETH/video_sdram_port.v ../board_display/user_source/hdl_source/ETH/direct_video_bram_32k_16.v ../board_display/user_source/hdl_source/ETH/direct_video_bram_9k_16.v --Mdir build_video_hybrid_integration_tag -o sim_video_hybrid_integration_tag
	./build_video_hybrid_integration_tag/sim_video_hybrid_integration_tag


.PHONY: video-audio-integration
video-audio-integration:
	$(VERILATOR) --binary --build-jobs 4 --timing -Wno-fatal -Wno-WIDTH --top-module tb_direct_video_audio -GN=396 -GHALF=1562 -GDELAY=15 vsrc/tb_direct_video_audio.sv ../board_display/user_source/hdl_source/ETH/direct_video_audio.v ../board_display/user_source/hdl_source/ETH/direct_video_bram_9k_16.v --Mdir build_video_audio_integration -o sim_video_audio_integration
	./build_video_audio_integration/sim_video_audio_integration


.PHONY: video-health-feedback
video-health-feedback:
	$(VERILATOR) --binary --build-jobs 4 --timing -Wno-fatal -Wno-WIDTH --top-module tb_video_health_feedback vsrc/tb_video_health_feedback.sv ../board_display/user_source/hdl_source/ETH/direct_video_feedback_tx.v --Mdir build_video_health_feedback -o sim_video_health_feedback
	./build_video_health_feedback/sim_video_health_feedback

.PHONY: direct-video-parser
direct-video-parser:
	$(VERILATOR) --binary --build-jobs 4 --timing -Wno-fatal -Wno-WIDTH --top-module tb_direct_video_row_parser vsrc/tb_direct_video_row_parser.sv ../board_display/user_source/hdl_source/ETH/direct_video_row_parser.v --Mdir build_direct_video_parser -o sim_direct_video_parser
	./build_direct_video_parser/sim_direct_video_parser


.PHONY: direct-video-demux
direct-video-demux:
	$(VERILATOR) --binary --build-jobs 4 --timing -Wno-fatal -Wno-WIDTH --top-module tb_direct_video_packet_demux vsrc/tb_direct_video_packet_demux.sv ../board_display/user_source/hdl_source/ETH/direct_video_packet_demux.v --Mdir build_direct_video_demux -o sim_direct_video_demux
	./build_direct_video_demux/sim_direct_video_demux


.PHONY: direct-video-region
direct-video-region:
	$(VERILATOR) --binary --build-jobs 4 --timing -Wno-fatal --top-module tb_direct_video_region_mux vsrc/tb_direct_video_region_mux.sv ../board_display/user_source/hdl_source/ETH/direct_video_region_mux.v --Mdir build_direct_video_region -o sim_direct_video_region
	./build_direct_video_region/sim_direct_video_region


.PHONY: direct-video-feedback
direct-video-feedback:
	$(VERILATOR) --binary --build-jobs 4 --timing -Wno-fatal -Wno-WIDTH --top-module tb_direct_video_feedback_tx vsrc/tb_direct_video_feedback_tx.sv ../board_display/user_source/hdl_source/ETH/direct_video_feedback_tx.v --Mdir build_direct_video_feedback -o sim_direct_video_feedback
	./build_direct_video_feedback/sim_direct_video_feedback


.PHONY: video-hybrid-raster video-integration-unit
video-hybrid-raster:
	$(VERILATOR) --binary --build-jobs 4 --timing -Wno-fatal -Wno-WIDTH --top-module tb_video_hybrid_raster -GW=720 -GH=360 -GWIN=512 -GHD=4 -GHT=1650 -GVT=750 -GFRAMES=3 -GSTALL_NS=3000000 vsrc/tb_video_hybrid_raster.sv ../board_display/user_source/hdl_source/SD/video_delay.v ../board_display/user_source/hdl_source/ETH/video_hybrid_pipeline.v ../board_display/user_source/hdl_source/ETH/video_row_tags.v ../board_display/user_source/hdl_source/ETH/video_head_cache.v ../board_display/user_source/hdl_source/ETH/video_row_ingress.v ../board_display/user_source/hdl_source/ETH/video_sdram_port.v ../board_display/user_source/hdl_source/ETH/direct_video_region_mux.v ../board_display/user_source/hdl_source/ETH/direct_video_bram_32k_16.v ../board_display/user_source/hdl_source/ETH/direct_video_bram_9k_16.v --Mdir build_video_product_raster -o sim_video_product_raster
	./build_video_product_raster/sim_video_product_raster

video-integration-unit: video-memory-lease media-audio-pause media-audio-playback view-session view-control-path audio-demux video-audio-integration video-health-feedback

.PHONY: video-ready-delay hdmi-symbols
video-ready-delay:
	$(VERILATOR) --binary --build-jobs 4 --timing -Wno-fatal -Wno-WIDTH --top-module tb_video_hybrid_pipeline -GW=720 -GH=360 -GWIN=512 -GHD=4 -GHT=1650 -GVT=750 -GFRAMES=3 -GWAIT_READY=1 vsrc/tb_video_hybrid_pipeline.sv ../board_display/user_source/hdl_source/ETH/video_hybrid_pipeline.v ../board_display/user_source/hdl_source/ETH/video_row_tags.v ../board_display/user_source/hdl_source/ETH/video_head_cache.v ../board_display/user_source/hdl_source/ETH/video_row_ingress.v ../board_display/user_source/hdl_source/ETH/video_sdram_port.v ../board_display/user_source/hdl_source/ETH/direct_video_bram_32k_16.v ../board_display/user_source/hdl_source/ETH/direct_video_bram_9k_16.v --Mdir build_video_ready_product -o sim_video_ready_product
	./build_video_ready_product/sim_video_ready_product

hdmi-symbols:
	$(VERILATOR) --binary --build-jobs 4 --timing -Wno-fatal -Wno-WIDTH --top-module tb_hdmi_phy_symbols vsrc/tb_hdmi_phy_symbols.sv ../board_display/user_source/hdl_source/hdmi_phy_warpper.v ../board_display/user_source/hdl_source/lane_lvds_10_1.v --Mdir build_hdmi_symbols -o sim_hdmi_symbols
	./build_hdmi_symbols/sim_hdmi_symbols

.PHONY: video-product-chain
video-product-chain:
	$(VERILATOR) --binary --build-jobs 4 --timing -Wno-fatal -Wno-WIDTH --top-module tb_video_hybrid_raster -GW=720 -GH=360 -GWIN=512 -GHD=4 -GHT=1650 -GVT=750 -GFRAMES=3 -GPRODUCT_CHAIN=1 -GSTALL_NS=3000000 vsrc/tb_video_hybrid_raster.sv ../board_display/user_source/hdl_source/SD/cv_pixel_effects.v ../board_display/user_source/hdl_source/SD/video_delay.v ../board_display/user_source/hdl_source/ETH/video_hybrid_pipeline.v ../board_display/user_source/hdl_source/ETH/video_row_tags.v ../board_display/user_source/hdl_source/ETH/video_head_cache.v ../board_display/user_source/hdl_source/ETH/video_row_ingress.v ../board_display/user_source/hdl_source/ETH/video_sdram_port.v ../board_display/user_source/hdl_source/ETH/direct_video_region_mux.v ../board_display/user_source/hdl_source/ETH/direct_video_bram_32k_16.v ../board_display/user_source/hdl_source/ETH/direct_video_bram_9k_16.v --Mdir build_video_product_chain -o sim_video_product_chain
	./build_video_product_chain/sim_video_product_chain

.PHONY: video-port-address
video-port-address:
	$(VERILATOR) --binary --build-jobs 4 --timing -Wno-fatal -Wno-WIDTH --top-module tb_video_sdram_port -GWALK=1 -GBASE=921600 -GALT=1 vsrc/tb_video_sdram_port.sv vsrc/video_sdram_bist.v ../board_display/user_source/hdl_source/ETH/video_sdram_port.v --Mdir build_video_port_address2 -o sim_video_port_address
	./build_video_port_address2/sim_video_port_address
	$(VERILATOR) --binary --build-jobs 4 --timing -Wno-fatal -Wno-WIDTH --top-module tb_video_sdram_port -GWALK=1 -GBASE=1509376 -GALT=1 vsrc/tb_video_sdram_port.sv vsrc/video_sdram_bist.v ../board_display/user_source/hdl_source/ETH/video_sdram_port.v --Mdir build_video_port_address3 -o sim_video_port_address
	./build_video_port_address3/sim_video_port_address

.PHONY: video-network-bridge video-ipv4-sum
video-network-bridge:
	$(VERILATOR) --binary --build-jobs 4 --timing -Wno-fatal -Wno-WIDTH --top-module tb_video_legacy_bridge vsrc/tb_video_legacy_bridge.sv ../board_display/user_source/hdl_source/ETH/display_udp_lite.v ../board_display/user_source/hdl_source/ETH/direct_video_packet_demux.v ../board_display/user_source/hdl_source/ETH/media_protocol_rx.v ../board_display/user_source/hdl_source/ETH/media_display_tx.v ../board_display/user_source/hdl_source/ETH/direct_video_feedback_tx.v ../board_display/user_source/hdl_source/ETH/media_tx_mux.v --Mdir build_video_legacy_bridge -o sim_video_legacy_bridge
	./build_video_legacy_bridge/sim_video_legacy_bridge

video-ipv4-sum:
	$(VERILATOR) --binary --build-jobs 4 --timing -Wno-fatal -Wno-WIDTH --top-module tb_video_ipv4_sum vsrc/tb_video_ipv4_sum.sv ../board_display/user_source/hdl_source/ETH/display_udp_lite.v --Mdir build_video_ipv4_sum -o sim_video_ipv4_sum
	./build_video_ipv4_sum/sim_video_ipv4_sum

.PHONY: video-stage1-controls
video-stage1-controls:
	$(VERILATOR) --binary --build-jobs 4 --timing -Wno-fatal -Wno-WIDTH --top-module tb_video_stage1_controls vsrc/tb_video_stage1_controls.sv ../board_display/user_source/hdl_source/ETH/media_display_control_rx.v --Mdir build_video_stage1_controls -o sim_video_stage1_controls
	./build_video_stage1_controls/sim_video_stage1_controls
