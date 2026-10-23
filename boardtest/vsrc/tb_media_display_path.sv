`timescale 1ns/1ps

module tb_media_display_path;
    parameter integer DIRECT_STREAM = 0;
    reg udp_clk=0, slow_write_clk=0;
    wire write_clk=DIRECT_STREAM ? udp_clk : slow_write_clk;
    always #4 udp_clk=~udp_clk;
    always #5 slow_write_clk=~slow_write_clk;
    reg rst=1;
    reg [7:0] rx_data=0;
    reg rx_valid=0;
    wire ready_request,frame_begin_valid;
    wire [15:0] frame_id;
    wire [4:0] image_index;
    wire [7:0] image_flags;
    wire [20:0] image_total_words;
    wire [11:0] image_width,image_height;
    wire stream_start,stream_is_audio,stream_word_valid,stream_done;
    wire [8:0] stream_word_count;
    wire [31:0] stream_word_data;
    wire stream_word_ready,raw_stream_ready;
    wire padded_stream_start,padded_stream_audio,padded_stream_valid,padded_stream_ready,padded_stream_done;
    wire [8:0] padded_stream_count;
    wire [31:0] padded_stream_data;
    wire pad_frame_done;
    wire frame_end_valid,frame_end_ok;
    wire [3:0] frame_end_reason;
    wire [15:0] frame_end_id,audio_frame_id,audio_end_id;
    wire audio_begin_valid,audio_end_valid,audio_end_ok;
    wire [3:0] audio_end_reason;
    wire [31:0] audio_sample_count;
    wire protocol_error_toggle;
    wire display_valid,image_has_wav,auto_play_status;
    wire [4:0] image_index_out;
    wire [11:0] image_width_out,image_height_out;
    wire [1:0] display_buffer_index,transition_mode_latched;
    wire transition_start_toggle,transition_target_buf,transition_prev_latched;
    wire frame_commit_pulse;
    wire write_req,write_en;
    wire [1:0] write_buffer_index;
    wire [20:0] write_length;
    wire [19:0] write_row_offset;
    wire [31:0] write_data;
    wire image_result_valid,audio_result_valid;
    wire [7:0] image_result_code,audio_result_code;
    wire audio_pair_on;
    wire [1:0] audio_buffer_index;
    wire [20:0] audio_buffer_length;
    wire [31:0] audio_sample_count_out;
    wire audio_source_toggle;
    reg finish_toggle=0,request_d=0;
    reg [20:0] req_words=0,written_words=0;
    reg [1:0] req_buffer=0;
    reg [1:0] transition_done_toggle=0;
    wire tx_request,tx_valid,tx_ack;
    wire [7:0] tx_data,stack_data;
    wire [15:0] tx_length,stack_length;
    wire stack_req,stack_valid,chunk_active,chunk_ready;
    reg stack_ack=0;
    reg stack_sending=0;
    reg [15:0] stack_bytes_expected=0,stack_bytes_sent=0;

    media_protocol_rx #(.FRAME_WORDS(21'd3)) u_rx (
        .clk(udp_clk),.rst(rst),.rx_data(rx_data),.rx_valid(rx_valid),
        .ready_request(ready_request),.frame_begin_valid(frame_begin_valid),
        .frame_id(frame_id),.image_index(image_index),.image_flags(image_flags),
        .image_total_words(image_total_words),.image_width(image_width),.image_height(image_height),
        .image_layout(),.image_window(),.image_generation(),.stream_start(stream_start),
        .stream_is_audio(stream_is_audio),.stream_word_count(stream_word_count),
        .stream_word_data(stream_word_data),.stream_word_valid(stream_word_valid),
        .stream_word_ready(raw_stream_ready),.stream_done(stream_done),
        .frame_end_valid(frame_end_valid),.frame_end_ok(frame_end_ok),
        .frame_end_reason(frame_end_reason),.frame_end_id(frame_end_id),
        .audio_begin_valid(audio_begin_valid),.audio_frame_id(audio_frame_id),
        .audio_sample_count(audio_sample_count),.audio_end_valid(audio_end_valid),
        .audio_end_ok(audio_end_ok),.audio_end_reason(audio_end_reason),.audio_end_id(audio_end_id),
        .protocol_error_toggle(protocol_error_toggle)
    );
    media_frame_pad #(.FRAME_WIDTH(11'd16),.FRAME_HEIGHT(10'd8),.FRAME_WORDS(21'd64)) u_frame_pad (
        .layout(2'd0),
        .clk(udp_clk),.rst(rst),.frame_begin(frame_begin_valid),
        .image_width(image_width),.image_height(image_height),.frame_end(frame_end_valid),
        .in_is_audio(stream_is_audio),.in_start(stream_start),.in_count(stream_word_count),
        .in_data(stream_word_data),.in_valid(stream_word_valid),.in_ready(raw_stream_ready),
        .in_done(stream_done),.out_start(padded_stream_start),.out_is_audio(padded_stream_audio),
        .out_count(padded_stream_count),.out_data(padded_stream_data),
        .out_valid(padded_stream_valid),.out_ready(padded_stream_ready),
        .out_done(padded_stream_done),.frame_done(pad_frame_done)
    );
    media_transaction_writer #(.DIRECT_STREAM(DIRECT_STREAM),.FRAME_WORDS(21'd64)) u_writer (
        .image_layout(2'd0),.image_window(2'd0),.view_target_buffer(1'b0),.write_layout(),.write_window(),
        .udp_clk(udp_clk),.udp_rst(rst),.frame_begin_valid(frame_begin_valid),
        .frame_id(frame_id),.image_index(image_index),.image_flags(image_flags),
        .image_total_words(image_total_words),.image_width(image_width),.image_height(image_height),
        .stream_start(padded_stream_start),
        .stream_is_audio(padded_stream_audio),.stream_word_count(padded_stream_count),
        .stream_word_data(padded_stream_data),.stream_word_valid(padded_stream_valid),
        .stream_word_ready(padded_stream_ready),.stream_done(padded_stream_done),
        .frame_end_valid(frame_end_valid),.frame_end_ok(frame_end_ok),
        .frame_end_reason(frame_end_reason),.frame_end_id(frame_end_id),
        .audio_begin_valid(audio_begin_valid),.audio_frame_id(audio_frame_id),
        .audio_sample_count(audio_sample_count),.audio_end_valid(audio_end_valid),
        .audio_end_ok(audio_end_ok),.audio_end_reason(audio_end_reason),.audio_end_id(audio_end_id),
        .write_clk(write_clk),.write_rst(rst),.frame_finish_toggle(finish_toggle),
        .effect_mode(2'd0),.transition_done_toggle(transition_done_toggle[0]),
        .display_valid(display_valid),.image_index_out(image_index_out),
        .image_width_out(image_width_out),.image_height_out(image_height_out),
        .image_has_wav(image_has_wav),.auto_play_status(auto_play_status),
        .display_buffer_index(display_buffer_index),.transition_start_toggle(transition_start_toggle),
        .transition_target_buf(transition_target_buf),.transition_mode_latched(transition_mode_latched),
        .transition_prev_latched(transition_prev_latched),.frame_commit_pulse(frame_commit_pulse),
        .write_req(write_req),.write_req_ack(write_req),.write_ready(1'b1),.write_buffer_index(write_buffer_index),
        .write_length(write_length),.write_row_offset(write_row_offset),
        .write_en(write_en),.write_data(write_data),
        .image_result_valid(image_result_valid),.image_result_code(image_result_code),
        .audio_result_valid(audio_result_valid),.audio_result_code(audio_result_code),
        .audio_pair_on(audio_pair_on),.audio_buffer_index(audio_buffer_index),
        .audio_buffer_length(audio_buffer_length),.audio_sample_count_out(audio_sample_count_out),
        .audio_source_toggle(audio_source_toggle)
    );
    media_display_tx #(.TX_GAP_CYCLES(4)) u_tx (
        .view_busy(1'b0),.view_prepare_valid(1'b0),.view_prepare_body(64'd0),.view_status_valid(1'b0),.view_status_body(128'd0),
        .clk(udp_clk),.rst(rst),.local_cmd_toggle_async(1'b0),.local_cmd_async(8'd0),
        .ready_valid(ready_request),.image_result_valid(image_result_valid),
        .image_result_code(image_result_code),.image_result_frame(frame_id),
        .audio_result_valid(audio_result_valid),.audio_result_code(audio_result_code),
        .audio_result_frame(frame_id),.control_ack_valid(1'b0),
        .control_ack_sequence(8'd0),.control_ack_op(8'd0),.control_ack_status(8'd0),
        .control_ack_value(8'd0),.status_valid(1'b0),.status_payload(64'd0),
        .tx_ready(chunk_ready),.tx_request(tx_request),.tx_valid(tx_valid),.tx_data(tx_data),
        .tx_length(tx_length),.tx_ack(tx_ack)
    );
    media_tx_mux u_tx_mux (
        .clk(udp_clk),.rst(rst),.stack_ready(1'b1),.stack_ack(stack_ack),
        .ctrl_req(1'b0),.ctrl_valid(1'b0),.ctrl_data(8'd0),.ctrl_length(16'd0),
        .ctrl_ready(),.ctrl_ack(),
        .chunk_req(tx_request),.chunk_valid(tx_valid),.chunk_data(tx_data),
        .chunk_length(tx_length),.chunk_ack(tx_ack),.chunk_ready(chunk_ready),
        .stack_req(stack_req),.stack_valid(stack_valid),.stack_data(stack_data),
        .stack_length(stack_length),.chunk_active(chunk_active),.chunk_owner()
    );
    always @(posedge udp_clk) begin
        if(stack_req && !stack_sending && !stack_ack) begin
            stack_ack<=1;
            stack_sending<=1;
            stack_bytes_expected<=stack_length;
            stack_bytes_sent<=0;
        end
        if(stack_valid && stack_sending) begin
            stack_bytes_sent<=stack_bytes_sent+16'd1;
            if(stack_bytes_sent+16'd1>=stack_bytes_expected)
                stack_sending<=0;
        end
        if(stack_ack && !stack_sending)
            stack_ack<=0;
    end

    integer output_packets=0,output_bytes=0,audio_i=0;
    reg output_in_packet=0;
    reg [7:0] packet_types[0:12];
    reg [7:0] packet_results[0:12];
    always @(posedge udp_clk) begin
        if(stack_valid) begin
            if(output_bytes==4) packet_types[output_packets]=stack_data;
            if(output_bytes==10) packet_results[output_packets]=stack_data;
            output_bytes=output_bytes+1;
            output_in_packet=1;
        end else if(output_in_packet) begin
            output_packets=output_packets+1;
            output_bytes=0;
            output_in_packet=0;
        end
    end

    always @(posedge write_clk) begin
        request_d<=write_req;
        if(write_req && !request_d) begin
            req_words<=write_length;
            req_buffer<=write_buffer_index;
            written_words<=0;
        end
        if(write_en) begin
            written_words<=written_words+21'd1;
            if(written_words+21'd1==req_words)
                finish_toggle<=~finish_toggle;
        end
    end

    task automatic send_byte(input [7:0] value);
        begin @(negedge udp_clk);rx_data=value;rx_valid=1;end
    endtask
    task automatic close_packet;
        begin @(negedge udp_clk);rx_valid=0;rx_data=0;repeat(20)@(negedge udp_clk);end
    endtask
    task automatic close_packet_drain;
        begin @(negedge udp_clk);rx_valid=0;rx_data=0;repeat(600)@(negedge udp_clk);end
    endtask
    task automatic header(input [7:0] kind,input [15:0] length);
        begin
            send_byte(8'haa);send_byte(8'hbb);send_byte(8'hcc);send_byte(8'hdd);
            send_byte(kind);send_byte(0);send_byte(length[7:0]);send_byte(length[15:8]);
        end
    endtask
    initial begin
        repeat(5)@(negedge udp_clk);rst=0;
        header(8'h20,0);close_packet();
        header(8'h21,16);send_byte(8'h34);send_byte(8'h12);send_byte(2);send_byte(8'h08);
        send_byte(3);send_byte(0);send_byte(0);send_byte(0);
        send_byte(2);send_byte(0);send_byte(3);send_byte(0);send_byte(0);send_byte(0);send_byte(0);send_byte(0);close_packet();
        header(8'h22,16);send_byte(8'h34);send_byte(8'h12);send_byte(0);send_byte(0);
        send_byte(8'h44);send_byte(8'h33);send_byte(8'h22);send_byte(8'h11);
        send_byte(8'h88);send_byte(8'h77);send_byte(8'h66);send_byte(8'h55);
        send_byte(8'hef);send_byte(8'hbe);send_byte(8'had);send_byte(8'hde);close_packet_drain();
        header(8'h23,8);send_byte(8'h34);send_byte(8'h12);send_byte(8'hbb);send_byte(8'h69);
        send_byte(8'h36);send_byte(8'h45);send_byte(0);send_byte(0);close_packet();
        wait(output_packets>=2);
        header(8'h30,8);send_byte(8'h34);send_byte(8'h12);send_byte(5);send_byte(0);
        send_byte(0);send_byte(0);send_byte(0);send_byte(0);close_packet();
        header(8'h31,9);send_byte(8'h34);send_byte(8'h12);send_byte(0);send_byte(0);
        send_byte(8'h80);send_byte(0);send_byte(8'hff);send_byte(8'h20);send_byte(8'h7f);close_packet();
        header(8'h32,8);send_byte(8'h34);send_byte(8'h12);send_byte(8'h1e);send_byte(8'h02);
        send_byte(0);send_byte(0);send_byte(0);send_byte(0);close_packet();
        wait(output_packets>=4);
        if(packet_types[0]!=8'h20 || packet_types[1]!=8'h24 || packet_results[1]!=0 ||
           packet_types[2]!=8'h33 || packet_results[2]!=0 ||
           packet_types[3]!=8'h24 || packet_results[3]!=2)
            $fatal(1,"response order/types %h %h %h %h",packet_types[0],packet_types[1],packet_types[2],packet_types[3]);
        if(!display_valid || image_index_out!=2 || !image_has_wav ||
           audio_buffer_index!=2 || audio_buffer_length!=256 || audio_sample_count_out!=5)
            $fatal(1,"final display metadata mismatch");
        if(req_buffer!=2 || req_words!=256) $fatal(1,"audio SDRAM transaction alignment");
        // The display repeats final RESULT=2 twice after the first copy. Drain
        // those idempotent replies before checking the next frame's rejection.
        wait(output_packets>=6);

        // A checksum failure returns 0x14 (reject + checksum reason 4), while
        // leaving the previously committed display image untouched.
        header(8'h21,16);send_byte(8'h35);send_byte(8'h12);send_byte(2);send_byte(8'h08);
        send_byte(3);send_byte(0);send_byte(0);send_byte(0);
        send_byte(2);send_byte(0);send_byte(3);send_byte(0);send_byte(0);send_byte(0);send_byte(0);send_byte(0);close_packet();
        header(8'h22,16);send_byte(8'h35);send_byte(8'h12);send_byte(0);send_byte(0);
        send_byte(8'h44);send_byte(8'h33);send_byte(8'h22);send_byte(8'h11);
        send_byte(8'h88);send_byte(8'h77);send_byte(8'h66);send_byte(8'h55);
        send_byte(8'hef);send_byte(8'hbe);send_byte(8'had);send_byte(8'hde);close_packet_drain();
        header(8'h23,8);send_byte(8'h35);send_byte(8'h12);send_byte(8'hba);send_byte(8'h69);
        send_byte(8'h36);send_byte(8'h45);send_byte(0);send_byte(0);close_packet();
        wait(output_packets>=7);
        if(packet_types[6]!=8'h24 || packet_results[6]!=8'h14)
            $fatal(1,"bad frame did not report checksum reject: type=%02x result=%02x",
                   packet_types[6],packet_results[6]);
        if(!display_valid || image_index_out!=2)
            $fatal(1,"rejected frame replaced committed image");

        // A valid image followed by a wrong PCM checksum returns audio reason
        // 5 through writer CDC and media_display_tx as AUDIO_RESULT=0x15.
        header(8'h21,16);send_byte(8'h36);send_byte(8'h12);send_byte(2);send_byte(8'h08);
        send_byte(3);send_byte(0);send_byte(0);send_byte(0);
        send_byte(2);send_byte(0);send_byte(3);send_byte(0);send_byte(0);send_byte(0);send_byte(0);send_byte(0);close_packet();
        header(8'h22,16);send_byte(8'h36);send_byte(8'h12);send_byte(0);send_byte(0);
        send_byte(8'h44);send_byte(8'h33);send_byte(8'h22);send_byte(8'h11);
        send_byte(8'h88);send_byte(8'h77);send_byte(8'h66);send_byte(8'h55);
        send_byte(8'hef);send_byte(8'hbe);send_byte(8'had);send_byte(8'hde);close_packet_drain();
        header(8'h23,8);send_byte(8'h36);send_byte(8'h12);send_byte(8'hbb);send_byte(8'h69);
        send_byte(8'h36);send_byte(8'h45);send_byte(0);send_byte(0);close_packet();
        wait(output_packets>=8);
        header(8'h30,8);send_byte(8'h36);send_byte(8'h12);send_byte(0);send_byte(4);
        send_byte(0);send_byte(0);send_byte(0);send_byte(0);close_packet();
        // Match the production 1012-sample packet boundary and a short final
        // packet, as used by the 480000-sample IMG0.WAV file.
        header(8'h31,1016);send_byte(8'h36);send_byte(8'h12);send_byte(0);send_byte(0);
        for (audio_i=0;audio_i<1012;audio_i=audio_i+1) send_byte(1);
        close_packet_drain();
        header(8'h31,16);send_byte(8'h36);send_byte(8'h12);send_byte(1);send_byte(0);
        for (audio_i=0;audio_i<12;audio_i=audio_i+1) send_byte(2);
        close_packet();
        header(8'h32,8);send_byte(8'h36);send_byte(8'h12);send_byte(8'h0d);send_byte(8'h04);
        send_byte(0);send_byte(0);send_byte(0);send_byte(0);close_packet();
        wait(output_packets>=9);
        if(packet_types[8]!=8'h33 || packet_results[8]!=8'h15)
            $fatal(1,"audio checksum reject reason was not preserved: type=%02x result=%02x",
                   packet_types[8],packet_results[8]);
        if(image_index_out!=2 || !image_has_wav)
            $fatal(1,"audio reject committed partial image metadata");
        $display("PASS: image commit/reject and audio checksum reason round-trip");
        $finish;
    end
    initial begin
        #20000000;
        $fatal(1,"timeout rx_active=%0d rx_bad=%0d rx_words=%0d/%0d pad=%0d xy=%0d,%0d raw=%0d cache=%0d writer=%0d req=%0d issued=%0d end=%0d/%0d write_done=%0d packets=%0d",
               u_rx.frame_active,u_rx.frame_bad,u_rx.received_image_words,u_rx.image_total_words,
               u_frame_pad.frame_active,u_frame_pad.x,u_frame_pad.y,0,
               u_frame_pad.source_word_valid,u_writer.writer_state,u_writer.write_req,
               u_writer.frame_words_issued,u_writer.frame_end_seen_w,u_writer.frame_end_good_w,
               u_writer.frame_write_done,output_packets);
    end
endmodule
