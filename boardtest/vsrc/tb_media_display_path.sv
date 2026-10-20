`timescale 1ns/1ps

module tb_media_display_path;
    reg udp_clk=0, write_clk=0;
    always #4 udp_clk=~udp_clk;
    always #5 write_clk=~write_clk;
    reg rst=1;
    reg [7:0] rx_data=0;
    reg rx_valid=0;
    wire ready_request,frame_begin_valid;
    wire [15:0] frame_id;
    wire [4:0] image_index;
    wire [7:0] image_flags;
    wire [20:0] image_total_words;
    wire stream_start,stream_is_audio,stream_word_valid,stream_done;
    wire [8:0] stream_word_count;
    wire [31:0] stream_word_data;
    wire stream_word_ready;
    wire frame_end_valid,frame_end_ok;
    wire [15:0] frame_end_id,audio_frame_id,audio_end_id;
    wire audio_begin_valid,audio_end_valid,audio_end_ok;
    wire [31:0] audio_sample_count;
    wire protocol_error_toggle;
    wire display_valid,image_has_wav,auto_play_status;
    wire [4:0] image_index_out;
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
        .image_total_words(image_total_words),.stream_start(stream_start),
        .stream_is_audio(stream_is_audio),.stream_word_count(stream_word_count),
        .stream_word_data(stream_word_data),.stream_word_valid(stream_word_valid),
        .stream_word_ready(stream_word_ready),.stream_done(stream_done),
        .frame_end_valid(frame_end_valid),.frame_end_ok(frame_end_ok),.frame_end_id(frame_end_id),
        .audio_begin_valid(audio_begin_valid),.audio_frame_id(audio_frame_id),
        .audio_sample_count(audio_sample_count),.audio_end_valid(audio_end_valid),
        .audio_end_ok(audio_end_ok),.audio_end_id(audio_end_id),
        .protocol_error_toggle(protocol_error_toggle)
    );
    media_transaction_writer #(.FRAME_WORDS(21'd3)) u_writer (
        .udp_clk(udp_clk),.udp_rst(rst),.frame_begin_valid(frame_begin_valid),
        .frame_id(frame_id),.image_index(image_index),.image_flags(image_flags),
        .image_total_words(image_total_words),.stream_start(stream_start),
        .stream_is_audio(stream_is_audio),.stream_word_count(stream_word_count),
        .stream_word_data(stream_word_data),.stream_word_valid(stream_word_valid),
        .stream_word_ready(stream_word_ready),.stream_done(stream_done),
        .frame_end_valid(frame_end_valid),.frame_end_ok(frame_end_ok),.frame_end_id(frame_end_id),
        .audio_begin_valid(audio_begin_valid),.audio_frame_id(audio_frame_id),
        .audio_sample_count(audio_sample_count),.audio_end_valid(audio_end_valid),
        .audio_end_ok(audio_end_ok),.audio_end_id(audio_end_id),
        .write_clk(write_clk),.write_rst(rst),.frame_finish_toggle(finish_toggle),
        .effect_mode(2'd0),.transition_done_toggle(transition_done_toggle[0]),
        .display_valid(display_valid),.image_index_out(image_index_out),
        .image_has_wav(image_has_wav),.auto_play_status(auto_play_status),
        .display_buffer_index(display_buffer_index),.transition_start_toggle(transition_start_toggle),
        .transition_target_buf(transition_target_buf),.transition_mode_latched(transition_mode_latched),
        .transition_prev_latched(transition_prev_latched),.frame_commit_pulse(frame_commit_pulse),
        .write_req(write_req),.write_req_ack(write_req),.write_buffer_index(write_buffer_index),
        .write_length(write_length),.write_row_offset(write_row_offset),
        .write_en(write_en),.write_data(write_data),
        .image_result_valid(image_result_valid),.image_result_code(image_result_code),
        .audio_result_valid(audio_result_valid),.audio_result_code(audio_result_code),
        .audio_pair_on(audio_pair_on),.audio_buffer_index(audio_buffer_index),
        .audio_buffer_length(audio_buffer_length),.audio_sample_count_out(audio_sample_count_out),
        .audio_source_toggle(audio_source_toggle)
    );
    media_display_tx #(.TX_GAP_CYCLES(4)) u_tx (
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
        .stack_length(stack_length),.chunk_active(chunk_active)
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

    integer output_packets=0,output_bytes=0;
    reg output_in_packet=0;
    reg [7:0] packet_types[0:3];
    reg [7:0] packet_results[0:3];
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
    task automatic header(input [7:0] kind,input [15:0] length);
        begin
            send_byte(8'haa);send_byte(8'hbb);send_byte(8'hcc);send_byte(8'hdd);
            send_byte(kind);send_byte(0);send_byte(length[7:0]);send_byte(length[15:8]);
        end
    endtask
    initial begin
        repeat(5)@(negedge udp_clk);rst=0;
        header(8'h20,0);close_packet();
        header(8'h21,8);send_byte(8'h34);send_byte(8'h12);send_byte(2);send_byte(8'h08);
        send_byte(3);send_byte(0);send_byte(0);send_byte(0);close_packet();
        header(8'h22,16);send_byte(8'h34);send_byte(8'h12);send_byte(0);send_byte(0);
        send_byte(8'h44);send_byte(8'h33);send_byte(8'h22);send_byte(8'h11);
        send_byte(8'h88);send_byte(8'h77);send_byte(8'h66);send_byte(8'h55);
        send_byte(8'hef);send_byte(8'hbe);send_byte(8'had);send_byte(8'hde);close_packet();
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
        $display("PASS: formal packets flow through parser, frame/audio SDRAM writer, commit and replies");
        $finish;
    end
    initial begin #20000000;$fatal(1,"timeout");end
endmodule
