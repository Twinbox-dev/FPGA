`timescale 1ns/1ps
// Media image stage: canonical frame production and PC receiver validation.
// Legacy D raw tap remains a separate debugging path; no media-board SDRAM.
module top (
    input wire clk,rst_n,
    input wire key1,key2,key3,
    input wire uart_rx,output wire uart_tx,
    input wire bt_rx,output wire bt_tx,
    input wire eth_rgmii_rxc,eth_rgmii_rx_ctl,input wire [3:0] eth_rgmii_rxd,
    output wire eth_rgmii_txc,eth_rgmii_tx_ctl,output wire [3:0] eth_rgmii_txd,
    output wire eth_phy_reset,
    output wire sd_clk,
    inout  wire sd_cmd,
    input  wire [3:0] sd_dat
);
    reg boot_rst=1;
    always @(posedge clk) if(rst_n)boot_rst<=0;
    reg reset_key_armed=0,reset_key_seen=0,reset_key_pulse=0;
    always @(posedge clk) begin
        if(boot_rst) begin reset_key_armed<=0;reset_key_seen<=0;reset_key_pulse<=0;end
        else if(rst_n) begin reset_key_armed<=1;reset_key_seen<=0;reset_key_pulse<=0;end
        else if(reset_key_armed && !reset_key_seen) begin
            reset_key_seen<=1;reset_key_pulse<=1;
        end else reset_key_pulse<=0;
    end
    wire media_sd_rst=boot_rst|reset_key_pulse;
    wire sd_clk_100m,sd_pll_locked;
    sd_host_pll u_sd_host_pll(.refclk_50m(clk),.reset(media_sd_rst),.clk_100m(sd_clk_100m),.locked(sd_pll_locked));
    wire [7:0] cmd;wire cmd_pending,cmd_ack_t,tx_tog;wire [63:0] tx_pkt;
    wire [15:0] tx_type,tx_payload_len;wire tx_done_tog;
    wire app_clk,app_rst;wire [7:0] rx_byte;wire rx_valid;wire [3:0] media_stack_status;
    reg [2:0] reset_key_sync;
    always @(posedge app_clk) begin
        if(app_rst) reset_key_sync<=0;
        else reset_key_sync<={reset_key_sync[1:0],reset_key_pulse};
    end
    wire media_app_rst=app_rst|reset_key_sync[2];
    wire media_request,media_valid,media_ack;wire [7:0] media_data;wire [15:0] media_length;
    wire sd_init_done,fat_mounted,fat_error,source_busy,source_error;
    wire [7:0] sd_diag_flags;wire [15:0] sd_init_debug_word;wire [31:0] sd_last_read_cycles,image_read_cycles;
    wire [5:0] file_count,bmp_count,wav_count,first_bmp;
    wire [191:0] bmp_next,bmp_prev;wire [7:0] fat_state;
    wire tap_val,tap_end;wire [31:0] tap_word;
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
    wire tx_busy,committed_valid;wire [7:0] tx_error;wire [3:0] tx_state;
    wire [7:0] media_status_state = (tx_error[7:4]==4'h7) ? tx_error : {tx_error[3:0],tx_state};
    wire committed_wav;reg [7:0] fat_state_s0,fat_state_s1;reg fat_error_s0,fat_error_s1;
    reg [7:0] sd_diag_s0,sd_diag_s1;reg [15:0] sd_debug_s0,sd_debug_s1;
    reg [31:0] image_cycles_s0,image_cycles_s1,sd_cycles_s0,sd_cycles_s1;
    wire auto_on;wire [3:0] auto_period_s,auto_next_pulse;
    wire usb_cmd_valid,bt_cmd_valid;wire [7:0] usb_cmd,bt_cmd;
    wire serial_cmd_valid,serial_cmd_ready;wire [7:0] serial_cmd;wire [1:0] serial_cmd_source,serial_source_lock;
    wire usb_tx_ready,bt_tx_ready,usb_tx_req,bt_tx_req;wire [63:0] serial_tx_pkt;
    wire control_debug_request,pc_snapshot_request,media_to_pc;reg [1:0] control_debug_sync;
    // N/P are translated by media_control_core to one-cycle local pulses.
    // Passing them to media_image_tx as well queues the same step twice.
    wire media_internal_cmd_pending = cmd_pending && (cmd==8'h4d);
    wire local_next_pulse,local_prev_pulse;
    wire key_next_press,key_auto_press,key_prev_press;
    reg key_next_toggle,key_auto_toggle,key_prev_toggle;
    reg [2:0] key_next_cdc,key_auto_cdc,key_prev_cdc;
    reg key_next_cdc_d,key_auto_cdc_d,key_prev_cdc_d;
    wire key_next_app_pulse=key_next_cdc[2]^key_next_cdc_d;
    wire key_auto_app_pulse=key_auto_cdc[2]^key_auto_cdc_d;
    wire key_prev_app_pulse=key_prev_cdc[2]^key_prev_cdc_d;
    media_button_debounce u_key_next(.clk(clk),.rst(media_sd_rst),.button_n(key1),.press_pulse(key_next_press));
    media_button_debounce u_key_auto(.clk(clk),.rst(media_sd_rst),.button_n(key2),.press_pulse(key_auto_press));
    media_button_debounce u_key_prev(.clk(clk),.rst(media_sd_rst),.button_n(key3),.press_pulse(key_prev_press));
    always @(posedge clk) begin
        if(media_sd_rst)begin key_next_toggle<=0;key_auto_toggle<=0;key_prev_toggle<=0;end
        else begin
            if(key_next_press)key_next_toggle<=~key_next_toggle;
            if(key_auto_press)key_auto_toggle<=~key_auto_toggle;
            if(key_prev_press)key_prev_toggle<=~key_prev_toggle;
        end
    end
    always @(posedge app_clk) begin
        if(media_app_rst)begin key_next_cdc<=0;key_auto_cdc<=0;key_prev_cdc<=0;
            key_next_cdc_d<=0;key_auto_cdc_d<=0;key_prev_cdc_d<=0;end
        else begin
            key_next_cdc<={key_next_cdc[1:0],key_next_toggle};
            key_auto_cdc<={key_auto_cdc[1:0],key_auto_toggle};
            key_prev_cdc<={key_prev_cdc[1:0],key_prev_toggle};
            key_next_cdc_d<=key_next_cdc[2];key_auto_cdc_d<=key_auto_cdc[2];key_prev_cdc_d<=key_prev_cdc[2];
        end
    end
    always @(posedge clk) begin
        if(media_sd_rst) audio_pause_sync<=0;
        else audio_pause_sync<={audio_pause_sync[0],production_available>=10'd256};
    end
    reg [2:0] start_sync;
    reg [4:0] source_index_s0,source_index_s1,committed_s0,committed_s1;
    reg [1:0] committed_valid_sync,tx_busy_sync;
    always @(posedge clk) begin
        if(media_sd_rst) begin
            source_index_s0<=0;source_index_s1<=0;committed_s0<=0;committed_s1<=0;
            committed_valid_sync<=0;tx_busy_sync<=0;
        end else begin
            source_index_s0<=source_index;source_index_s1<=source_index_s0;
            committed_s0<=committed_index;committed_s1<=committed_s0;
            committed_valid_sync<={committed_valid_sync[0],committed_valid};
            tx_busy_sync<={tx_busy_sync[0],tx_busy};
        end
    end
    always @(posedge clk) if(media_sd_rst)start_sync<=0;else start_sync<={start_sync[1:0],start_toggle};
    wire formal_start=start_sync[2]^start_sync[1];
    media_autoplay_timer u_autoplay_timer(
        .clk(app_clk),.rst(media_app_rst),.enable(auto_on),.busy(tx_busy),.committed_valid(committed_valid),
        .period_s(auto_period_s),.next_pulse(auto_next_pulse)
    );
    always @(posedge clk) begin
        if(media_sd_rst)control_debug_sync<=0;
        else control_debug_sync<={control_debug_sync[0],control_debug_request};
    end
    wire debug_launch=control_debug_sync[1] && !tx_busy_sync[1] && !formal_start;
    wire [4:0] file_index=debug_launch ? (committed_valid_sync[1]?committed_s1:first_bmp[4:0]) : source_index_s1;
    media_image_source u_source (
        .clk(clk),.rst(media_sd_rst),.start(formal_start),.debug_start(debug_launch),.abort(1'b0),.file_index(file_index),
        .audio_start_toggle_async(audio_start_toggle),.audio_file_index_async(audio_file_index),
        .audio_pause(audio_pause_sync[1]),
        .sd_clk(sd_clk),.sd_clk_100m(sd_clk_100m),.sd_pll_locked(sd_pll_locked),.sd_cmd(sd_cmd),.sd_dat(sd_dat),
        .sd_init_done(sd_init_done),.fat_mounted(fat_mounted),.fat_error(fat_error),
        .sd_diag_flags(sd_diag_flags),.sd_init_debug_word(sd_init_debug_word),
        .sd_last_read_cycles(sd_last_read_cycles),.image_read_cycles(image_read_cycles),
        .file_count(file_count),.bmp_count(bmp_count),.wav_count(wav_count),.first_bmp(first_bmp),
        .bmp_next(bmp_next),.bmp_prev(bmp_prev),.fat_state(fat_state),.busy(source_busy),.error(source_error),
        .prepared_toggle(prepared_toggle),.done_toggle(done_toggle),.audio_prepared_toggle(audio_prepared_toggle),
        .audio_done_toggle(audio_done_toggle),.audio_sample_count(audio_sample_count),
        .audio_source_error(audio_source_error),.paired_wav_valid(source_has_wav),
        .paired_wav_index(source_wav_index),.frame_clear(frame_clear),
        .image_width(image_width),.image_height(image_height),.frame_data(frame_data),.frame_valid(frame_valid),
        .frame_ready(frame_ready),.source_status(),.tap_val(tap_val),.tap_end(tap_end),.tap_word(tap_word)
    );
    reg [1:0] clear_sync,busy_sync,error_sync,prepared_sync,done_sync;
    reg [2:0] mounted_sync;
    // Playlist buses only change during mount. Two destination registers plus
    // a third mounted synchronizer stage keep lookups out of the CDC path.
    reg [5:0] first_s0,first_s1;
    reg [191:0] next_s0,next_s1,prev_s0,prev_s1;
    always @(posedge app_clk) begin
        if(media_app_rst)begin
            clear_sync<=3;mounted_sync<=0;busy_sync<=0;error_sync<=0;prepared_sync<=0;done_sync<=0;
            fat_state_s0<=0;fat_state_s1<=0;fat_error_s0<=0;fat_error_s1<=0;
            sd_diag_s0<=0;sd_diag_s1<=0;sd_debug_s0<=0;sd_debug_s1<=0;
            image_cycles_s0<=0;image_cycles_s1<=0;sd_cycles_s0<=0;sd_cycles_s1<=0;
            first_s0<=0;first_s1<=0;next_s0<=0;next_s1<=0;prev_s0<=0;prev_s1<=0;
        end else begin
            clear_sync<={clear_sync[0],frame_clear};mounted_sync<={mounted_sync[1:0],fat_mounted};
            fat_state_s0<=fat_state;fat_state_s1<=fat_state_s0;fat_error_s0<=fat_error;fat_error_s1<=fat_error_s0;
            sd_diag_s0<=sd_diag_flags;sd_diag_s1<=sd_diag_s0;
            sd_debug_s0<=sd_init_debug_word;sd_debug_s1<=sd_debug_s0;
            image_cycles_s0<=image_read_cycles;image_cycles_s1<=image_cycles_s0;
            sd_cycles_s0<=sd_last_read_cycles;sd_cycles_s1<=sd_cycles_s0;
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
        .wr_clk(clk),.wr_rst(media_sd_rst || frame_clear),.wr_en(frame_valid && frame_ready),
        .wr_data(frame_data),.wr_full(production_full),
        .rd_clk(app_clk),.rd_rst(media_app_rst || clear_sync[1]),.rd_en(production_read),
        .rd_data(production_data),.rd_empty(production_empty),.rd_avail(production_available)
    );
    media_image_tx u_formal_tx (
        .clk(app_clk),.rst(media_app_rst),.mounted(mounted_sync[2]),.source_busy(busy_sync[1]),.source_error(error_sync[1]),
        .first_bmp(first_s1),.bmp_next(next_s1),.bmp_prev(prev_s1),.cmd(cmd),.cmd_pending(media_internal_cmd_pending),.auto_next(auto_next_pulse),.auto_status(auto_on),
        .pc_snapshot_request(pc_snapshot_request),.media_to_pc(media_to_pc),
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
    uart_link #(.CLK_FREQ_HZ(125000000),.BAUD(1000000)) u_uart_usb (
        .clk(app_clk),.rst(media_app_rst),.rx(uart_rx),.tx(uart_tx),.tx_ready(usb_tx_ready),
        .cmd(usb_cmd),.cmd_val(usb_cmd_valid),.tx_req(usb_tx_req),.tx_pkt(serial_tx_pkt)
    );
    uart_link #(.CLK_FREQ_HZ(125000000),.BAUD(9600)) u_uart_bt (
        .clk(app_clk),.rst(media_app_rst),.rx(bt_rx),.tx(bt_tx),.tx_ready(bt_tx_ready),
        .cmd(bt_cmd),.cmd_val(bt_cmd_valid),.tx_req(bt_tx_req),.tx_pkt(serial_tx_pkt)
    );
    media_uart_arbiter u_uart_arbiter (
        .clk(app_clk),.rst(media_app_rst),.usb_cmd(usb_cmd),.usb_valid(usb_cmd_valid),
        .bt_cmd(bt_cmd),.bt_valid(bt_cmd_valid),.cmd(serial_cmd),.cmd_source(serial_cmd_source),
        .source_lock(serial_source_lock),.cmd_valid(serial_cmd_valid),.cmd_ready(serial_cmd_ready),
        .usb_overflow_count(),.bt_overflow_count()
    );
    media_control_core u_control (
        .clk(app_clk),.rst(media_app_rst),.cmd(cmd),.cmd_pending(cmd_pending),.cmd_ack_t(cmd_ack_t),
        .rx_data(rx_byte),.rx_valid(rx_valid),.tx_done_tog(tx_done_tog),.tx_tog(tx_tog),
        .uart_cmd(serial_cmd),.uart_cmd_valid(serial_cmd_valid),.uart_cmd_source(serial_cmd_source),
        .uart_cmd_ready(serial_cmd_ready),.uart_source_lock(serial_source_lock),
        .uart_tx_ready(usb_tx_ready),.bt_tx_ready(bt_tx_ready),
        .uart_tx_req(usb_tx_req),.bt_tx_req(bt_tx_req),.uart_tx_pkt(serial_tx_pkt),
        .sd_diag_flags(sd_diag_s1),.sd_init_debug_word(sd_debug_s1),
        .image_read_cycles(image_cycles_s1),.sd_read_cycles(sd_cycles_s1),
        .image_next_pulse(local_next_pulse),.image_prev_pulse(local_prev_pulse),.local_auto_toggle(key_auto_app_pulse),
        .tx_type(tx_type),.tx_payload_len(tx_payload_len),.tx_pkt(tx_pkt),
        .first_bmp(first_s1),.committed_index(committed_s1),.committed_valid(committed_valid_sync[1]),
        .paired_wav(committed_wav),.fat_state(fat_state_s1),.fat_error(fat_error_s1),
        .media_state(media_status_state),
        .debug_request(control_debug_request),.pc_snapshot_request(pc_snapshot_request),
        .auto_on(auto_on),.auto_period_s(auto_period_s),.volume(),.brightness(),.contrast(),
        .effect(),.osd_mode(),.spectrum_on(),.spectrum_sensitivity(),.last_control_error()
    );
    // Ethernet D requests use the formal on-demand snapshot transaction.
    // UART D retains the raw source probe for bench diagnostics.
    // Production SD/media flow keeps PC D snapshot and source taps in RTL.
    // MAC wire capture remains enabled for this SD/BT acceptance baseline;
    // evaluate disabling it later as a separate resource candidate.
    eth_subsys #(.MAC_CAPTURE(1),.LOCAL_IP(32'hc0a88903),.LOCAL_MAC(48'h020000000003),.DST_IP(32'hc0a88901),.DISPLAY_IP(32'hc0a88902),.PC_UDP_PORT(16'h0002),.DISPLAY_UDP_PORT(16'h0001)) u_eth (
        .clk_50(clk),.rst_all(boot_rst),.phy1_rgmii_rx_clk(eth_rgmii_rxc),.phy1_rgmii_rx_ctl(eth_rgmii_rx_ctl),
        .phy1_rgmii_rx_data(eth_rgmii_rxd),.phy1_rgmii_tx_clk(eth_rgmii_txc),.phy1_rgmii_tx_ctl(eth_rgmii_tx_ctl),
        .phy1_rgmii_tx_data(eth_rgmii_txd),.phy_reset(eth_phy_reset),
        .app_clk_out(app_clk),.app_reset_out(app_rst),.app_rx_byte(rx_byte),.app_rx_valid(rx_valid),.media_stack_status(media_stack_status),
        .media_request(media_request),.media_valid(media_valid),.media_data(media_data),.media_length(media_length),.media_ack(media_ack),
        .media_to_pc(media_to_pc),
        .cmd(cmd),.cmd_pending(cmd_pending),.cmd_ack_t(cmd_ack_t),.tx_tog(tx_tog),
        .tx_type(tx_type),.tx_payload_len(tx_payload_len),.tx_pkt(tx_pkt),.tx_done_tog(tx_done_tog),
        .sys_rst(boot_rst),.tap_clk(clk),.tap_val(tap_val),.tap_word(tap_word),.tap_end(tap_end),
        .tap2_clk(clk),.tap2_val(1'b0),.tap2_word(32'd0),.tap2_end(1'b0)
    );
wire _unused=&{1'b0,image_width,image_height,production_available,media_stack_status,tx_done_tog,auto_next_pulse,key_next_press,key_auto_press,key_prev_press};
endmodule
