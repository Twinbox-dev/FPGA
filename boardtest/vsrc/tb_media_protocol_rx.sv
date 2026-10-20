`timescale 1ns/1ps

module tb_media_protocol_rx;
    reg clk = 0;
    always #5 clk = ~clk;
    reg rst = 1;
    reg [7:0] rx_data = 0;
    reg rx_valid = 0;
    wire ready_request, frame_begin_valid;
    wire [15:0] frame_id;
    wire [4:0] image_index;
    wire [7:0] image_flags;
    wire [20:0] image_total_words;
    wire stream_start, stream_is_audio;
    wire [8:0] stream_word_count;
    wire [31:0] stream_word_data;
    wire stream_word_valid, stream_done;
    wire frame_end_valid, frame_end_ok;
    wire [15:0] frame_end_id;
    wire audio_begin_valid;
    wire [15:0] audio_frame_id;
    wire [31:0] audio_sample_count;
    wire audio_end_valid, audio_end_ok;
    wire [15:0] audio_end_id;
    wire protocol_error_toggle;

    media_protocol_rx #(.FRAME_WORDS(21'd3)) dut (
        .clk(clk), .rst(rst), .rx_data(rx_data), .rx_valid(rx_valid),
        .ready_request(ready_request), .frame_begin_valid(frame_begin_valid),
        .frame_id(frame_id), .image_index(image_index), .image_flags(image_flags),
        .image_total_words(image_total_words), .stream_start(stream_start),
        .stream_is_audio(stream_is_audio), .stream_word_count(stream_word_count),
        .stream_word_data(stream_word_data), .stream_word_valid(stream_word_valid),
        .stream_word_ready(1'b1), .stream_done(stream_done),
        .frame_end_valid(frame_end_valid), .frame_end_ok(frame_end_ok),
        .frame_end_id(frame_end_id), .audio_begin_valid(audio_begin_valid),
        .audio_frame_id(audio_frame_id), .audio_sample_count(audio_sample_count),
        .audio_end_valid(audio_end_valid), .audio_end_ok(audio_end_ok),
        .audio_end_id(audio_end_id), .protocol_error_toggle(protocol_error_toggle)
    );

    integer image_words_seen = 0;
    integer audio_words_seen = 0;
    integer stream_done_count = 0;
    reg frame_end_seen = 0;
    reg audio_end_seen = 0;
    reg bad_end_seen = 0;
    reg ready_seen = 0;
    reg begin_seen = 0;
    reg audio_begin_seen = 0;

    always @(posedge clk) begin
        if (ready_request) ready_seen <= 1;
        if (frame_begin_valid) begin
            if (frame_id != 16'h1234 && frame_id != 16'h1235) $fatal(1, "frame id %h", frame_id);
            if (image_index != 5'd2 || image_total_words != 21'd3 || image_flags != 8'h08)
                $fatal(1, "image BEGIN metadata mismatch");
            begin_seen <= 1;
        end
        if (audio_begin_valid) begin
            if (audio_frame_id != 16'h1234 || audio_sample_count != 32'd5)
                $fatal(1, "audio BEGIN metadata mismatch");
            audio_begin_seen <= 1;
        end
        if (stream_start) begin
            if (stream_is_audio) begin
                if (stream_word_count != 2) $fatal(1, "audio word count %0d", stream_word_count);
            end else if (stream_word_count != 3) begin
                $fatal(1, "image word count %0d", stream_word_count);
            end
        end
        if (stream_word_valid) begin
            if (!stream_is_audio && frame_id == 16'h1234) begin
                case (image_words_seen)
                    0: if (stream_word_data !== 32'h11223344) $fatal(1, "image word0 %h", stream_word_data);
                    1: if (stream_word_data !== 32'h55667788) $fatal(1, "image word1 %h", stream_word_data);
                    2: if (stream_word_data !== 32'hdeadbeef) $fatal(1, "image word2 %h", stream_word_data);
                    default: $fatal(1, "too many image words");
                endcase
                image_words_seen <= image_words_seen + 1;
            end else if (stream_is_audio) begin
                case (audio_words_seen)
                    0: if (stream_word_data !== 32'h20ff0080) $fatal(1, "audio word0 %h", stream_word_data);
                    1: if (stream_word_data !== 32'h8080807f) $fatal(1, "audio word1 %h", stream_word_data);
                    default: $fatal(1, "too many audio words");
                endcase
                audio_words_seen <= audio_words_seen + 1;
            end
        end
        if (stream_done) stream_done_count <= stream_done_count + 1;
        if (frame_end_valid) begin
            if (frame_end_id == 16'h1234 && !frame_end_ok) $fatal(1, "valid image rejected");
            if (frame_end_id == 16'h1235 && frame_end_ok) $fatal(1, "bad checksum accepted");
            if (frame_end_id == 16'h1234) frame_end_seen <= 1;
            if (frame_end_id == 16'h1235) bad_end_seen <= 1;
        end
        if (audio_end_valid) begin
            if (audio_end_id != 16'h1234 || !audio_end_ok) $fatal(1, "audio END rejected");
            audio_end_seen <= 1;
        end
    end

    task automatic send_byte(input [7:0] value);
        begin
            @(negedge clk); rx_data = value; rx_valid = 1;
        end
    endtask

    task automatic close_packet;
        begin
            @(negedge clk); rx_valid = 0; rx_data = 0;
            repeat (20) @(negedge clk);
        end
    endtask

    task automatic header(input [7:0] kind, input [15:0] length);
        begin
            send_byte(8'haa); send_byte(8'hbb); send_byte(8'hcc); send_byte(8'hdd);
            send_byte(kind); send_byte(8'h00);
            send_byte(length[7:0]); send_byte(length[15:8]);
        end
    endtask

    task automatic send_image(input [15:0] id, input corrupt_checksum);
        begin
            header(8'h21, 16'd8);
            send_byte(id[7:0]); send_byte(id[15:8]); send_byte(8'd2); send_byte(8'h08);
            send_byte(8'd3); send_byte(8'd0); send_byte(8'd0); send_byte(8'd0);
            close_packet();
            header(8'h22, 16'd16);
            send_byte(id[7:0]); send_byte(id[15:8]); send_byte(8'd0); send_byte(8'd0);
            send_byte(8'h44); send_byte(8'h33); send_byte(8'h22); send_byte(8'h11);
            send_byte(8'h88); send_byte(8'h77); send_byte(8'h66); send_byte(8'h55);
            send_byte(8'hef); send_byte(8'hbe); send_byte(8'had); send_byte(8'hde);
            close_packet();
            header(8'h23, 16'd8);
            send_byte(id[7:0]); send_byte(id[15:8]);
            send_byte(corrupt_checksum ? 8'hba : 8'hbb);
            send_byte(8'h69); send_byte(8'h36); send_byte(8'h45);
            send_byte(8'd0); send_byte(8'd0);
            close_packet();
        end
    endtask

    initial begin
        repeat (4) @(negedge clk); rst = 0;
        header(8'h20, 16'd0); close_packet();
        wait (ready_seen);

        send_image(16'h1234, 1'b0);
        wait (frame_end_seen);
        if (!begin_seen) $fatal(1, "BEGIN metadata missing");

        header(8'h30, 16'd8);
        send_byte(8'h34); send_byte(8'h12);
        send_byte(8'd5); send_byte(8'd0); send_byte(8'd0); send_byte(8'd0);
        send_byte(8'd0); send_byte(8'd0);
        close_packet();
        header(8'h31, 16'd9);
        send_byte(8'h34); send_byte(8'h12); send_byte(8'd0); send_byte(8'd0);
        send_byte(8'h80); send_byte(8'h00); send_byte(8'hff); send_byte(8'h20); send_byte(8'h7f);
        close_packet();
        header(8'h32, 16'd8);
        send_byte(8'h34); send_byte(8'h12);
        send_byte(8'h1e); send_byte(8'h02); send_byte(8'd0); send_byte(8'd0);
        send_byte(8'd0); send_byte(8'd0);
        close_packet();
        wait (audio_end_seen);
        if (!audio_begin_seen) $fatal(1, "audio BEGIN missing");

        send_image(16'h1235, 1'b1);
        wait (bad_end_seen);
        if (image_words_seen != 3 || audio_words_seen != 2 || stream_done_count != 3)
            $fatal(1, "stream totals img=%0d audio=%0d done=%0d",
                   image_words_seen, audio_words_seen, stream_done_count);
        $display("PASS: READY, image sequencing/checksum, PCM packing/checksum, reject bad image checksum");
        $finish;
    end

    initial begin
        #2000000;
        $fatal(1, "timeout");
    end
endmodule
