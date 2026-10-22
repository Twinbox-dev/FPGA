`timescale 1ns/1ps
module tb_media_frame_format;
    reg clk = 0;
    always #5 clk = ~clk;

    reg rst = 1;
    reg start = 0;
    reg abort = 0;
    reg [11:0] image_width = 0;
    reg [11:0] image_height = 0;
    reg pixel_valid = 0;
    reg [15:0] pixel_data = 0;
    wire pixel_pause;
    wire [31:0] word_data;
    wire word_valid;
    reg word_ready = 0;
    wire active, done, error;
    wire [31:0] checksum;

    media_frame_format dut (
        .clk(clk), .rst(rst), .start(start), .abort(abort),
        .image_width(image_width), .image_height(image_height),
        .pixel_valid(pixel_valid), .pixel_data(pixel_data), .pixel_pause(pixel_pause),
        .word_data(word_data), .word_valid(word_valid), .word_ready(word_ready),
        .active(active), .done(done), .error(error), .checksum(checksum)
    );

    integer width_cfg, height_cfg;
    integer expected_word_total;
    integer received_words = 0;
    integer cycles = 0;
    integer pixel_x;
    reg [15:0] expected_low, expected_high;
    reg [31:0] expected_word, expected_sum = 0;

    function automatic [15:0] expected_pixel(input integer index);
        begin
            // The formatter now emits only source RGB565 pixels in BMP order.
            expected_pixel = (index + 1) & 16'hffff;
        end
    endfunction

    always @(negedge clk) begin
        if (!rst && active) begin
            cycles = cycles + 1;
            // A packet/FIFO-like sink that regularly applies backpressure.
            word_ready = (cycles % 10) < 6;
            if (word_valid && word_ready) begin
                pixel_x = received_words * 2;
                expected_low = expected_pixel(pixel_x);
                expected_high = (pixel_x + 1 < width_cfg * height_cfg) ?
                                expected_pixel(pixel_x + 1) : 16'd0;
                expected_word = {expected_high, expected_low};
                if (word_data !== expected_word) begin
                    $display("FAIL %0dx%0d word %0d: got %08x expected %08x (x=%0d y=%0d)",
                             width_cfg, height_cfg, received_words, word_data,
                             expected_word, pixel_x, received_words*2 / width_cfg);
                    $fatal(1);
                end
                expected_sum = expected_sum + expected_word;
                received_words = received_words + 1;
            end
        end else begin
            word_ready = 0;
        end
    end

    task automatic run_case(input integer w, input integer h);
        integer sent_pixels;
        integer sector_pixels;
        integer local_index;
        integer watchdog;
        begin
            width_cfg = w;
            height_cfg = h;
            expected_word_total = (w * h + 1) / 2;
            received_words = 0;
            expected_sum = 0;
            cycles = 0;
            sent_pixels = 0;

            @(negedge clk);
            image_width = w;
            image_height = h;
            start = 1;
            @(negedge clk);
            start = 0;

            // FAT32 flow control pauses before a new sector, while at most
            // 512 bytes (~171 RGB888 pixels) from the in-flight sector remain.
            while (sent_pixels < w * h) begin
                while (pixel_pause) @(negedge clk);
                sector_pixels = (w * h - sent_pixels > 171) ? 171 : (w * h - sent_pixels);
                for (local_index = 0; local_index < sector_pixels; local_index = local_index + 1) begin
                    @(negedge clk);
                    pixel_valid = 1;
                    pixel_data = (sent_pixels + local_index + 1) & 16'hffff;
                end
                @(negedge clk);
                pixel_valid = 0;
                sent_pixels = sent_pixels + sector_pixels;
            end

            watchdog = 0;
            while (!done && watchdog < 3000000) begin
                @(negedge clk);
                watchdog = watchdog + 1;
            end
            if (!done) $fatal(1, "timeout for %0dx%0d", w, h);
            if (error) $fatal(1, "formatter error for %0dx%0d", w, h);
            if (received_words != expected_word_total)
                $fatal(1, "word count %0d expected %0d for %0dx%0d",
                       received_words, expected_word_total, w, h);
            if (checksum !== expected_sum)
                $fatal(1, "checksum got %08x expected %08x for %0dx%0d",
                       checksum, expected_sum, w, h);
            $display("PASS: %0dx%0d -> %0d raw words, pixel order/tail exact, checksum=%08x",
                     w, h, received_words, checksum);

            @(negedge clk);
            rst = 1;
            pixel_valid = 0;
            start = 0;
            repeat (3) @(negedge clk);
            rst = 0;
            repeat (3) @(negedge clk);
        end
    endtask

    initial begin
        repeat (4) @(negedge clk);
        rst = 0;
        repeat (3) @(negedge clk);
        run_case(1280, 720);
        run_case(640, 480);
        run_case(333, 217);
        $display("PASS: all media frame formatter cases");
        $finish;
    end
endmodule
