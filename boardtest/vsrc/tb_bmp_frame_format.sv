`timescale 1ns/1ps
module tb_bmp_frame_format;
    reg clk = 0;
    always #5 clk = ~clk;

    reg rst = 1, restart = 0;
    reg [7:0] byte_data = 0;
    reg byte_valid = 0;
    wire pix_valid, hdr_ok, img_ok, img_error;
    wire [23:0] pixel_rgb;
    wire [11:0] parsed_width, parsed_height;
    wire [7:0] parser_state;

    reg format_start = 0;
    wire pixel_pause;
    wire [31:0] word_data, checksum;
    wire word_valid, active, done, format_error;
    reg word_ready = 0;
    wire [31:0] format_width;

    reg [7:0] bmp_bytes [0:3000000];
    string bmp_path;
    integer fd, byte_count;
    integer width_cfg, height_cfg, data_offset, row_stride;
    integer cycles = 0, received_words = 0, pixel_x, pixel_y, byte_offset;
    integer pixel_index;
    reg [15:0] expected_low, expected_high;
    reg [31:0] expected_word, expected_sum = 0;

    bmp_dec u_bmp (
        .clk(clk), .rst_n(~rst), .i_byte(byte_data), .i_bval(byte_valid),
        .i_restart(restart), .o_pix_val(pix_valid), .o_pix(pixel_rgb),
        .o_img_w(parsed_width), .o_img_h(parsed_height), .o_hdr_ok(hdr_ok),
        .o_img_ok(img_ok), .o_img_err(img_error), .o_dbg_state(parser_state)
    );

    media_frame_format u_format (
        .clk(clk), .rst(rst), .start(format_start), .abort(1'b0),
        .image_width(width_cfg[11:0]), .image_height(height_cfg[11:0]),
        .pixel_valid(pix_valid), .pixel_data({pixel_rgb[23:19],pixel_rgb[15:10],pixel_rgb[7:3]}),
        .pixel_pause(pixel_pause), .word_data(word_data), .word_valid(word_valid),
        .word_ready(word_ready), .active(active), .done(done), .error(format_error),
        .checksum(checksum)
    );

    function automatic [15:0] bmp_rgb565(input integer x, input integer row);
        integer p;
        reg [7:0] blue, green, red;
        begin
            p = data_offset + row * row_stride + x * 3;
            blue = bmp_bytes[p];
            green = bmp_bytes[p+1];
            red = bmp_bytes[p+2];
            bmp_rgb565 = {red[7:3], green[7:2], blue[7:3]};
        end
    endfunction

    always @(negedge clk) begin
        if (!rst && active) begin
            cycles = cycles + 1;
            word_ready = (cycles % 10) < 6;
            if (word_valid && word_ready) begin
                pixel_index = received_words * 2;
                pixel_x = pixel_index % width_cfg;
                pixel_y = pixel_index / width_cfg;
                expected_low = bmp_rgb565(pixel_x, pixel_y);
                if (pixel_index + 1 < width_cfg * height_cfg) begin
                    pixel_x = (pixel_index + 1) % width_cfg;
                    pixel_y = (pixel_index + 1) / width_cfg;
                    expected_high = bmp_rgb565(pixel_x, pixel_y);
                end else expected_high = 16'd0;
                expected_word = {expected_high, expected_low};
                if (word_data !== expected_word) begin
                    $display("FAIL %s raw word %0d: got %08x expected %08x at pixel %0d",
                             bmp_path, received_words, word_data, expected_word, pixel_index);
                    $fatal(1);
                end
                expected_sum = expected_sum + expected_word;
                received_words = received_words + 1;
            end
        end else word_ready = 0;
    end

    task automatic send_byte(input integer index);
        begin
            @(negedge clk);
            byte_data = bmp_bytes[index];
            byte_valid = 1;
        end
    endtask

    integer i, sector_end, watchdog;
    initial begin
        if (!$value$plusargs("BMP=%s", bmp_path)) $fatal(1, "pass +BMP=path");
        fd = $fopen(bmp_path, "rb");
        if (!fd) $fatal(1, "cannot open BMP %s", bmp_path);
        byte_count = $fread(bmp_bytes, fd);
        $fclose(fd);
        if (byte_count < 54 || bmp_bytes[0] != 8'h42 || bmp_bytes[1] != 8'h4d)
            $fatal(1, "invalid BMP %s", bmp_path);
        data_offset = {bmp_bytes[13],bmp_bytes[12],bmp_bytes[11],bmp_bytes[10]};
        width_cfg = {bmp_bytes[21],bmp_bytes[20],bmp_bytes[19],bmp_bytes[18]};
        height_cfg = {bmp_bytes[25],bmp_bytes[24],bmp_bytes[23],bmp_bytes[22]};
        row_stride = ((width_cfg * 3 + 3) / 4) * 4;

        repeat (4) @(negedge clk);
        rst = 0;
        @(negedge clk);
        format_start = 1;
        restart = 1;
        @(negedge clk);
        format_start = 0;
        restart = 0;

        // Reproduce FAT's file-byte stream and sector-boundary backpressure.
        for (i = 0; i < byte_count; i = sector_end) begin
            while (pixel_pause) @(negedge clk);
            sector_end = (i + 512 < byte_count) ? i + 512 : byte_count;
            for (; i < sector_end; i = i + 1) send_byte(i);
            @(negedge clk);
            byte_valid = 0;
        end

        watchdog = 0;
        while (!img_ok && !img_error && watchdog < 1000000) begin
            @(negedge clk);
            watchdog = watchdog + 1;
        end
        if (!img_ok || img_error) $fatal(1, "BMP parser did not finish cleanly (%s)", bmp_path);
        watchdog = 0;
        while (!done && watchdog < 3000000) begin
            @(negedge clk);
            watchdog = watchdog + 1;
        end
        if (!done) $fatal(1, "formatter timeout (%s)", bmp_path);
        if (format_error) $fatal(1, "formatter overflow (%s)", bmp_path);
        if (received_words != (width_cfg * height_cfg + 1) / 2)
            $fatal(1, "got %0d words, expected %0d (%s)", received_words,
                   (width_cfg * height_cfg + 1) / 2, bmp_path);
        if (checksum !== expected_sum)
            $fatal(1, "checksum mismatch got=%08x expected=%08x (%s)", checksum, expected_sum, bmp_path);
        $display("PASS: %s %0dx%0d BMP parser + sector pause + raw RGB565 stream exact, checksum=%08x",
                 bmp_path, width_cfg, height_cfg, checksum);
        $finish;
    end

    initial begin #200000000; $fatal(1, "timeout"); end
endmodule
