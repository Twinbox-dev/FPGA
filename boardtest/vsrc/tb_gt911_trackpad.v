`timescale 1ns/1ps
// A GT911 register-level I2C model exercises NACK fallback, ID validation,
// status clear, contact anchoring, relative movement and release.
module tb_gt911_trackpad;
    reg clk = 1'b0;
    always #5 clk = ~clk;
    reg video_clk = 1'b0;
    always #7 video_clk = ~video_clk;
    reg rst = 1'b1;
    reg video_vs = 1'b0;
    tri1 scl, sda;
    reg slave_sda_low = 1'b0;
    reg [6:0] model_addr = 7'h14;
    assign sda = slave_sda_low ? 1'b0 : 1'bz;

    wire req, ack, online, report, down, swipe_next, swipe_prev;
    wire [10:0] mailbox_x, cursor_x;
    wire [9:0] mailbox_y, cursor_y;
    wire [23:0] video_rgb;
    wire video_de_out, video_vs_out;
    integer reports = 0;
    integer next_count = 0, prev_count = 0;
    gt911_trackpad #(.I2C_DIV(2), .BOOT_CYCLES(5),
                     .POLL_CYCLES(100), .RETRY_CYCLES(20)) dut (
        .clk(clk), .rst(rst), .scl(scl), .sda(sda),
        .cursor_ack_toggle(ack), .cursor_req_toggle(req),
        .cursor_mailbox_x(mailbox_x), .cursor_mailbox_y(mailbox_y),
        .online(online),
        .touch_report(report), .touch_down(down),
        .swipe_next(swipe_next), .swipe_prev(swipe_prev),
        .cursor_x(cursor_x), .cursor_y(cursor_y)
    );
    gt911_cursor_overlay #(
        .MEM_FILE("../board_display/user_source/hdl_source/SD/gt911_ganyu_cursor.mem")
    ) u_cursor (
        .video_clk(video_clk), .rst(rst), .video_in(24'h123456),
        .de_in(1'b0), .vs_in(video_vs), .online_raw(online),
        .cursor_req_toggle(req), .cursor_mailbox_x(mailbox_x),
        .cursor_mailbox_y(mailbox_y), .cursor_ack_toggle(ack),
        .video_out(video_rgb), .de_out(video_de_out),
        .vs_out(video_vs_out)
    );
    always @(posedge clk) if (report) reports <= reports + 1;
    always @(posedge clk) begin
        if (swipe_next) next_count <= next_count + 1;
        if (swipe_prev) prev_count <= prev_count + 1;
    end

    task automatic wait_start;
        begin
            @(negedge sda);
            if (scl !== 1'b1) $fatal(1, "START while SCL low");
        end
    endtask
    task automatic wait_stop;
        begin
            @(posedge sda);
            if (scl !== 1'b1) $fatal(1, "STOP while SCL low");
        end
    endtask
    task automatic expect_write(input [7:0] expected, input bit acknowledge);
        reg [7:0] received;
        integer i;
        begin
            received = 8'd0;
            for (i = 7; i >= 0; i = i - 1) begin
                @(posedge scl);
                received[i] = sda;
                @(negedge scl);
            end
            if (received !== expected)
                $fatal(1, "I2C byte %02h expected %02h", received, expected);
            slave_sda_low = acknowledge;
            @(posedge scl);
            @(negedge scl);
            slave_sda_low = 1'b0;
        end
    endtask
    task automatic send_byte(input [7:0] value, input bit expect_nack);
        integer i;
        begin
            for (i = 7; i >= 0; i = i - 1) begin
                slave_sda_low = !value[i];
                @(posedge scl);
                @(negedge scl);
            end
            slave_sda_low = 1'b0;
            @(posedge scl);
            if (sda !== expect_nack)
                $fatal(1, "master read ACK/NACK mismatch: %b", sda);
            @(negedge scl);
        end
    endtask
    task automatic serve_read(input [15:0] reg_addr,
                              input integer count, input [39:0] data);
        integer i;
        reg [7:0] b;
        begin
            wait_start();
            expect_write({model_addr, 1'b0}, 1'b1);
            expect_write(reg_addr[15:8], 1'b1);
            expect_write(reg_addr[7:0], 1'b1);
            wait_start();
            expect_write({model_addr, 1'b1}, 1'b1);
            for (i = 0; i < count; i = i + 1) begin
                b = data >> ((count - 1 - i) * 8);
                send_byte(b, i == count - 1);
            end
            wait_stop();
        end
    endtask
    task automatic serve_clear;
        begin
            wait_start();
            expect_write({model_addr, 1'b0}, 1'b1);
            expect_write(8'h81, 1'b1);
            expect_write(8'h4e, 1'b1);
            expect_write(8'h00, 1'b1);
            wait_stop();
        end
    endtask

    initial begin : slave_script
        // First candidate 0x5D NACKs, so the scanner must choose 0x14.
        wait_start();
        expect_write(8'hba, 1'b0);
        wait_stop();
        serve_read(16'h8140, 4, 40'h00_39_31_31_00);
        serve_read(16'h814e, 1, 40'h81);
        serve_read(16'h814f, 5, 40'h02_64_00_64_00); // first finger: anchor
        serve_clear();
        serve_read(16'h814e, 1, 40'h81);
        serve_read(16'h814f, 5, 40'h02_6e_00_68_00); // +10,+4
        serve_clear();
        serve_read(16'h814e, 1, 40'h80); // release
        serve_clear();
        serve_read(16'h814e, 1, 40'h81);
        serve_read(16'h814f, 5, 40'h03_90_01_2c_01); // new ID: anchor
        serve_clear();
        serve_read(16'h814e, 1, 40'h81);
        serve_read(16'h814f, 5, 40'h03_95_01_2e_01); // +5,+2
        serve_clear();
        repeat (10) @(negedge video_clk);
        video_vs = 1'b1;
        @(negedge video_clk);
        video_vs = 1'b0;
        repeat (4) @(negedge video_clk);
        if (!online || !down || reports != 4 ||
            cursor_x !== 11'd670 || cursor_y !== 10'd372 ||
            mailbox_x !== cursor_x || mailbox_y !== cursor_y ||
            ack !== req || u_cursor.frame_x !== cursor_x ||
            u_cursor.frame_y !== cursor_y)
            $fatal(1, "trackpad result: online=%b down=%b reports=%0d pos=%0d,%0d mailbox=%0d,%0d",
                   online, down, reports, cursor_x, cursor_y, mailbox_x, mailbox_y);
        // Release the prior finger. Two quick horizontal gestures must produce
        // exactly one navigation pulse each, only after release.
        serve_read(16'h814e, 1, 40'h80);
        serve_clear();
        if (next_count != 0 || prev_count != 0)
            $fatal(1, "short cursor drag triggered a swipe");
        serve_read(16'h814e, 1, 40'h81);
        serve_read(16'h814f, 5, 40'h04_f4_01_c8_00); // 500,200 anchor
        serve_clear();
        serve_read(16'h814e, 1, 40'h81);
        serve_read(16'h814f, 5, 40'h04_9a_01_cc_00); // 410,204
        serve_clear();
        serve_read(16'h814e, 1, 40'h81);
        serve_read(16'h814f, 5, 40'h04_45_01_d0_00); // 325,208
        serve_clear();
        if (next_count != 0 || prev_count != 0)
            $fatal(1, "swipe emitted before release");
        serve_read(16'h814e, 1, 40'h80);
        serve_clear();
        if (next_count != 1 || prev_count != 0)
            $fatal(1, "left swipe count %0d,%0d", next_count, prev_count);
        serve_read(16'h814e, 1, 40'h81);
        serve_read(16'h814f, 5, 40'h05_c8_00_c8_00); // 200,200 anchor
        serve_clear();
        serve_read(16'h814e, 1, 40'h81);
        serve_read(16'h814f, 5, 40'h05_22_01_cc_00); // 290,204
        serve_clear();
        serve_read(16'h814e, 1, 40'h81);
        serve_read(16'h814f, 5, 40'h05_77_01_d0_00); // 375,208
        serve_clear();
        serve_read(16'h814e, 1, 40'h80);
        serve_clear();
        if (next_count != 1 || prev_count != 1)
            $fatal(1, "right swipe count %0d,%0d", next_count, prev_count);
        // Reset the FPGA-side reader, then let the first candidate 0x5D ACK.
        @(negedge clk);
        rst = 1'b1;
        model_addr = 7'h5d;
        repeat (4) @(negedge clk);
        rst = 1'b0;
        serve_read(16'h8140, 4, 40'h00_39_31_31_00);
        serve_read(16'h814e, 1, 40'h00);
        repeat (10) @(negedge clk);
        if (!online || cursor_x !== 11'd640 || cursor_y !== 10'd360)
            $fatal(1, "0x5D direct probe failed");
        // A real address ACK with corrupt ID must not put the reader online.
        @(negedge clk);
        rst = 1'b1;
        repeat (4) @(negedge clk);
        rst = 1'b0;
        serve_read(16'h8140, 4, 40'h00_42_41_44_00); // "BAD"
        wait_start();
        expect_write(8'h28, 1'b0);
        wait_stop();
        repeat (10) @(negedge clk);
        if (online) $fatal(1, "corrupt product ID put reader online");
        $display("PASS GT911: both addresses, ID, relative cursor, CDC, two release swipes");
        $finish;
    end
    initial begin
        repeat (4) @(negedge clk);
        rst = 1'b0;
        #2000000;
        $fatal(1, "GT911 simulation timeout");
    end
endmodule
