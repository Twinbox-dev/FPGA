// Shared SD/FAT source. Image RGB565 words and WAV PCM words reuse one output FIFO.
module media_image_source (
    input wire clk, rst,
    input wire start, debug_start, abort,
    input wire [4:0] file_index,
    input wire audio_start_toggle_async,
    input wire [4:0] audio_file_index_async,
    input wire audio_pause,
    output wire SD_nCS, SD_DCLK, SD_MOSI,
    input wire SD_MISO,
    output wire sd_init_done, fat_mounted, fat_error,
    output wire [5:0] file_count, bmp_count, wav_count, first_bmp,
    output wire [191:0] bmp_next, bmp_prev,
    output wire [7:0] fat_state,
    output reg busy, error,
    output reg prepared_toggle, done_toggle,
    output reg audio_prepared_toggle, audio_done_toggle,
    output reg [31:0] audio_sample_count,
    output reg audio_source_error,
    output reg paired_wav_valid,
    output reg [4:0] paired_wav_index,
    output reg frame_clear,
    output reg [11:0] image_width, image_height,
    output wire [31:0] frame_data,
    output wire frame_valid,
    input wire frame_ready,
    output wire [7:0] source_status,
    output reg tap_val, tap_end,
    output reg [31:0] tap_word
);
    localparam [2:0] IDLE=3'd0, HEADER=3'd1, FULL=3'd2, RAW=3'd3,
                     CANCEL=3'd4, PAIR_NAME=3'd5, PAIR_SCAN=3'd6, AUDIO=3'd7;
    reg [2:0] state;
    reg [4:0] index_latched, audio_index_latched, pair_scan_index;
    reg [63:0] image_name_latched;
    reg file_req, restart, header_only, format_start, wav_restart;
    reg file_done_seen, format_done_seen;
    wire [31:0] lba, sd_addr;
    wire req, ready, dval, sec_done, sec_error;
    wire [7:0] data, sd_data;
    wire sd_read, sd_valid, sd_end;
    sd_card_top #(.SPI_LOW_SPEED_DIV(16'd248),.SPI_HIGH_SPEED_DIV(16'd0)) u_sd_card (
        .clk(clk),.rst(rst),.SD_nCS(SD_nCS),.SD_DCLK(SD_DCLK),.SD_MOSI(SD_MOSI),.SD_MISO(SD_MISO),
        .sd_init_done(sd_init_done),.sd_sec_read(sd_read),.sd_sec_read_addr(sd_addr),
        .sd_sec_read_data(sd_data),.sd_sec_read_data_valid(sd_valid),.sd_sec_read_end(sd_end),
        .sd_sec_write(1'b0),.sd_sec_write_addr(32'd0),.sd_sec_write_data(8'd0),
        .sd_sec_write_data_req(),.sd_sec_write_end()
    );
    sd_adapter u_sd_adapter (
        .clk(clk),.rst(rst),.sd_init_done(sd_init_done),.o_lba(lba),.o_req(req),
        .i_ready(ready),.i_data(data),.i_dval(dval),.i_done(sec_done),.i_err(sec_error),
        .sd_sec_read(sd_read),.sd_sec_read_addr(sd_addr),.sd_sec_read_data(sd_data),
        .sd_sec_read_data_valid(sd_valid),.sd_sec_read_end(sd_end)
    );

    wire [7:0] file_byte;
    wire file_valid, file_done, fat_idle, is_wav;
    wire [5:0] type_map;
    wire [63:0] pl_name;
    wire pl_wav, pl_valid;
    wire [4:0] pl_select = state==PAIR_SCAN ? pair_scan_index : index_latched;
    wire pixel_pause;
    wire file_pause = (state==FULL && pixel_pause) || (state==AUDIO && audio_pause);
    wire [4:0] fat_file_index = state==AUDIO ? audio_index_latched : index_latched;
    fat32_ro #(.FILE_FLOW_CONTROL(1)) u_fat32 (
        .clk(clk),.rst_n(~rst),.o_lba(lba),.o_req(req),.i_ready(ready),.i_data(data),
        .i_dval(dval),.i_done(sec_done),.i_err(sec_error),.o_byte(file_byte),.o_bval(file_valid),
        .o_file_done(file_done),.i_file_idx(fat_file_index),.i_file_req(file_req),
        .i_file_pause(file_pause),.i_header_only(header_only),
        .i_file_abort(state==CANCEL || abort),.o_mounted(fat_mounted),.o_file_cnt(file_count),
        .o_bmp_cnt(bmp_count),.o_wav_cnt(wav_count),.o_type_map(type_map),.o_first_bmp(first_bmp),
        .o_bmp_nxt(bmp_next),.o_bmp_prv(bmp_prev),.o_err(fat_error),.o_cur_is_wav(is_wav),
        .o_file_idle(fat_idle),.o_dbg_state(fat_state),.i_pl_idx(pl_select),
        .o_pl_name(pl_name),.o_pl_is_wav(pl_wav),.o_pl_valid(pl_valid)
    );

    wire pix_valid, hdr_ok, img_ok, img_error;
    wire [23:0] pix;
    wire [11:0] width, height;
    wire [7:0] dec_state;
    bmp_dec u_bmp_dec (
        .clk(clk),.rst_n(~rst),.i_byte(file_byte),
        .i_bval(file_valid && (state==HEADER || state==FULL || state==RAW)),
        .i_restart(restart),.o_pix_val(pix_valid),.o_pix(pix),
        .o_img_w(width),.o_img_h(height),.o_hdr_ok(hdr_ok),.o_img_ok(img_ok),
        .o_img_err(img_error),.o_dbg_state(dec_state)
    );
    wire [15:0] rgb565={pix[23:19],pix[15:10],pix[7:3]};
    wire format_active, format_done, format_error;
    wire [31:0] format_checksum, format_word;
    wire format_word_valid;
    media_frame_format u_format (
        .clk(clk),.rst(rst),.start(format_start),.abort(abort || state==CANCEL),
        .image_width(image_width),.image_height(image_height),
        .pixel_valid(pix_valid && state==FULL),.pixel_data(rgb565),.pixel_pause(pixel_pause),
        .word_data(format_word),.word_valid(format_word_valid),
        .word_ready(frame_ready && state==FULL),
        .active(format_active),.done(format_done),.error(format_error),.checksum(format_checksum)
    );

    wire [7:0] wav_sample;
    wire wav_sample_valid, wav_header_ok, wav_format_error;
    wire [31:0] wav_data_bytes;
    wav_reader u_wav_reader (
        .clk(clk),.rst_n(~rst),.i_byte(file_byte),
        .i_bval(file_valid && state==AUDIO),.i_restart(wav_restart),
        .o_smp(wav_sample),.o_sval(wav_sample_valid),
        .o_hdr_ok(wav_header_ok),.o_fmt_err(wav_format_error),.o_data_bytes(wav_data_bytes)
    );

    reg [2:0] audio_start_sync;
    wire audio_start_pulse=audio_start_sync[2]^audio_start_sync[1];
    reg audio_header_seen, audio_finish_seen, audio_reset_guard;
    reg [1:0] pcm_pack_count;
    reg [31:0] pcm_pack, pcm_word;
    reg pcm_word_valid;
    wire [31:0] pcm_word_padded =
        pcm_pack_count==2'd1 ? {24'd0,pcm_pack[7:0]} :
        pcm_pack_count==2'd2 ? {16'd0,pcm_pack[15:0]} :
        pcm_pack_count==2'd3 ? {8'd0,pcm_pack[23:0]} : 32'd0;
    assign frame_data = state==FULL ? format_word : pcm_word;
    assign frame_valid = state==FULL ? format_word_valid :
                         (state==AUDIO ? pcm_word_valid : 1'b0);
    assign source_status={error,state,file_done_seen,format_done_seen,img_ok,format_error};

    reg img_ok_d, half_pixel;
    reg [15:0] raw_low;
    always @(posedge clk) begin
        if (rst) begin
            state<=IDLE;index_latched<=0;audio_index_latched<=0;pair_scan_index<=0;
            image_name_latched<=0;file_req<=0;restart<=0;header_only<=0;
            format_start<=0;wav_restart<=0;busy<=0;error<=0;
            prepared_toggle<=0;done_toggle<=0;audio_prepared_toggle<=0;audio_done_toggle<=0;
            audio_sample_count<=0;audio_source_error<=0;paired_wav_valid<=0;paired_wav_index<=0;
            frame_clear<=1;image_width<=0;image_height<=0;
            file_done_seen<=0;format_done_seen<=0;img_ok_d<=0;half_pixel<=0;raw_low<=0;
            tap_val<=0;tap_end<=0;tap_word<=0;audio_start_sync<=0;
            audio_header_seen<=0;audio_finish_seen<=0;audio_reset_guard<=0;pcm_pack_count<=0;
            pcm_pack<=0;pcm_word<=0;pcm_word_valid<=0;
        end else begin
            file_req<=0;restart<=0;format_start<=0;wav_restart<=0;frame_clear<=0;
            tap_val<=0;tap_end<=0;img_ok_d<=img_ok;
            audio_start_sync<={audio_start_sync[1:0],audio_start_toggle_async};

            if (pcm_word_valid && frame_ready) pcm_word_valid<=0;
            if (state==AUDIO && !audio_reset_guard && wav_sample_valid && !audio_source_error) begin
                case (pcm_pack_count)
                    2'd0: begin pcm_pack[7:0]<=wav_sample;pcm_pack_count<=2'd1;end
                    2'd1: begin pcm_pack[15:8]<=wav_sample;pcm_pack_count<=2'd2;end
                    2'd2: begin pcm_pack[23:16]<=wav_sample;pcm_pack_count<=2'd3;end
                    default: begin
                        if (!pcm_word_valid || frame_ready) begin
                            pcm_word<={wav_sample,pcm_pack[23:0]};
                            pcm_word_valid<=1;pcm_pack_count<=0;
                        end else audio_source_error<=1;
                    end
                endcase
            end

            if(state==RAW) begin
                if(pix_valid) begin
                    if(!half_pixel) begin raw_low<=rgb565;half_pixel<=1;end
                    else begin tap_word<={rgb565,raw_low};tap_val<=1;half_pixel<=0;end
                end
                if(img_ok && !img_ok_d) begin
                    if(pix_valid && !half_pixel) begin tap_word<={16'd0,rgb565};tap_val<=1;half_pixel<=0;end
                    else if(!pix_valid && half_pixel) begin tap_word<={16'd0,raw_low};tap_val<=1;half_pixel<=0;end
                    tap_end<=1;
                end
            end

            if (audio_start_pulse && state!=IDLE)
                audio_source_error<=1'b1;

            if(abort && busy && state!=AUDIO) begin
                state<=CANCEL;
            end else case(state)
                IDLE: begin
                    if(start && fat_mounted && fat_idle) begin
                        index_latched<=file_index;busy<=1;error<=0;frame_clear<=1;
                        file_done_seen<=0;format_done_seen<=0;half_pixel<=0;
                        paired_wav_valid<=0;paired_wav_index<=0;
                        state<=PAIR_NAME;
                    end else if(debug_start && fat_mounted && fat_idle) begin
                        index_latched<=file_index;file_req<=1;restart<=1;
                        header_only<=0;busy<=1;error<=0;half_pixel<=0;state<=RAW;
                    end else if(audio_start_pulse && fat_mounted && fat_idle) begin
                        audio_index_latched<=audio_file_index_async;
                        file_req<=1;wav_restart<=1;header_only<=0;busy<=1;
                        audio_source_error<=0;audio_sample_count<=0;
                        audio_header_seen<=0;audio_finish_seen<=0;audio_reset_guard<=1;
                        pcm_pack_count<=0;pcm_pack<=0;pcm_word_valid<=0;
                        frame_clear<=1;state<=AUDIO;
                    end
                end
                PAIR_NAME: begin
                    if(pl_valid && !pl_wav) begin
                        image_name_latched<=pl_name;pair_scan_index<=0;state<=PAIR_SCAN;
                    end else begin error<=1;busy<=0;done_toggle<=~done_toggle;state<=IDLE;end
                end
                PAIR_SCAN: begin
                    if(pl_valid && pl_wav && pl_name==image_name_latched) begin
                        paired_wav_valid<=1;paired_wav_index<=pair_scan_index;
                        file_req<=1;restart<=1;header_only<=1;state<=HEADER;
                    end else if (({1'b0,pair_scan_index}+6'd1)>=file_count) begin
                        paired_wav_valid<=0;paired_wav_index<=0;
                        file_req<=1;restart<=1;header_only<=1;state<=HEADER;
                    end else pair_scan_index<=pair_scan_index+1'b1;
                end
                HEADER: if(file_done) begin
                    if(hdr_ok && !img_error) begin
                        image_width<=width;image_height<=height;header_only<=0;
                        file_req<=1;restart<=1;format_start<=1;
                        prepared_toggle<=~prepared_toggle;state<=FULL;
                    end else begin error<=1;busy<=0;done_toggle<=~done_toggle;state<=IDLE;end
                end else if(fat_error) begin error<=1;busy<=0;done_toggle<=~done_toggle;state<=IDLE;end
                FULL: begin
                    if(file_done) file_done_seen<=1;
                    if(format_done) format_done_seen<=1;
                    if(img_error || fat_error || format_error) begin error<=1;state<=CANCEL;end
                    else if((file_done_seen || file_done) && (format_done_seen || format_done) && img_ok) begin
                        busy<=0;done_toggle<=~done_toggle;state<=IDLE;
                    end
                end
                RAW: if(file_done || fat_error) begin
                    busy<=0;error<=fat_error || img_error;state<=IDLE;
                end
                AUDIO: begin
                    if (audio_reset_guard) audio_reset_guard<=0;
                    else begin
                        if (!audio_header_seen && wav_header_ok) begin
                            audio_sample_count<=wav_data_bytes;audio_header_seen<=1;
                            audio_prepared_toggle<=~audio_prepared_toggle;
                        end else if (!audio_header_seen && wav_format_error) begin
                            audio_sample_count<=0;audio_header_seen<=1;
                            audio_prepared_toggle<=~audio_prepared_toggle;
                        end else if (!audio_header_seen && fat_error) begin
                            audio_sample_count<=0;audio_source_error<=1;audio_header_seen<=1;
                            audio_prepared_toggle<=~audio_prepared_toggle;
                        end
                        if (file_done) begin
                            audio_finish_seen<=1;
                            if (!audio_header_seen && !wav_header_ok && !wav_format_error && !fat_error) begin
                                audio_sample_count<=0;audio_header_seen<=1;
                                audio_prepared_toggle<=~audio_prepared_toggle;
                            end
                        end
                        if (fat_error) begin
                            audio_source_error<=1;audio_finish_seen<=1;
                        end
                        if (audio_finish_seen && !wav_sample_valid) begin
                            if (pcm_pack_count!=0 && !pcm_word_valid) begin
                                pcm_word<=pcm_word_padded;pcm_word_valid<=1;pcm_pack_count<=0;
                            end else if (pcm_pack_count==0 && !pcm_word_valid) begin
                                busy<=0;audio_done_toggle<=~audio_done_toggle;state<=IDLE;
                            end
                        end
                    end
                end
                CANCEL: if(fat_idle) begin busy<=0;done_toggle<=~done_toggle;state<=IDLE;end
                default: state<=IDLE;
            endcase
        end
    end
endmodule
