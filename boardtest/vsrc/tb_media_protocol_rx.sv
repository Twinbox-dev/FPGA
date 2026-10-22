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
    wire [11:0] image_width,image_height;
    wire [7:0] image_layout,image_window;
    wire [15:0] image_generation;
    wire stream_start, stream_is_audio;
    wire [8:0] stream_word_count;
    wire [31:0] stream_word_data;
    wire stream_word_valid, stream_done;
    wire frame_end_valid, frame_end_ok;
    wire [3:0] frame_end_reason;
    wire [15:0] frame_end_id;
    wire audio_begin_valid;
    wire [15:0] audio_frame_id;
    wire [31:0] audio_sample_count;
    wire audio_end_valid, audio_end_ok;
    wire [3:0] audio_end_reason;
    wire [15:0] audio_end_id;
    wire protocol_error_toggle;

    media_protocol_rx #(.FRAME_WORDS(21'd8)) dut (
        .clk(clk), .rst(rst), .rx_data(rx_data), .rx_valid(rx_valid),
        .ready_request(ready_request), .frame_begin_valid(frame_begin_valid),
        .frame_id(frame_id), .image_index(image_index), .image_flags(image_flags),
        .image_total_words(image_total_words),.image_width(image_width),.image_height(image_height),
        .image_layout(image_layout),.image_window(image_window),.image_generation(image_generation),
        .stream_start(stream_start),
        .stream_is_audio(stream_is_audio), .stream_word_count(stream_word_count),
        .stream_word_data(stream_word_data), .stream_word_valid(stream_word_valid),
        .stream_word_ready(1'b1), .stream_done(stream_done),
        .frame_end_valid(frame_end_valid), .frame_end_ok(frame_end_ok),
        .frame_end_reason(frame_end_reason), .frame_end_id(frame_end_id),
        .audio_begin_valid(audio_begin_valid),
        .audio_frame_id(audio_frame_id), .audio_sample_count(audio_sample_count),
        .audio_end_valid(audio_end_valid), .audio_end_ok(audio_end_ok),.audio_end_reason(audio_end_reason),
        .audio_end_id(audio_end_id), .protocol_error_toggle(protocol_error_toggle)
    );

    integer image_words_seen = 0;
    integer audio_words_seen = 0;
    integer stream_done_count = 0;
    integer odd_words_seen = 0;
    reg frame_end_seen = 0;
    reg audio_end_seen = 0;
    reg bad_end_seen = 0;
    reg odd_end_seen = 0;
    reg ready_seen = 0;
    reg begin_seen = 0;
    reg audio_begin_seen = 0;

    always @(posedge clk) begin
        if (ready_request) ready_seen <= 1;
        if (frame_begin_valid) begin
            if (frame_id != 16'h1234 && frame_id != 16'h1235 && frame_id != 16'h1236)
                $fatal(1, "frame id %h", frame_id);
            if (image_index != 5'd2 || image_flags != 8'h08 || image_layout != 0 ||
                image_window != 0 || image_generation != 0)
                $fatal(1, "image BEGIN metadata mismatch");
            if (frame_id != 16'h1236 &&
                (image_total_words != 21'd3 || image_width != 12'd2 || image_height != 12'd3))
                $fatal(1,"even image dimensions/count mismatch");
            if (frame_id == 16'h1236 &&
                (image_total_words != 21'd5 || image_width != 12'd3 || image_height != 12'd3))
                $fatal(1,"odd image dimensions/count mismatch");
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
            end else if (stream_word_count != 3 &&
                         !(frame_id==16'h1236 && stream_word_count==5)) begin
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
            end else if (frame_id==16'h1236) begin
                case(odd_words_seen)
                    0: if(stream_word_data!==32'h11223344) $fatal(1,"odd word0");
                    1: if(stream_word_data!==32'h55667788) $fatal(1,"odd word1");
                    2: if(stream_word_data!==32'hdeadbeef) $fatal(1,"odd word2");
                    3: if(stream_word_data!==32'h01020304) $fatal(1,"odd word3");
                    4: if(stream_word_data!==32'h05060708) $fatal(1,"odd word4");
                    default:$fatal(1,"too many odd image words");
                endcase
                odd_words_seen <= odd_words_seen + 1;
            end
        end
        if (stream_done) stream_done_count <= stream_done_count + 1;
        if (frame_end_valid) begin
            if (frame_end_id == 16'h1234 && !frame_end_ok) $fatal(1, "valid image rejected");
            if (frame_end_id == 16'h1235 && frame_end_ok) $fatal(1, "bad checksum accepted");
            if (frame_end_id == 16'h1234 && frame_end_reason != 4'd0)
                $fatal(1, "good frame reported reason %0d", frame_end_reason);
            if (frame_end_id == 16'h1235 && frame_end_reason != 4'd4)
                $fatal(1, "checksum failure reported reason %0d", frame_end_reason);
            if (frame_end_id == 16'h1236 && !frame_end_ok)
                $fatal(1,"valid odd-pixel frame rejected reason=%0d",frame_end_reason);
            if (frame_end_id == 16'h1234) frame_end_seen <= 1;
            if (frame_end_id == 16'h1235) bad_end_seen <= 1;
            if (frame_end_id == 16'h1236) odd_end_seen <= 1;
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
            header(8'h21, 16'd16);
            send_byte(id[7:0]); send_byte(id[15:8]); send_byte(8'd2); send_byte(8'h08);
            send_byte(8'd3); send_byte(8'd0); send_byte(8'd0); send_byte(8'd0);
            send_byte(8'd2); send_byte(8'd0); send_byte(8'd3); send_byte(8'd0);
            send_byte(8'd0); send_byte(8'd0); send_byte(8'd0); send_byte(8'd0);
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

    task automatic send_odd_image;
        reg [31:0] sum;
        begin
            sum=32'h11223344+32'h55667788+32'hdeadbeef+32'h01020304+32'h05060708;
            header(8'h21,16'd16);
            send_byte(8'h36);send_byte(8'h12);send_byte(8'd2);send_byte(8'h08);
            send_byte(8'd5);send_byte(8'd0);send_byte(8'd0);send_byte(8'd0);
            send_byte(8'd3);send_byte(8'd0);send_byte(8'd3);send_byte(8'd0);
            send_byte(8'd0);send_byte(8'd0);send_byte(8'd0);send_byte(8'd0);
            close_packet();
            header(8'h22,16'd24);send_byte(8'h36);send_byte(8'h12);send_byte(0);send_byte(0);
            send_byte(8'h44);send_byte(8'h33);send_byte(8'h22);send_byte(8'h11);
            send_byte(8'h88);send_byte(8'h77);send_byte(8'h66);send_byte(8'h55);
            send_byte(8'hef);send_byte(8'hbe);send_byte(8'had);send_byte(8'hde);
            send_byte(8'h04);send_byte(8'h03);send_byte(8'h02);send_byte(8'h01);
            send_byte(8'h08);send_byte(8'h07);send_byte(8'h06);send_byte(8'h05);
            close_packet();
            header(8'h23,16'd8);send_byte(8'h36);send_byte(8'h12);
            send_byte(sum[7:0]);send_byte(sum[15:8]);send_byte(sum[23:16]);send_byte(sum[31:24]);
            send_byte(0);send_byte(0);close_packet();
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
        send_odd_image();
        wait(odd_end_seen);
        if(odd_words_seen!=5) $fatal(1,"odd image word count %0d",odd_words_seen);
        $display("PASS: READY, variable dimensions, odd-pixel frame, image checksum and PCM integrity");
        $finish;
    end

    initial begin
        #2000000;
        $fatal(1, "timeout");
    end
endmodule
