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
    input  wire [3:0] sd_dat,
    inout  wire sensor_scl,
    inout  wire sensor_sda
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
    wire [31:0] sd_last_failure_lba;wire [7:0] sd_last_failure_info;
    wire [31:0] sd_stream_debug;
    wire [7:0] image_source_status;
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
    wire start_toggle,source_abort_toggle;wire [4:0] source_index,committed_index;
    wire tx_busy,committed_valid;wire [7:0] tx_error;wire [3:0] tx_state;
    wire [7:0] media_status_state = (tx_error[7:4]==4'h7) ? tx_error : {tx_error[3:0],tx_state};
    wire committed_wav;reg [7:0] fat_state_s0,fat_state_s1;reg fat_error_s0,fat_error_s1;
    reg [7:0] sd_diag_s0,sd_diag_s1;reg [15:0] sd_debug_s0,sd_debug_s1;
    reg [31:0] image_cycles_s0,image_cycles_s1,sd_cycles_s0,sd_cycles_s1;
    reg [31:0] fail_lba_s0,fail_lba_s1;reg [7:0] fail_info_s0,fail_info_s1;
    reg [31:0] sd_stream_debug_s0,sd_stream_debug_s1;
    reg [7:0] source_status_s0,source_status_s1;
    wire auto_on;wire [3:0] auto_period_s,auto_next_pulse;
    wire usb_cmd_valid,bt_cmd_valid;wire [7:0] usb_cmd,bt_cmd;
    wire serial_cmd_valid,serial_cmd_ready;wire [7:0] serial_cmd;wire [1:0] serial_cmd_source,serial_source_lock;
    wire usb_tx_ready,bt_tx_ready,usb_tx_req,bt_tx_req;wire [63:0] serial_tx_pkt;
    wire usb_physical_ready,usb_packet_request;
    wire [135:0] usb_packet_data;
    wire [4:0] usb_packet_length;
    wire control_debug_request,pc_snapshot_request,media_to_pc;reg [1:0] control_debug_sync;
    // N/P are translated by media_control_core to one-cycle local pulses.
    // Passing them to media_image_tx as well queues the same step twice.
    wire media_internal_cmd_pending = cmd_pending && (cmd==8'h4d);
    wire local_next_pulse,local_prev_pulse;
    wire view_busy,view_layout_request,view_touch_request,serial_cmd_was_busy;
    wire [1:0] view_requested_layout,view_active_layout;
    wire [3:0] view_active_mask;
    wire [15:0] view_active_generation;
    wire [4:0] view_current_index;
    wire view_current_valid,view_status_valid;
    wire [127:0] view_status_body;
    wire sensor_snapshot_request,sensor_snapshot_release_toggle,sensor_snapshot_done_toggle;
    wire [335:0] sensor_snapshot_bus;
    reg sensor_query_toggle,sensor_snapshot_ready,sensor_snapshot_seen;
    reg [2:0] sensor_snapshot_done_sync;
    wire job_start,job_snapshot,job_previous,job_ready,job_done;
    wire [4:0] job_index;
    wire [1:0] job_layout,job_window;
    wire [15:0] job_generation;
    wire [7:0] job_result;
    wire formal_request,formal_valid,formal_ack,formal_to_pc;
    wire [7:0] formal_data;wire [15:0] formal_length;
    // A toggle carries image-source cancellation from the 125 MHz application
    // clock into the 50 MHz SD/FAT clock domain without losing a short pulse.
    reg [2:0] source_abort_sync;
    always @(posedge clk) begin
        if(media_sd_rst)source_abort_sync<=0;
        else source_abort_sync<={source_abort_sync[1:0],source_abort_toggle};
    end
    wire source_abort_pulse=source_abort_sync[2]^source_abort_sync[1];
    wire view_request,view_valid,view_ack,view_to_pc;
    wire [7:0] view_data;wire [15:0] view_length;
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
        .clk(app_clk),.rst(media_app_rst),.enable(auto_on),.busy(view_busy),.committed_valid(view_current_valid),
        .period_s(auto_period_s),.next_pulse(auto_next_pulse)
    );
    always @(posedge clk) begin
        if(media_sd_rst)control_debug_sync<=0;
        else control_debug_sync<={control_debug_sync[0],control_debug_request};
    end
    wire debug_launch=control_debug_sync[1] && !tx_busy_sync[1] && !formal_start;
    wire [4:0] file_index=debug_launch ? (committed_valid_sync[1]?committed_s1:first_bmp[4:0]) : source_index_s1;
    media_image_source u_source (
        .clk(clk),.rst(media_sd_rst),.start(formal_start),.debug_start(debug_launch),.abort(source_abort_pulse),.file_index(file_index),
        .audio_start_toggle_async(audio_start_toggle),.audio_file_index_async(audio_file_index),
        .audio_pause(audio_pause_sync[1]),
        .sd_clk(sd_clk),.sd_clk_100m(sd_clk_100m),.sd_pll_locked(sd_pll_locked),.sd_cmd(sd_cmd),.sd_dat(sd_dat),
        .sd_init_done(sd_init_done),.fat_mounted(fat_mounted),.fat_error(fat_error),
        .sd_diag_flags(sd_diag_flags),.sd_init_debug_word(sd_init_debug_word),
        .sd_last_read_cycles(sd_last_read_cycles),.sd_last_failure_lba(sd_last_failure_lba),
        .sd_last_failure_info(sd_last_failure_info),.sd_stream_debug(sd_stream_debug),
        .image_read_cycles(image_read_cycles),
        .file_count(file_count),.bmp_count(bmp_count),.wav_count(wav_count),.first_bmp(first_bmp),
        .bmp_next(bmp_next),.bmp_prev(bmp_prev),.fat_state(fat_state),.busy(source_busy),.error(source_error),
        .prepared_toggle(prepared_toggle),.done_toggle(done_toggle),.audio_prepared_toggle(audio_prepared_toggle),
        .audio_done_toggle(audio_done_toggle),.audio_sample_count(audio_sample_count),
        .audio_source_error(audio_source_error),.paired_wav_valid(source_has_wav),
        .paired_wav_index(source_wav_index),.frame_clear(frame_clear),
        .image_width(image_width),.image_height(image_height),.frame_data(frame_data),.frame_valid(frame_valid),
        .frame_ready(frame_ready),.source_status(image_source_status),.tap_val(tap_val),.tap_end(tap_end),.tap_word(tap_word)
    );

    // Sensor I2C runs from the fixed 50 MHz board clock. Its sampled raw bus
    // crosses to the Ethernet application domain only on an explicit query.
    media_sensor_capture u_sensor_capture (
        .clk(clk),.rst(media_sd_rst),.sensor_scl(sensor_scl),.sensor_sda(sensor_sda),
        .snapshot_request_toggle(sensor_query_toggle),
        .snapshot_release_toggle(sensor_snapshot_release_toggle),
        .snapshot_done_toggle(sensor_snapshot_done_toggle),.snapshot_data(sensor_snapshot_bus)
    );
    always @(posedge app_clk) begin
        if(media_app_rst)begin
            sensor_query_toggle<=0;sensor_snapshot_done_sync<=0;sensor_snapshot_seen<=0;
            sensor_snapshot_ready<=0;
        end else begin
            if(sensor_snapshot_request)sensor_query_toggle<=~sensor_query_toggle;
            sensor_snapshot_done_sync<={sensor_snapshot_done_sync[1:0],sensor_snapshot_done_toggle};
            sensor_snapshot_ready<=0;
            if(sensor_snapshot_done_sync[2]!=sensor_snapshot_seen)begin
                sensor_snapshot_seen<=sensor_snapshot_done_sync[2];
                sensor_snapshot_ready<=1;
            end
        end
    end
    reg [1:0] clear_sync,busy_sync,error_sync,prepared_sync,done_sync;
    reg [2:0] mounted_sync;
    // Playlist buses only change during mount. Two destination registers plus
    // a third mounted synchronizer stage keep lookups out of the CDC path.
    reg [5:0] first_s0,first_s1;
    reg [191:0] next_s0,next_s1,prev_s0,prev_s1;
    reg [11:0] image_width_s0,image_width_s1,image_height_s0,image_height_s1;
    always @(posedge app_clk) begin
        if(media_app_rst)begin
            clear_sync<=3;mounted_sync<=0;busy_sync<=0;error_sync<=0;prepared_sync<=0;done_sync<=0;
            fat_state_s0<=0;fat_state_s1<=0;fat_error_s0<=0;fat_error_s1<=0;
            sd_diag_s0<=0;sd_diag_s1<=0;sd_debug_s0<=0;sd_debug_s1<=0;
            image_cycles_s0<=0;image_cycles_s1<=0;sd_cycles_s0<=0;sd_cycles_s1<=0;
            source_status_s0<=0;source_status_s1<=0;
            fail_lba_s0<=0;fail_lba_s1<=0;fail_info_s0<=0;fail_info_s1<=0;
            sd_stream_debug_s0<=0;sd_stream_debug_s1<=0;
            first_s0<=0;first_s1<=0;next_s0<=0;next_s1<=0;prev_s0<=0;prev_s1<=0;
            image_width_s0<=0;image_width_s1<=0;image_height_s0<=0;image_height_s1<=0;
        end else begin
            clear_sync<={clear_sync[0],frame_clear};mounted_sync<={mounted_sync[1:0],fat_mounted};
            fat_state_s0<=fat_state;fat_state_s1<=fat_state_s0;fat_error_s0<=fat_error;fat_error_s1<=fat_error_s0;
            sd_diag_s0<=sd_diag_flags;sd_diag_s1<=sd_diag_s0;
            sd_debug_s0<=sd_init_debug_word;sd_debug_s1<=sd_debug_s0;
            image_cycles_s0<=image_read_cycles;image_cycles_s1<=image_cycles_s0;
            sd_cycles_s0<=sd_last_read_cycles;sd_cycles_s1<=sd_cycles_s0;
            source_status_s0<=image_source_status;source_status_s1<=source_status_s0;
            fail_lba_s0<=sd_last_failure_lba;fail_lba_s1<=fail_lba_s0;
            fail_info_s0<=sd_last_failure_info;fail_info_s1<=fail_info_s0;
            sd_stream_debug_s0<=sd_stream_debug;sd_stream_debug_s1<=sd_stream_debug_s0;
            first_s0<=first_bmp;first_s1<=first_s0;
            next_s0<=bmp_next;next_s1<=next_s0;prev_s0<=bmp_prev;prev_s1<=prev_s0;
            image_width_s0<=image_width;image_width_s1<=image_width_s0;
            image_height_s0<=image_height;image_height_s1<=image_height_s0;
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
    media_image_tx #(.EXTERNAL_SCHEDULE(1)) u_formal_tx (
        .clk(app_clk),.rst(media_app_rst),.mounted(mounted_sync[2]),.source_busy(busy_sync[1]),.source_error(error_sync[1]),
        .first_bmp(first_s1),.bmp_next(next_s1),.bmp_prev(prev_s1),
        .image_width(image_width_s1),.image_height(image_height_s1),
        .cmd(cmd),.cmd_pending(media_internal_cmd_pending),.auto_next(auto_next_pulse),.auto_status(auto_on),
        .pc_snapshot_request(1'b0),.media_to_pc(formal_to_pc),
        .job_start(job_start),.job_snapshot(job_snapshot),.job_previous(job_previous),
        .job_index(job_index),.job_layout(job_layout),.job_window(job_window),.job_generation(job_generation),
        .job_ready(job_ready),.job_done(job_done),.job_result(job_result),
        .local_next(local_next_pulse || key_next_app_pulse),.local_prev(local_prev_pulse || key_prev_app_pulse),
        .prepared_toggle(prepared_sync[1]),.done_toggle(done_sync[1]),.source_has_wav_async(source_has_wav),
        .source_wav_index_async(source_wav_index),.audio_prepared_toggle(audio_prepared_toggle),
        .audio_done_toggle(audio_done_toggle),.audio_sample_count_async(audio_sample_count),
        .audio_source_error_async(audio_source_error),
        .start_toggle(start_toggle),.source_index(source_index),
        .audio_start_toggle(audio_start_toggle),.audio_file_index(audio_file_index),
        .source_abort_toggle(source_abort_toggle),
        .fifo_empty(production_empty),.fifo_data(production_data),.fifo_read(production_read),
        .rx_data(rx_byte),.rx_valid(rx_valid),.tx_request(formal_request),.tx_valid(formal_valid),
        .tx_data(formal_data),.tx_length(formal_length),.tx_ack(formal_ack),
        .busy(tx_busy),.committed_index(committed_index),.committed_valid(committed_valid),.committed_wav(committed_wav),.error_code(tx_error),.state_code(tx_state)
    );
    media_view_scheduler u_view_scheduler(.clk(app_clk),.rst(media_app_rst),.link_ready(job_ready),
        .next_request(local_next_pulse || key_next_app_pulse || auto_next_pulse!=0),
        .prev_request(local_prev_pulse || key_prev_app_pulse),.snapshot_request(pc_snapshot_request),
        .layout_request(view_layout_request),.requested_layout(view_requested_layout),.touch_request(view_touch_request),
        .first_bmp(first_s1),.bmp_next(next_s1),.bmp_prev(prev_s1),.rx_data(rx_byte),.rx_valid(rx_valid),
        .job_start(job_start),.job_snapshot(job_snapshot),.job_previous(job_previous),.job_index(job_index),
        .job_layout(job_layout),.job_window(job_window),.job_generation(job_generation),
        .job_done(job_done),.job_result(job_result),.busy(view_busy),.current_index(view_current_index),
        .current_valid(view_current_valid),.active_layout(view_active_layout),.active_mask(view_active_mask),
        .active_generation(view_active_generation),.view_status_valid(view_status_valid),.view_status_body(view_status_body),
        .tx_request(view_request),.tx_valid(view_valid),.tx_data(view_data),.tx_length(view_length),
        .tx_to_pc(view_to_pc),.tx_ack(view_ack));
    media_packet_arbiter u_view_packet_arbiter(.clk(app_clk),.rst(media_app_rst),
        .a_request(formal_request),.a_valid(formal_valid),.a_to_pc(formal_to_pc),.a_data(formal_data),
        .a_length(formal_length),.a_ack(formal_ack),.b_request(view_request),.b_valid(view_valid),
        .b_to_pc(view_to_pc),.b_data(view_data),.b_length(view_length),.b_ack(view_ack),
        .request(media_request),.valid(media_valid),.data(media_data),.length(media_length),
        .to_pc(media_to_pc),.ack(media_ack));
    media_usb_view_tx u_usb_view(.clk(app_clk),.rst(media_app_rst),.physical_ready(usb_physical_ready),
        .control_request(usb_tx_req),.control_packet(serial_tx_pkt),.control_ready(usb_tx_ready),
        .view_valid(view_status_valid),.view_body(view_status_body),
        .tx_request(usb_packet_request),.tx_packet(usb_packet_data),.tx_count(usb_packet_length));
    uart_link #(.CLK_FREQ_HZ(125000000),.BAUD(1000000),.TX_BYTES(17)) u_uart_usb (
        .clk(app_clk),.rst(media_app_rst),.rx(uart_rx),.tx(uart_tx),.tx_ready(usb_physical_ready),
        .cmd(usb_cmd),.cmd_val(usb_cmd_valid),.tx_req(usb_packet_request),.tx_pkt(usb_packet_data),.tx_count(usb_packet_length)
    );
    uart_link #(.CLK_FREQ_HZ(125000000),.BAUD(9600)) u_uart_bt (
        .clk(app_clk),.rst(media_app_rst),.rx(bt_rx),.tx(bt_tx),.tx_ready(bt_tx_ready),
        .cmd(bt_cmd),.cmd_val(bt_cmd_valid),.tx_req(bt_tx_req),.tx_pkt(serial_tx_pkt),.tx_count(5'd8)
    );
    media_uart_arbiter u_uart_arbiter (
        .clk(app_clk),.rst(media_app_rst),.usb_cmd(usb_cmd),.usb_valid(usb_cmd_valid),
        .bt_cmd(bt_cmd),.bt_valid(bt_cmd_valid),.cmd(serial_cmd),.cmd_source(serial_cmd_source),
        .source_lock(serial_source_lock),.cmd_valid(serial_cmd_valid),.cmd_ready(serial_cmd_ready),
        .view_busy(view_busy),.cmd_was_busy(serial_cmd_was_busy),
        .usb_overflow_count(),.bt_overflow_count()
    );
    media_control_core #(.VIEW_ENABLE(1)) u_control (
        .clk(app_clk),.rst(media_app_rst),.cmd(cmd),.cmd_pending(cmd_pending),.cmd_ack_t(cmd_ack_t),
        .rx_data(rx_byte),.rx_valid(rx_valid),.tx_done_tog(tx_done_tog),.tx_tog(tx_tog),
        .uart_cmd(serial_cmd),.uart_cmd_valid(serial_cmd_valid),.uart_cmd_source(serial_cmd_source),
        .uart_cmd_ready(serial_cmd_ready),.uart_source_lock(serial_source_lock),
        .view_busy(view_busy),.uart_cmd_was_busy(serial_cmd_was_busy),
        .layout_request(view_layout_request),.requested_layout(view_requested_layout),.image_touch_request(view_touch_request),
        .sensor_snapshot_request(sensor_snapshot_request),.sensor_snapshot_ready(sensor_snapshot_ready),
        .sensor_snapshot_release_toggle(sensor_snapshot_release_toggle),
        .sensor_snapshot_data(sensor_snapshot_bus),
        .uart_tx_ready(usb_tx_ready),.bt_tx_ready(bt_tx_ready),
        .uart_tx_req(usb_tx_req),.bt_tx_req(bt_tx_req),.uart_tx_pkt(serial_tx_pkt),
        .sd_diag_flags(sd_diag_s1),.sd_init_debug_word(sd_debug_s1),
        .image_read_cycles(image_cycles_s1),.sd_read_cycles(sd_cycles_s1),
        .image_source_status(source_status_s1),.image_source_busy(busy_sync[1]),
        .sd_last_failure_lba(fail_lba_s1),.sd_last_failure_info(fail_info_s1),
        .sd_stream_debug(sd_stream_debug_s1),
        .image_next_pulse(local_next_pulse),.image_prev_pulse(local_prev_pulse),.local_auto_toggle(key_auto_app_pulse),
        .tx_type(tx_type),.tx_payload_len(tx_payload_len),.tx_pkt(tx_pkt),
        .first_bmp(first_s1),.committed_index(view_current_index),.committed_valid(view_current_valid),
        .paired_wav(committed_wav && view_active_layout==0),.fat_state(fat_state_s1),.fat_error(fat_error_s1),
        .media_state(media_status_state),
        .debug_request(control_debug_request),.pc_snapshot_request(pc_snapshot_request),
        .auto_on(auto_on),.auto_period_s(auto_period_s),.volume(),.brightness(),.contrast(),
        .effect(),.cv_mode(),.osd_mode(),.spectrum_on(),.spectrum_sensitivity(),.last_control_error()
    );
    // Ethernet D requests use the formal on-demand snapshot transaction.
    // UART D retains the raw source probe for bench diagnostics.
    // Production SD/media flow keeps PC D snapshot and source taps in RTL.
    // MAC wire capture remains enabled for this SD/BT acceptance baseline;
    // evaluate disabling it later as a separate resource candidate.
    // Raw MAC capture was temporary packet debugging. Keep the reusable
    // implementation in eth_subsys, but omit it from the product netlist;
    // formal D snapshots and both application data taps are independent.
    eth_subsys #(.MEDIA_UDP_LITE(1),.MAC_CAPTURE(0),.LOCAL_IP(32'hc0a88903),.LOCAL_MAC(48'h020000000003),.DST_IP(32'hc0a88901),.DISPLAY_IP(32'hc0a88902),.PC_UDP_PORT(16'h0002),.DISPLAY_UDP_PORT(16'h0001)) u_eth (
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
