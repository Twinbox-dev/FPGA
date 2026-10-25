`timescale 1ns/1ps

// End-to-end source test: native SD pins -> FAT32 -> BMP decode -> raw,
// variable-size RGB565 frame stream. Display-side padding is tested separately.
module tb_media_sd_image_source;
    reg sd_clk100=0;
    reg app_clk50=0;
    always #5 sd_clk100=~sd_clk100;
    always #10 app_clk50=~app_clk50;

    reg rst=1;
    reg pll_locked=0;
    reg start=0;
    reg abort=0;
    reg audio_start_toggle=0;
    reg [4:0] audio_file_index=0;
    reg count_clear=0,audio_check=0;
    reg [7:0] pcm_golden[0:2351103];
    string pcm_dir="captures/card_pcm",pcm_base,pcm_path;
    integer pcm_file,pcm_size,pcm_seen=0,pcm_bytes,byte_no,name_no;
    integer audio_checked=0;
    reg [7:0] name_byte;
    reg audio_done_ref;
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
    reg [4:0] selected_bmp_index=0;
    wire frame_clear,tap_val,tap_end,frame_valid;
    wire [11:0] image_width,image_height;
    wire [15:0] cmd_count,cmd_crc_errors,read_count;
    reg done_ref;
    integer cycles=0,words=0;
    integer image_no=0,expected_words=0;
    reg [31:0] visited_bmps=0;

    media_image_source u_source (
        .clk(app_clk50),.rst(rst),.start(start),.debug_start(1'b0),.abort(abort),
        .file_index(selected_bmp_index),.audio_start_toggle_async(audio_start_toggle),
        .audio_file_index_async(audio_file_index),.audio_pause(1'b0),
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
        if(rst || count_clear)begin words<=0;pcm_seen<=0;end
        else if(frame_valid)begin
            words<=words+1;
            if(audio_check)begin
                pcm_bytes=(pcm_size-pcm_seen>=4)?4:(pcm_size-pcm_seen);
                for(byte_no=0;byte_no<pcm_bytes;byte_no=byte_no+1)
                    if(frame_data[8*byte_no+:8]!==pcm_golden[pcm_seen+byte_no])
                        $fatal(1,"PCM mismatch %s sample%0d got%02x expected%02x",pcm_base,pcm_seen+byte_no,
                               frame_data[8*byte_no+:8],pcm_golden[pcm_seen+byte_no]);
                pcm_seen<=pcm_seen+pcm_bytes;
            end
        end
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
        selected_bmp_index=first_bmp[4:0];
        for(image_no=0;image_no<bmp_count;image_no=image_no+1) begin
            if(selected_bmp_index>=32 || visited_bmps[selected_bmp_index])
                $fatal(1,"BMP playlist loop/invalid index at image %0d index=%0d",
                    image_no,selected_bmp_index);
            visited_bmps[selected_bmp_index]=1'b1;
            @(negedge app_clk50);count_clear=1;
            @(negedge app_clk50);count_clear=0;
            done_ref=done_toggle;
            @(negedge app_clk50);start=1;
            @(negedge app_clk50);start=0;

            cycles=0;
            while((done_toggle==done_ref || source_busy) && cycles<200_000_000) begin
                @(posedge app_clk50);cycles=cycles+1;
                if(source_error || fat_error)
                    $fatal(1,"source error image=%0d index=%0d words=%0d state=%0d fat=%0d width=%0d height=%0d",
                        image_no,selected_bmp_index,words,source_status[2:0],fat_state,image_width,image_height);
            end
            if(done_toggle==done_ref || source_busy)
                $fatal(1,"image-source timeout image=%0d index=%0d words=%0d status=%02x fat=%0d host=%0d reads=%0d",
                    image_no,selected_bmp_index,words,source_status,fat_state,
                    u_source.u_sd_card.u_host.state,read_count);
            if(image_width==0 || image_height==0)
                $fatal(1,"BMP dimensions were not decoded at index=%0d",selected_bmp_index);
            expected_words=(image_width*image_height+1)/2;
            if(words!=expected_words)
                $fatal(1,"raw frame length index=%0d %0dx%0d got=%0d expected=%0d",
                    selected_bmp_index,image_width,image_height,words,expected_words);
            $display("BMP[%0d] %0dx%0d raw_words=%0d wav=%0d read_us=%0d",
                selected_bmp_index,image_width,image_height,words,paired_wav_valid,sd_last_read_cycles/100);
            if(paired_wav_valid)begin
                pcm_base="";
                for(name_no=0;name_no<8;name_no=name_no+1)begin
                    name_byte=u_source.image_name_latched[8*name_no+:8];
                    if(name_byte!=8'h20)pcm_base={pcm_base,$sformatf("%c",name_byte)};
                end
                pcm_path={pcm_dir,"/",pcm_base,".pcm"};
                pcm_file=$fopen(pcm_path,"rb");
                if(!pcm_file)$fatal(1,"missing PCM golden %s",pcm_path);
                pcm_size=$fread(pcm_golden,pcm_file);$fclose(pcm_file);
                @(negedge app_clk50);count_clear=1;audio_check=1;audio_file_index=paired_wav_index;
                @(negedge app_clk50);count_clear=0;audio_done_ref=audio_done_toggle;
                audio_start_toggle=~audio_start_toggle;
                cycles=0;
                while(audio_done_toggle==audio_done_ref && cycles<200_000_000)begin
                    @(posedge app_clk50);cycles=cycles+1;
                    if(audio_source_error || source_error || fat_error)$fatal(1,"WAV source failure %s",pcm_base);
                end
                repeat(3)@(negedge app_clk50);
                if(audio_done_toggle==audio_done_ref || pcm_seen!=pcm_size || audio_sample_count!=pcm_size || words!=(pcm_size+3)/4)
                    $fatal(1,"WAV count %s got%0d/%0d words%0d samples%0d",pcm_base,pcm_seen,pcm_size,words,audio_sample_count);
                audio_check=0;audio_checked=audio_checked+1;
                $display("PASS: %s WAV %0d PCM bytes exact through real SD/FAT source",pcm_base,pcm_size);
            end
            selected_bmp_index=bmp_next[(selected_bmp_index*6)+:6];
        end
        if(audio_checked!=wav_count)$fatal(1,"paired WAV coverage %0d expected%0d",audio_checked,wav_count);
        $display("MEDIA_SD_IMAGE_SOURCE_PASS all %0d BMP files, files=%0d WAV=%0d reads=%0d",
            bmp_count,file_count,wav_count,read_count);

        // Exercise the cancellation path used by media_image_tx when the
        // production FIFO stops making progress. Abort mid-BMP, wait for the
        // in-flight FAT sector to drain, then prove a fresh image can start.
        selected_bmp_index=first_bmp[4:0];
        @(negedge app_clk50);count_clear=1;
        @(negedge app_clk50);count_clear=0;done_ref=done_toggle;
        @(negedge app_clk50);start=1;
        @(negedge app_clk50);start=0;
        cycles=0;
        while(words<256 && source_busy && cycles<100_000_000)begin
            @(posedge app_clk50);cycles=cycles+1;
        end
        if(words<256 || !source_busy)$fatal(1,"abort test failed to reach active BMP stream");
        @(negedge app_clk50);abort=1;
        @(negedge app_clk50);abort=0;
        cycles=0;
        while((source_busy || done_toggle==done_ref) && cycles<2_000_000)begin
            @(posedge app_clk50);cycles=cycles+1;
        end
        if(source_busy || done_toggle==done_ref || source_error || fat_error)
            $fatal(1,"source abort did not drain cleanly busy=%0b done=%0b err=%0b fat=%0b",
                source_busy,done_toggle!=done_ref,source_error,fat_error);
        $display("PASS: source abort drains in-flight SD/FAT sector and returns idle");

        @(negedge app_clk50);count_clear=1;
        @(negedge app_clk50);count_clear=0;done_ref=done_toggle;
        @(negedge app_clk50);start=1;
        @(negedge app_clk50);start=0;
        cycles=0;
        while((done_toggle==done_ref || source_busy) && cycles<200_000_000)begin
            @(posedge app_clk50);cycles=cycles+1;
            if(source_error || fat_error)$fatal(1,"image retry after source abort failed");
        end
        if(done_toggle==done_ref || source_busy || image_width==0 || image_height==0)
            $fatal(1,"image source did not recover after abort");
        expected_words=(image_width*image_height+1)/2;
        if(words!=expected_words)
            $fatal(1,"image after abort got %0d words expected %0d",words,expected_words);
        $display("PASS: full BMP read succeeds after an aborted source transaction");
        $finish;
    end
endmodule
