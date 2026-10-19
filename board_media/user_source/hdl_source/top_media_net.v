`timescale 1ns/1ps
// Media image stage: canonical frame production and PC receiver validation.
// Legacy D raw tap remains a separate debugging path; no media-board SDRAM.
module top (
    input wire clk,rst_n,
    input wire key1,key2,key3,
    input wire uart_rx,output wire uart_tx,
    input wire eth_rgmii_rxc,eth_rgmii_rx_ctl,input wire [3:0] eth_rgmii_rxd,
    output wire eth_rgmii_txc,eth_rgmii_tx_ctl,output wire [3:0] eth_rgmii_txd,
    output wire eth_phy_reset,sd_ncs,sd_dclk,sd_mosi,input wire sd_miso
);
    reg boot_rst=1;
    always @(posedge clk) if(rst_n)boot_rst<=0;
    wire [7:0] cmd;wire cmd_pending,cmd_ack_t,tx_tog;wire [63:0] tx_pkt;
    wire [15:0] tx_type,tx_payload_len;wire tx_done_tog;
    wire app_clk,app_rst;wire [7:0] rx_byte;wire rx_valid;wire [3:0] media_stack_status;
    wire media_request,media_valid,media_ack;wire [7:0] media_data;wire [15:0] media_length;
    wire sd_init_done,fat_mounted,fat_error,source_busy,source_error;
    wire [5:0] file_count,bmp_count,wav_count,first_bmp;
    wire [191:0] bmp_next,bmp_prev;wire [7:0] fat_state;
    wire debug_req,unused_next,unused_prev,tap_val,tap_end;wire [31:0] tap_word;
    wire prepared_toggle,done_toggle,frame_clear;
    wire audio_prepared_toggle,audio_done_toggle,audio_source_error,source_has_wav;
    wire [31:0] audio_sample_count;
    wire [4:0] source_wav_index,audio_file_index;
    wire audio_start_toggle;
    wire [11:0] image_width,image_height;
    wire [31:0] frame_data;wire frame_valid,frame_ready;
    wire [9:0] production_available;
    reg [1:0] audio_pause_sync;
    wire start_toggle;wire [4:0] source_index,committed_index;
    wire tx_busy,committed_valid;wire [7:0] tx_error,source_status;wire [3:0] tx_state;
    wire committed_wav;reg [7:0] fat_state_s0,fat_state_s1;reg fat_error_s0,fat_error_s1;
    wire auto_on;wire [3:0] auto_period_s,auto_next_pulse;
    wire uart_cmd_valid;wire [7:0] uart_cmd;wire uart_tx_ready,uart_tx_req;wire [63:0] uart_tx_pkt;
    wire control_debug_request;reg [1:0] control_debug_sync;
    wire local_next_pulse,local_prev_pulse;
    wire key_next_press,key_auto_press,key_prev_press;
    reg key_next_toggle,key_auto_toggle,key_prev_toggle;
    reg [2:0] key_next_cdc,key_auto_cdc,key_prev_cdc;
    reg key_next_cdc_d,key_auto_cdc_d,key_prev_cdc_d;
    wire key_next_app_pulse=key_next_cdc[2]^key_next_cdc_d;
    wire key_auto_app_pulse=key_auto_cdc[2]^key_auto_cdc_d;
    wire key_prev_app_pulse=key_prev_cdc[2]^key_prev_cdc_d;
    reg [23:0] diag_s0,diag_s1;
    media_button_debounce u_key_next(.clk(clk),.rst(boot_rst),.button_n(key1),.press_pulse(key_next_press));
    media_button_debounce u_key_auto(.clk(clk),.rst(boot_rst),.button_n(key2),.press_pulse(key_auto_press));
    media_button_debounce u_key_prev(.clk(clk),.rst(boot_rst),.button_n(key3),.press_pulse(key_prev_press));
    always @(posedge clk) begin
        if(boot_rst)begin key_next_toggle<=0;key_auto_toggle<=0;key_prev_toggle<=0;end
        else begin
            if(key_next_press)key_next_toggle<=~key_next_toggle;
            if(key_auto_press)key_auto_toggle<=~key_auto_toggle;
            if(key_prev_press)key_prev_toggle<=~key_prev_toggle;
        end
    end
    always @(posedge app_clk) begin
        if(app_rst)begin key_next_cdc<=0;key_auto_cdc<=0;key_prev_cdc<=0;
            key_next_cdc_d<=0;key_auto_cdc_d<=0;key_prev_cdc_d<=0;end
        else begin
            key_next_cdc<={key_next_cdc[1:0],key_next_toggle};
            key_auto_cdc<={key_auto_cdc[1:0],key_auto_toggle};
            key_prev_cdc<={key_prev_cdc[1:0],key_prev_toggle};
            key_next_cdc_d<=key_next_cdc[2];key_auto_cdc_d<=key_auto_cdc[2];key_prev_cdc_d<=key_prev_cdc[2];
        end
    end
    always @(posedge clk) begin
        if(boot_rst) audio_pause_sync<=0;
        else audio_pause_sync<={audio_pause_sync[0],production_available>=10'd256};
    end
    always @(posedge clk) if(boot_rst)begin diag_s0<=0;diag_s1<=0;end
    else begin diag_s0<={source_status,tx_error,media_stack_status,tx_state};diag_s1<=diag_s0;end
    reg [2:0] start_sync;
    reg [4:0] source_index_s0,source_index_s1,committed_s0,committed_s1;
    reg [1:0] committed_valid_sync,tx_busy_sync;
    always @(posedge clk) begin
        if(boot_rst) begin
            source_index_s0<=0;source_index_s1<=0;committed_s0<=0;committed_s1<=0;
            committed_valid_sync<=0;tx_busy_sync<=0;
        end else begin
            source_index_s0<=source_index;source_index_s1<=source_index_s0;
            committed_s0<=committed_index;committed_s1<=committed_s0;
            committed_valid_sync<={committed_valid_sync[0],committed_valid};
            tx_busy_sync<={tx_busy_sync[0],tx_busy};
        end
    end
    always @(posedge clk) if(boot_rst)start_sync<=0;else start_sync<={start_sync[1:0],start_toggle};
    wire formal_start=start_sync[2]^start_sync[1];
    media_autoplay_timer u_autoplay_timer(
        .clk(app_clk),.rst(app_rst),.enable(auto_on),.busy(tx_busy),.committed_valid(committed_valid),
        .period_s(auto_period_s),.next_pulse(auto_next_pulse)
    );
    always @(posedge clk) begin
        if(boot_rst)control_debug_sync<=0;
        else control_debug_sync<={control_debug_sync[0],control_debug_request};
    end
    wire debug_launch=(debug_req || control_debug_sync[1]) && !tx_busy_sync[1] && !formal_start;
    wire [4:0] file_index=debug_launch ? (committed_valid_sync[1]?committed_s1:first_bmp[4:0]) : source_index_s1;
    media_image_source u_source (
        .clk(clk),.rst(boot_rst),.start(formal_start),.debug_start(debug_launch),.abort(1'b0),.file_index(file_index),
        .audio_start_toggle_async(audio_start_toggle),.audio_file_index_async(audio_file_index),
        .audio_pause(audio_pause_sync[1]),
        .SD_nCS(sd_ncs),.SD_DCLK(sd_dclk),.SD_MOSI(sd_mosi),.SD_MISO(sd_miso),
        .sd_init_done(sd_init_done),.fat_mounted(fat_mounted),.fat_error(fat_error),
        .file_count(file_count),.bmp_count(bmp_count),.wav_count(wav_count),.first_bmp(first_bmp),
        .bmp_next(bmp_next),.bmp_prev(bmp_prev),.fat_state(fat_state),.busy(source_busy),.error(source_error),
        .prepared_toggle(prepared_toggle),.done_toggle(done_toggle),.audio_prepared_toggle(audio_prepared_toggle),
        .audio_done_toggle(audio_done_toggle),.audio_sample_count(audio_sample_count),
        .audio_source_error(audio_source_error),.paired_wav_valid(source_has_wav),
        .paired_wav_index(source_wav_index),.frame_clear(frame_clear),
        .image_width(image_width),.image_height(image_height),.frame_data(frame_data),.frame_valid(frame_valid),
        .frame_ready(frame_ready),.source_status(source_status),.tap_val(tap_val),.tap_end(tap_end),.tap_word(tap_word)
    );
    reg [1:0] clear_sync,busy_sync,error_sync,prepared_sync,done_sync;
    reg [2:0] mounted_sync;
    // Playlist buses only change during mount. Two destination registers plus
    // a third mounted synchronizer stage keep lookups out of the CDC path.
    reg [5:0] first_s0,first_s1;
    reg [191:0] next_s0,next_s1,prev_s0,prev_s1;
    always @(posedge app_clk) begin
        if(app_rst)begin
            clear_sync<=3;mounted_sync<=0;busy_sync<=0;error_sync<=0;prepared_sync<=0;done_sync<=0;
            fat_state_s0<=0;fat_state_s1<=0;fat_error_s0<=0;fat_error_s1<=0;
            first_s0<=0;first_s1<=0;next_s0<=0;next_s1<=0;prev_s0<=0;prev_s1<=0;
        end else begin
            clear_sync<={clear_sync[0],frame_clear};mounted_sync<={mounted_sync[1:0],fat_mounted};
            fat_state_s0<=fat_state;fat_state_s1<=fat_state_s0;fat_error_s0<=fat_error;fat_error_s1<=fat_error_s0;
            first_s0<=first_bmp;first_s1<=first_s0;
            next_s0<=bmp_next;next_s1<=next_s0;prev_s0<=bmp_prev;prev_s1<=prev_s0;
            busy_sync<={busy_sync[0],source_busy};error_sync<={error_sync[0],source_error};
            prepared_sync<={prepared_sync[0],prepared_toggle};done_sync<={done_sync[0],done_toggle};
        end
    end
    wire production_full,production_empty,production_read;
    wire [31:0] production_data;
    assign frame_ready=!production_full;
    tap_afifo #(.AW(9),.DW(32)) u_production_fifo (
        .wr_clk(clk),.wr_rst(boot_rst || frame_clear),.wr_en(frame_valid && frame_ready),
        .wr_data(frame_data),.wr_full(production_full),
        .rd_clk(app_clk),.rd_rst(app_rst || clear_sync[1]),.rd_en(production_read),
        .rd_data(production_data),.rd_empty(production_empty),.rd_avail(production_available)
    );
    media_image_tx u_formal_tx (
        .clk(app_clk),.rst(app_rst),.mounted(mounted_sync[2]),.source_busy(busy_sync[1]),.source_error(error_sync[1]),
        .first_bmp(first_s1),.bmp_next(next_s1),.bmp_prev(prev_s1),.cmd(cmd),.cmd_pending(cmd_pending),.auto_next(auto_next_pulse),
        .local_next(local_next_pulse || key_next_app_pulse),.local_prev(local_prev_pulse || key_prev_app_pulse),
        .prepared_toggle(prepared_sync[1]),.done_toggle(done_sync[1]),.source_has_wav_async(source_has_wav),
        .source_wav_index_async(source_wav_index),.audio_prepared_toggle(audio_prepared_toggle),
        .audio_done_toggle(audio_done_toggle),.audio_sample_count_async(audio_sample_count),
        .audio_source_error_async(audio_source_error),
        .start_toggle(start_toggle),.source_index(source_index),
        .audio_start_toggle(audio_start_toggle),.audio_file_index(audio_file_index),
        .fifo_empty(production_empty),.fifo_data(production_data),.fifo_read(production_read),
        .rx_data(rx_byte),.rx_valid(rx_valid),.tx_request(media_request),.tx_valid(media_valid),
        .tx_data(media_data),.tx_length(media_length),.tx_ack(media_ack),
        .busy(tx_busy),.committed_index(committed_index),.committed_valid(committed_valid),.committed_wav(committed_wav),.error_code(tx_error),.state_code(tx_state)
    );
    uart_link #(.CLK_FREQ_HZ(125000000),.BAUD(1000000)) u_uart (
        .clk(app_clk),.rst(app_rst),.rx(uart_rx),.tx(uart_tx),.tx_ready(uart_tx_ready),
        .cmd(uart_cmd),.cmd_val(uart_cmd_valid),.tx_req(uart_tx_req),.tx_pkt(uart_tx_pkt)
    );
    media_control_core u_control (
        .clk(app_clk),.rst(app_rst),.cmd(cmd),.cmd_pending(cmd_pending),.cmd_ack_t(cmd_ack_t),
        .rx_data(rx_byte),.rx_valid(rx_valid),.tx_done_tog(tx_done_tog),.tx_tog(tx_tog),
        .uart_cmd(uart_cmd),.uart_cmd_valid(uart_cmd_valid),.uart_tx_ready(uart_tx_ready),
        .uart_tx_req(uart_tx_req),.uart_tx_pkt(uart_tx_pkt),
        .image_next_pulse(local_next_pulse),.image_prev_pulse(local_prev_pulse),.local_auto_toggle(key_auto_app_pulse),
        .tx_type(tx_type),.tx_payload_len(tx_payload_len),.tx_pkt(tx_pkt),
        .first_bmp(first_s1),.committed_index(committed_s1),.committed_valid(committed_valid_sync[1]),
        .paired_wav(committed_wav),.fat_state(fat_state_s1),.fat_error(fat_error_s1),.media_state(tx_state),
        .debug_request(control_debug_request),.auto_on(auto_on),.auto_period_s(auto_period_s),.volume(),.brightness(),.contrast(),
        .effect(),.osd_mode(),.spectrum_on(),.spectrum_sensitivity(),.last_control_error()
    );
    media_probe_bridge #(.DIAG_ENABLE(0)) u_probe (
        .media_status(diag_s1),
        .clk(clk),.rst(boot_rst),.cmd(cmd),.cmd_pending(cmd_pending),
        .sd_init_done(sd_init_done),.fat_mounted(fat_mounted),.fat_error(fat_error),
        .file_count(file_count),.bmp_count(bmp_count),.wav_count(wav_count),.first_bmp(first_bmp),.fat_state(fat_state),
        .bmp_busy(source_busy || tx_busy_sync[1]),.bmp_req(debug_req),.bmp_next_req(unused_next),.bmp_prev_req(unused_prev),
        .cmd_ack_t(),.tx_tog(),.tx_pkt()
    );
    eth_subsys #(.LOCAL_IP(32'hc0a88903),.LOCAL_MAC(48'h020000000003),.DST_IP(32'hc0a88901),.DISPLAY_IP(32'hc0a88902),.PC_UDP_PORT(16'h0002),.DISPLAY_UDP_PORT(16'h0001)) u_eth (
        .clk_50(clk),.rst_all(boot_rst),.phy1_rgmii_rx_clk(eth_rgmii_rxc),.phy1_rgmii_rx_ctl(eth_rgmii_rx_ctl),
        .phy1_rgmii_rx_data(eth_rgmii_rxd),.phy1_rgmii_tx_clk(eth_rgmii_txc),.phy1_rgmii_tx_ctl(eth_rgmii_tx_ctl),
        .phy1_rgmii_tx_data(eth_rgmii_txd),.phy_reset(eth_phy_reset),
        .app_clk_out(app_clk),.app_reset_out(app_rst),.app_rx_byte(rx_byte),.app_rx_valid(rx_valid),.media_stack_status(media_stack_status),
        .media_request(media_request),.media_valid(media_valid),.media_data(media_data),.media_length(media_length),.media_ack(media_ack),
        .cmd(cmd),.cmd_pending(cmd_pending),.cmd_ack_t(cmd_ack_t),.tx_tog(tx_tog),
        .tx_type(tx_type),.tx_payload_len(tx_payload_len),.tx_pkt(tx_pkt),.tx_done_tog(tx_done_tog),
        .sys_rst(boot_rst),.tap_clk(clk),.tap_val(tap_val),.tap_word(tap_word),.tap_end(tap_end),
        .tap2_clk(clk),.tap2_val(1'b0),.tap2_word(32'd0),.tap2_end(1'b0)
    );
    wire _unused=&{1'b0,image_width,image_height,production_available,tx_error,tx_done_tog,auto_next_pulse,control_debug_request,key_next_press,key_auto_press,key_prev_press};
endmodule
