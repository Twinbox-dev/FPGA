`timescale 1ns/1ps

// Media sender -> display receiver loopback for the first real padded-card
// case (BMP index 5, 504x720). This includes the production packet cadence,
// image checksum, silent audio transaction, display padding/writer, and both
// RESULT replies, while abstracting only UDP/IP/PHY transport.
module tb_media_pair_504 #(
    parameter integer IMAGE_WIDTH=504,
    parameter integer IMAGE_HEIGHT=720
);
    localparam integer SOURCE_WORDS = (IMAGE_WIDTH*IMAGE_HEIGHT+1)/2;
    localparam integer CANVAS_WORDS = 460800;
    reg [7:0] bmp_bytes [0:2764853];
    reg bmp_loaded=0;
    integer bmp_offset=0,bmp_stride=0;
    string bmp_name;
    integer bmp_file,bmp_size;
    function automatic [15:0] source_pixel(input integer index);
        integer p;
        reg [31:0] pattern;
        begin
            if(bmp_loaded) begin
                p=bmp_offset+(index/IMAGE_WIDTH)*bmp_stride+(index%IMAGE_WIDTH)*3;
                source_pixel={bmp_bytes[p+2][7:3],bmp_bytes[p+1][7:2],bmp_bytes[p][7:3]};
            end else begin
                pattern=(32'h9e3779b9*index)^32'h1f123bb5;
                source_pixel=pattern[31:16]^pattern[15:0];
            end
        end
    endfunction
    function automatic [31:0] source_word(input integer index);
        source_word={((index*2+1<IMAGE_WIDTH*IMAGE_HEIGHT)?source_pixel(index*2+1):16'd0),source_pixel(index*2)};
    endfunction
    function automatic [15:0] canvas_pixel(input integer x,input integer y);
        integer left,bottom,index;
        begin
            left=(1280-IMAGE_WIDTH)/2;bottom=(720-IMAGE_HEIGHT)-(720-IMAGE_HEIGHT)/2;
            index=(y-bottom)*IMAGE_WIDTH+x-left;
            canvas_pixel=(x>=left && x<left+IMAGE_WIDTH && y>=bottom && y<bottom+IMAGE_HEIGHT)?source_pixel(index):16'd0;
        end
    endfunction

    reg udp_clk = 0, write_clk = 0;
    always #4 udp_clk = ~udp_clk;
    always #5 write_clk = ~write_clk;
    reg rst = 1;

    reg mounted = 1, source_busy = 0, source_error = 0;
    reg [5:0] first_bmp = 6'd1;
    reg [191:0] bmp_next = 0, bmp_prev = 0;
    reg [11:0] source_width = IMAGE_WIDTH, source_height = IMAGE_HEIGHT;
    reg prepared_toggle = 0, done_toggle = 0;
    reg source_has_wav = 0;
    reg [4:0] source_wav_index = 0;
    reg audio_prepared_toggle = 0, audio_done_toggle = 0;
    reg [31:0] audio_sample_count = 0;
    reg audio_source_error = 0;
    reg local_next = 0, local_prev = 0;
    reg [7:0] cmd = 0;
    reg cmd_pending = 0, auto_next = 0, auto_status = 0, pc_snapshot_request = 0;

    wire sender_start_toggle, sender_audio_start_toggle;
    wire [4:0] sender_source_index, sender_audio_file_index;
    reg [31:0] source_read_count = 0;
    wire source_fifo_empty = source_read_count >= SOURCE_WORDS;
    reg [31:0] source_fifo_data = 0;
    wire source_fifo_read;
    wire sender_tx_request, sender_tx_valid, sender_tx_ack;
    wire [7:0] sender_tx_data;
    wire [15:0] sender_tx_length;
    wire sender_rx_valid;
    wire [7:0] sender_rx_data;
    wire sender_busy, sender_committed_valid, sender_committed_wav, media_to_pc;
    wire [4:0] sender_committed_index;
    wire [7:0] sender_error;
    wire [3:0] sender_state;
    reg source_seen = 0;
    integer prepare_delay = -1;

    media_image_tx u_sender (
        .job_start(1'b0),.job_snapshot(1'b0),.job_previous(1'b0),.job_index(5'd0),.job_layout(2'd0),.job_window(2'd0),.job_generation(16'd0),.job_ready(),.job_done(),.job_result(),
        .clk(udp_clk), .rst(rst), .mounted(mounted), .source_busy(source_busy), .source_error(source_error),
        .first_bmp(first_bmp), .bmp_next(bmp_next), .bmp_prev(bmp_prev),
        .image_width(source_width), .image_height(source_height),
        .cmd(cmd), .cmd_pending(cmd_pending), .auto_next(auto_next), .auto_status(auto_status),
        .pc_snapshot_request(pc_snapshot_request), .local_next(local_next), .local_prev(local_prev),
        .prepared_toggle(prepared_toggle), .done_toggle(done_toggle),
        .source_has_wav_async(source_has_wav), .source_wav_index_async(source_wav_index),
        .audio_prepared_toggle(audio_prepared_toggle), .audio_done_toggle(audio_done_toggle),
        .audio_sample_count_async(audio_sample_count), .audio_source_error_async(audio_source_error),
        .start_toggle(sender_start_toggle), .source_index(sender_source_index),
        .audio_start_toggle(sender_audio_start_toggle), .audio_file_index(sender_audio_file_index),
        .fifo_empty(source_fifo_empty), .fifo_data(source_fifo_data), .fifo_read(source_fifo_read),
        .rx_data(sender_rx_data), .rx_valid(sender_rx_valid),
        .tx_request(sender_tx_request), .tx_valid(sender_tx_valid), .tx_data(sender_tx_data),
        .tx_length(sender_tx_length), .tx_ack(sender_tx_ack), .busy(sender_busy),
        .committed_index(sender_committed_index), .committed_valid(sender_committed_valid),
        .committed_wav(sender_committed_wav), .error_code(sender_error), .state_code(sender_state),
        .media_to_pc(media_to_pc)
    );
    assign sender_tx_ack = sender_tx_request;

    always @(posedge udp_clk or posedge rst) begin
        if (rst) begin
            source_seen <= 0; prepare_delay <= -1; source_busy <= 0;
            source_read_count <= 0; prepared_toggle <= 0; done_toggle <= 0;
        end else begin
            if (sender_start_toggle != source_seen) begin
                source_seen <= sender_start_toggle;
                source_busy <= 1;
                source_read_count <= 0;
                prepare_delay <= 4;
            end else if (prepare_delay > 0) begin
                prepare_delay <= prepare_delay - 1;
            end else if (prepare_delay == 0) begin
                prepared_toggle <= ~prepared_toggle;
                source_busy <= 0;
                prepare_delay <= -1;
            end
            if (source_fifo_read && source_read_count < SOURCE_WORDS) begin
                source_fifo_data <= source_word(source_read_count);
                source_read_count <= source_read_count + 1;
                if (source_read_count + 1 == SOURCE_WORDS)
                    done_toggle <= ~done_toggle;
            end
        end
    end

    wire [7:0] display_rx_data = sender_tx_data;
    wire display_rx_valid = sender_tx_valid;
    wire ready_request, frame_begin_valid;
    wire [15:0] frame_id, frame_end_id;
    wire [4:0] image_index;
    wire [7:0] image_flags;
    wire [20:0] image_total_words;
    wire [11:0] image_width, image_height;
    wire stream_start, stream_is_audio, stream_word_valid, stream_done;
    wire [8:0] stream_word_count;
    wire [31:0] stream_word_data;
    wire raw_stream_ready;
    wire padded_stream_start, padded_stream_audio, padded_stream_valid, padded_stream_ready, padded_stream_done;
    wire [8:0] padded_stream_count;
    wire [31:0] padded_stream_data;
    wire pad_frame_done;
    wire frame_end_valid, frame_end_ok;
    wire [3:0] frame_end_reason;
    wire audio_begin_valid, audio_end_valid, audio_end_ok;
    wire [15:0] audio_frame_id, audio_end_id;
    wire [31:0] received_audio_count;
    wire [3:0] audio_end_reason;
    wire protocol_error_toggle;

    media_protocol_rx u_rx (
        .clk(udp_clk), .rst(rst), .rx_data(display_rx_data), .rx_valid(display_rx_valid),
        .ready_request(ready_request), .frame_begin_valid(frame_begin_valid),
        .frame_id(frame_id), .image_index(image_index), .image_flags(image_flags),
        .image_total_words(image_total_words), .image_width(image_width), .image_height(image_height),
        .image_layout(), .image_window(), .image_generation(),
        .stream_start(stream_start), .stream_is_audio(stream_is_audio),
        .stream_word_count(stream_word_count), .stream_word_data(stream_word_data),
        .stream_word_valid(stream_word_valid), .stream_word_ready(raw_stream_ready), .stream_done(stream_done),
        .frame_end_valid(frame_end_valid), .frame_end_ok(frame_end_ok), .frame_end_reason(frame_end_reason),
        .frame_end_id(frame_end_id), .audio_begin_valid(audio_begin_valid), .audio_frame_id(audio_frame_id),
        .audio_sample_count(received_audio_count), .audio_end_valid(audio_end_valid),
        .audio_end_ok(audio_end_ok), .audio_end_reason(audio_end_reason), .audio_end_id(audio_end_id),
        .protocol_error_toggle(protocol_error_toggle)
    );

    media_frame_pad u_pad (
        .layout(2'd0),
        .clk(udp_clk), .rst(rst), .frame_begin(frame_begin_valid),
        .image_width(image_width), .image_height(image_height), .frame_end(frame_end_valid),
        .in_is_audio(stream_is_audio), .in_start(stream_start), .in_count(stream_word_count),
        .in_data(stream_word_data), .in_valid(stream_word_valid), .in_ready(raw_stream_ready),
        .in_done(stream_done), .out_start(padded_stream_start), .out_is_audio(padded_stream_audio),
        .out_count(padded_stream_count), .out_data(padded_stream_data), .out_valid(padded_stream_valid),
        .out_ready(padded_stream_ready), .out_done(padded_stream_done), .frame_done(pad_frame_done)
    );

    reg finish_toggle = 0, write_req_d = 0, backend_finish_d = 0;
    wire backend_ack, backend_ready, backend_finish;
    wire backend_write_en;
    wire [20:0] backend_write_addr;
    wire [31:0] backend_write_data;
    reg [9:0] backend_phase = 0;
    reg [20:0] write_target = 0, written_words = 0;
    wire display_valid, image_has_wav, auto_play_status;
    wire [4:0] displayed_index;
    wire [11:0] displayed_width, displayed_height;
    wire [1:0] display_buffer_index;
    wire transition_start_toggle, transition_target_buf, transition_prev_latched;
    wire [1:0] transition_mode_latched;
    wire frame_commit_pulse, write_req, write_en;
    wire [1:0] write_buffer_index;
    wire [20:0] write_length;
    wire [19:0] write_row_offset;
    wire [31:0] write_data;
    wire image_result_valid, audio_result_valid;
    wire [7:0] image_result_code, audio_result_code;
    wire audio_pair_on;
    wire [1:0] audio_buffer_index;
    wire [20:0] audio_buffer_length;
    wire [31:0] audio_sample_count_out;
    wire audio_source_toggle;
    integer border_mismatch_count = 0;
    // Use the actual production FIFO/reset/SDRAM request engines. The former
    // always-ready sink hid three lost border words during FIFO reset release.
    frame_read_write #(.FRAME_WIDTH(640), .FRAME_HEIGHT(720), .WRITE_V_FLIP(1)) u_backend (
        .stream_clk(1'b0),
        .view_read_layout(2'd0),.view_write_layout(2'd0),.view_write_window(2'd0),.view_valid_mask(4'd1),.view_epoch(1'b0),.view_drained_epoch(),
        .rst(rst), .mem_clk(write_clk), .Sdr_init_done(1'b1),
        .Sdr_init_ref_vld(backend_phase < 10'd24), .Sdr_busy(1'b0),
        .App_rd_en(), .App_rd_addr(), .Sdr_rd_en(1'b0), .Sdr_rd_dout(32'd0),
        .read_clk(write_clk), .read_req(1'b0), .read_req_ack(), .read_finish(),
        .read_addr_0(21'd0), .read_addr_1(21'd460800),
        .read_addr_2(21'd921600), .read_addr_3(21'd1509376),
        .read_addr_index(2'd0), .read_len(21'd460800), .read_en(1'b0),
        .read_data(), .o_vid_rd_empty(), .o_mem_rd_audio(), .o_mem_rd_busy(),
        .o_mem_wr_busy(), .o_vid_fifo_words(), .line_hold(backend_phase < 10'd800),
        .aud_read_req(1'b0), .aud_read_req_ack(), .aud_read_finish(),
        .aud_read_addr_index(2'd2), .aud_read_len(21'd0), .aud_rd_en(1'b0),
        .aud_rd_data(), .o_aud_fifo_words(),
        .App_wr_en(backend_write_en), .App_wr_addr(backend_write_addr),
        .App_wr_din(backend_write_data), .App_wr_dm(),
        .write_clk(write_clk), .write_req(write_req), .write_req_ack(backend_ack),
        .write_ready(backend_ready), .write_finish(backend_finish),
        .write_addr_0(21'd0), .write_addr_1(21'd460800),
        .write_addr_2(21'd921600), .write_addr_3(21'd1509376),
        .write_addr_index(write_buffer_index), .write_len(write_length),
        .vrow_off(20'sd0), .write_en(write_en), .write_data(write_data)
    );
    always @(posedge write_clk) begin
        backend_phase <= backend_phase + 1'b1;
        backend_finish_d <= backend_finish;
        if (backend_finish && !backend_finish_d) finish_toggle <= ~finish_toggle;
        write_req_d <= write_req;
        if (write_req && !write_req_d) begin
            write_target <= write_length;
            written_words <= 0;
        end
        if (backend_write_en) begin
            if (backend_write_data !== {canvas_pixel((written_words%640)*2+1,written_words/640),
                                        canvas_pixel((written_words%640)*2,written_words/640)})
                $fatal(1,"actual SDRAM write mismatch word=%0d addr=%0d got=%08x",written_words,backend_write_addr,backend_write_data);
            if(backend_write_addr != (719-written_words/640)*640+written_words%640)
                $fatal(1,"actual SDRAM vflip address mismatch word=%0d addr=%0d",written_words,backend_write_addr);
            written_words <= written_words + 1;
        end
    end

    media_transaction_writer u_writer (
        .image_layout(2'd0),.image_window(2'd0),.view_target_buffer(1'b0),.write_layout(),.write_window(),
        .udp_clk(udp_clk), .udp_rst(rst), .frame_begin_valid(frame_begin_valid),
        .frame_id(frame_id), .image_index(image_index), .image_flags(image_flags),
        .image_total_words(image_total_words), .image_width(image_width), .image_height(image_height),
        .stream_start(padded_stream_start), .stream_is_audio(padded_stream_audio),
        .stream_word_count(padded_stream_count), .stream_word_data(padded_stream_data),
        .stream_word_valid(padded_stream_valid), .stream_word_ready(padded_stream_ready),
        .stream_done(padded_stream_done), .frame_end_valid(frame_end_valid),
        .frame_end_ok(frame_end_ok), .frame_end_reason(frame_end_reason), .frame_end_id(frame_end_id),
        .audio_begin_valid(audio_begin_valid), .audio_frame_id(audio_frame_id),
        .audio_sample_count(received_audio_count), .audio_end_valid(audio_end_valid),
        .audio_end_ok(audio_end_ok), .audio_end_reason(audio_end_reason), .audio_end_id(audio_end_id),
        .write_clk(write_clk), .write_rst(rst), .frame_finish_toggle(finish_toggle),
        .effect_mode(2'd0), .audio_commit_enable(1'b1), .transition_done_toggle(1'b0),
        .display_valid(display_valid), .image_index_out(displayed_index),
        .image_width_out(displayed_width), .image_height_out(displayed_height),
        .image_has_wav(image_has_wav), .auto_play_status(auto_play_status),
        .display_buffer_index(display_buffer_index), .transition_start_toggle(transition_start_toggle),
        .transition_target_buf(transition_target_buf), .transition_mode_latched(transition_mode_latched),
        .transition_prev_latched(transition_prev_latched), .frame_commit_pulse(frame_commit_pulse),
        .write_req(write_req), .write_req_ack(backend_ack), .write_ready(backend_ready),
        .write_buffer_index(write_buffer_index),
        .write_length(write_length), .write_row_offset(write_row_offset), .write_en(write_en),
        .write_data(write_data), .image_result_valid(image_result_valid),
        .image_result_code(image_result_code), .audio_result_valid(audio_result_valid),
        .audio_result_code(audio_result_code), .audio_pair_on(audio_pair_on),
        .audio_buffer_index(audio_buffer_index), .audio_buffer_length(audio_buffer_length),
        .audio_sample_count_out(audio_sample_count_out), .audio_source_toggle(audio_source_toggle)
    );

    wire display_tx_request, display_tx_valid, display_tx_ack;
    wire [7:0] display_tx_data;
    wire [15:0] display_tx_length;
    media_display_tx #(.TX_GAP_CYCLES(4)) u_display_tx (
        .view_busy(1'b0),.view_prepare_valid(1'b0),.view_prepare_body(64'd0),.view_status_valid(1'b0),.view_status_body(128'd0),
        .clk(udp_clk), .rst(rst), .local_cmd_toggle_async(1'b0), .local_cmd_async(8'd0),
        .ready_valid(1'b0), .image_result_valid(image_result_valid),
        .image_result_code(image_result_code), .image_result_frame(frame_id),
        .audio_result_valid(audio_result_valid), .audio_result_code(audio_result_code),
        .audio_result_frame(frame_id), .control_ack_valid(1'b0), .control_ack_sequence(8'd0),
        .control_ack_op(8'd0), .control_ack_status(8'd0), .control_ack_value(8'd0),
        .status_valid(1'b0), .status_payload(64'd0), .tx_request(display_tx_request),
        .tx_valid(display_tx_valid), .tx_data(display_tx_data), .tx_length(display_tx_length),
        .tx_ready(1'b1), .tx_ack(display_tx_ack)
    );
    assign display_tx_ack = display_tx_request;
    assign sender_rx_valid = display_tx_valid;
    assign sender_rx_data = display_tx_data;

    integer response_packets = 0, response_byte = 0;
    reg response_in_packet = 0;
    reg [7:0] response_type [0:7], response_code [0:7];
    always @(posedge udp_clk) begin
        if (display_tx_valid) begin
            if (response_byte == 4) response_type[response_packets] = display_tx_data;
            if (response_byte == 10) response_code[response_packets] = display_tx_data;
            response_byte = response_byte + 1;
            response_in_packet = 1;
        end else if (response_in_packet) begin
            response_packets = response_packets + 1;
            response_byte = 0;
            response_in_packet = 0;
        end
    end

    integer reset_count, scan_index;
    initial begin
        if($value$plusargs("BMP=%s",bmp_name)) begin
            bmp_file=$fopen(bmp_name,"rb");
            if(!bmp_file)$fatal(1,"cannot open BMP fixture %s",bmp_name);
            bmp_size=$fread(bmp_bytes,bmp_file);$fclose(bmp_file);
            bmp_offset={bmp_bytes[13],bmp_bytes[12],bmp_bytes[11],bmp_bytes[10]};
            bmp_stride=(IMAGE_WIDTH*3+3)&~3;bmp_loaded=1;
            if(bmp_size<bmp_offset+bmp_stride*IMAGE_HEIGHT)$fatal(1,"truncated BMP fixture");
        end
        bmp_next[(3*6)+:6] = 6'd5; // FAT playlist: current index 3 -> BMP index 5 (504x720).
        repeat(5) @(negedge udp_clk);
        rst = 0;
        // Prime the sender as an already-ready dual-board system whose last
        // committed frame is index 3; the only transaction under test is N.
        @(negedge udp_clk);
        u_sender.state = 4'd9;              // IDLE
        u_sender.receiver_ready = 1'b1;
        u_sender.boot_loaded = 1'b1;
        u_sender.committed_valid = 1'b1;
        u_sender.committed_index = 5'd3;
        // Leave display-writer outputs under the writer's sole procedural
        // driver. The transaction under test still starts from sender index 3;
        // display storage contents are irrelevant to this fresh full-frame write.
        local_next = 1'b1;
        @(negedge udp_clk);
        local_next = 1'b0;

        reset_count = 0;
        while ((!sender_committed_valid || sender_committed_index != 5'd5 ||
                sender_busy || sender_error != 0 || response_packets < 3 ||
                written_words != CANVAS_WORDS || !display_valid || displayed_index != 5'd5 ||
                displayed_width != IMAGE_WIDTH || displayed_height != IMAGE_HEIGHT) &&
               reset_count < 60_000_000) begin
            @(negedge udp_clk);
            reset_count = reset_count + 1;
        end
        if (reset_count >= 60_000_000)
            $fatal(1, "pair loopback timeout: sender_state=%0d error=%0d source_words=%0d/%0d rx_active=%0d bad=%0d rx_words=%0d/%0d frame_good=%0d reason=%0d pad=%0d xy=%0d,%0d writes=%0d/%0d results=%0d last=%0d/%0d",
                   sender_state, sender_error, source_read_count, SOURCE_WORDS, u_rx.frame_active,
                   u_rx.frame_bad, u_rx.received_image_words, image_total_words,
                   frame_end_ok, frame_end_reason, u_pad.frame_active, u_pad.x, u_pad.y,
                   written_words, CANVAS_WORDS, response_packets,
                   response_type[response_packets-1], response_code[response_packets-1]);
        if (sender_committed_index != 5 || displayed_index != 5 || !display_valid ||
            displayed_width != IMAGE_WIDTH || displayed_height != IMAGE_HEIGHT)
            $fatal(1, "committed metadata mismatch sender=%0d display=%0d %0dx%0d",
                   sender_committed_index, displayed_index, displayed_width, displayed_height);
        if (response_type[0] != 8'h24 || response_code[0] != 0 ||
            response_type[1] != 8'h33 || response_code[1] != 0 ||
            response_type[2] != 8'h24 || response_code[2] != 2)
            $fatal(1, "response order/type mismatch %h/%h %h/%h %h/%h",
                   response_type[0],response_code[0],response_type[1],response_code[1],
                   response_type[2],response_code[2]);
        if (written_words != CANVAS_WORDS || border_mismatch_count != 0)
            $fatal(1, "padded SDRAM frame mismatch words=%0d errors=%0d",
                   written_words, border_mismatch_count);
        $display("PASS: %0dx%0d every SDRAM write word/address exact, real FIFOs and result handshake",IMAGE_WIDTH,IMAGE_HEIGHT);
        $finish;
    end

    initial begin #600000000; $fatal(1, "media/display pair loopback timeout"); end
endmodule
