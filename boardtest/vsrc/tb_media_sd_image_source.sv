`timescale 1ns/1ps

// End-to-end source test: native SD pins -> FAT32 -> BMP decode -> 1280x720
// RGB565 black-border formatter -> production frame stream.
module tb_media_sd_image_source;
    reg sd_clk100=0;
    reg app_clk50=0;
    always #5 sd_clk100=~sd_clk100;
    always #10 app_clk50=~app_clk50;

    reg rst=1;
    reg pll_locked=0;
    reg start=0;
    tri1 sd_cmd;
    tri1 [3:0] sd_dat;
    wire sd_clk,sd_init_done,fat_mounted,fat_error;
    wire [7:0] sd_diag_flags,fat_state,source_status;
    wire [15:0] sd_init_debug_word;
    wire [31:0] sd_last_read_cycles,image_read_cycles;
    wire [31:0] sd_last_failure_lba;
    wire [7:0] sd_last_failure_info;
    wire [31:0] sd_stream_debug;
    wire [5:0] file_count,bmp_count,wav_count,first_bmp;
    wire [191:0] bmp_next,bmp_prev;
    wire source_busy,source_error,prepared_toggle,done_toggle;
    wire audio_prepared_toggle,audio_done_toggle,audio_source_error,paired_wav_valid;
    wire [31:0] audio_sample_count,frame_data,tap_word;
    wire [4:0] paired_wav_index;
    wire frame_clear,tap_val,tap_end,frame_valid;
    wire [11:0] image_width,image_height;
    wire [15:0] cmd_count,cmd_crc_errors,read_count;
    reg done_ref;
    integer cycles=0,words=0;

    media_image_source u_source (
        .clk(app_clk50),.rst(rst),.start(start),.debug_start(1'b0),.abort(1'b0),
        .file_index(first_bmp[4:0]),.audio_start_toggle_async(1'b0),
        .audio_file_index_async(5'd0),.audio_pause(1'b0),
        .sd_clk(sd_clk),.sd_clk_100m(sd_clk100),.sd_pll_locked(pll_locked),
        .sd_cmd(sd_cmd),.sd_dat(sd_dat),.sd_init_done(sd_init_done),
        .fat_mounted(fat_mounted),.fat_error(fat_error),.sd_diag_flags(sd_diag_flags),
        .sd_init_debug_word(sd_init_debug_word),.sd_last_read_cycles(sd_last_read_cycles),
        .sd_last_failure_lba(sd_last_failure_lba),.sd_last_failure_info(sd_last_failure_info),
        .sd_stream_debug(sd_stream_debug),
        .image_read_cycles(image_read_cycles),.file_count(file_count),.bmp_count(bmp_count),
        .wav_count(wav_count),.first_bmp(first_bmp),.bmp_next(bmp_next),.bmp_prev(bmp_prev),
        .fat_state(fat_state),.busy(source_busy),.error(source_error),
        .prepared_toggle(prepared_toggle),.done_toggle(done_toggle),
        .audio_prepared_toggle(audio_prepared_toggle),.audio_done_toggle(audio_done_toggle),
        .audio_sample_count(audio_sample_count),.audio_source_error(audio_source_error),
        .paired_wav_valid(paired_wav_valid),.paired_wav_index(paired_wav_index),
        .frame_clear(frame_clear),.image_width(image_width),.image_height(image_height),
        .frame_data(frame_data),.frame_valid(frame_valid),.frame_ready(1'b1),
        .source_status(source_status),.tap_val(tap_val),.tap_end(tap_end),.tap_word(tap_word)
    );

    sd_native_card_model card (
        .sd_clk(sd_clk),.sd_cmd(sd_cmd),.sd_dat(sd_dat),.cmd_count(cmd_count),
        .cmd_crc_errors(cmd_crc_errors),.read_count(read_count)
    );

    always @(posedge app_clk50) begin
        if(!rst && frame_valid) words<=words+1;
    end

    initial begin
        repeat(8) @(posedge sd_clk100);
        rst=0;pll_locked=1;
        cycles=0;
        while(!fat_mounted && cycles<2_000_000) begin
            @(posedge app_clk50);cycles=cycles+1;
        end
        if(!fat_mounted) begin
            $display("mount debug: mbr=%0b sig=%b%b type=%02x start=%0d BPB=%0d/%0d/%0d/%0d/%0d/%0d FAT=%0d LBA=%0d bytes=%02x %02x %02x %02x",
                u_source.u_fat32.is_mbr,u_source.u_fat32.sig55,u_source.u_fat32.sigAA,
                u_source.u_fat32.mbr_type,u_source.u_fat32.start_lba_le,
                u_source.u_fat32.bps_le,u_source.u_fat32.spc,u_source.u_fat32.rsvd_le,
                u_source.u_fat32.nfats,u_source.u_fat32.fatsz_le,u_source.u_fat32.rootclus_le,
                u_source.u_fat32.state,card.data_lba,card.card_file[0],card.card_file[1],
                card.card_file[2],card.card_file[3]);
            $fatal(1,"FAT mount timeout host=%0d fat=%0d cmds=%0d reads=%0d",
                u_source.u_sd_card.u_host.state,fat_state,cmd_count,read_count);
        end
        $display("PASS: full-image card mounted files=%0d bmp=%0d wav=%0d first_bmp=%0d",
            file_count,bmp_count,wav_count,first_bmp);
        done_ref=done_toggle;
        @(negedge app_clk50);start=1;
        @(negedge app_clk50);start=0;

        cycles=0;
        while((done_toggle==done_ref || source_busy) && cycles<200_000_000) begin
            @(posedge app_clk50);cycles=cycles+1;
            if(source_error || fat_error)
                $fatal(1,"source error words=%0d state=%0d fat=%0d width=%0d height=%0d",
                    words,source_status[2:0],fat_state,image_width,image_height);
        end
        if(done_toggle==done_ref || source_busy)
            $fatal(1,"image-source timeout words=%0d source_status=%02x fat=%0d host=%0d reads=%0d last_sector=%0d",
                words,source_status,fat_state,u_source.u_sd_card.u_host.state,read_count,sd_last_read_cycles);
        if(words!=460800)
            $fatal(1,"formatted frame length=%0d expected=460800",words);
        if(image_width==0 || image_height==0)
            $fatal(1,"BMP dimensions were not decoded");
        $display("MEDIA_SD_IMAGE_SOURCE_PASS words=%0d dimensions=%0dx%0d reads=%0d read_us=%0d",
            words,image_width,image_height,read_count,sd_last_read_cycles/100);
        $finish;
    end
endmodule
