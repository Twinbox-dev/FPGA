`timescale 1ns/1ps
module tb_gt911_cursor;
    reg clk = 1'b0;
    always #5 clk = ~clk;
    reg rst = 1'b1, de = 1'b0, vs = 1'b0;
    reg online = 1'b0, req = 1'b0;
    reg [10:0] mailbox_x = 11'd2;
    reg [9:0] mailbox_y = 10'd1;
    reg [23:0] rgb = 24'h123456;
    wire [23:0] out_rgb;
    wire out_de, out_vs, ack;
    reg [23:0] expected_d = 24'd0;
    reg check_d = 1'b0, de_d = 1'b0, vs_d = 1'b0;
    integer row, col;

    gt911_cursor_overlay #(
        .INIT_X(11'd2), .INIT_Y(10'd1),
        .MEM_FILE("../board/user_source/hdl_source/SD/gt911_ganyu_cursor.mem")
    ) dut (
        .video_clk(clk), .rst(rst),
        .video_in(rgb), .de_in(de), .vs_in(vs),
        .online_raw(online),
        .cursor_req_toggle(req),
        .cursor_mailbox_x(mailbox_x), .cursor_mailbox_y(mailbox_y),
        .cursor_ack_toggle(ack),
        .video_out(out_rgb), .de_out(out_de), .vs_out(out_vs)
    );

    // The synchronous ROM adds a stage; compare with the prior input pixel.
    task automatic tick(input bit active, input bit vs_level,
                        input bit check_rgb, input [23:0] expected_rgb);
        begin
            @(negedge clk);
            de = active;
            vs = vs_level;
            @(posedge clk);
            #1;
            if (out_de !== de_d || out_vs !== vs_d ||
                (check_d && out_rgb !== expected_d))
                $fatal(1, "cursor pipeline: de=%b/%b vs=%b/%b rgb=%h/%h",
                       out_de, de_d, out_vs, vs_d, out_rgb, expected_d);
            de_d = active;
            vs_d = vs_level;
            check_d = check_rgb;
            expected_d = expected_rgb;
        end
    endtask

    task automatic frame(input integer pointer_x);
        reg check_pixel;
        reg [23:0] expected;
        begin
            tick(0, 1, 1, 24'h123456);
            tick(0, 0, 1, 24'h123456);
            for (row = 0; row < 66; row = row + 1) begin
                for (col = 0; col < 72; col = col + 1) begin
                    check_pixel = 1'b0;
                    expected = 24'h123456;
                    if (row == 3 && col == pointer_x + 2) begin
                        check_pixel = 1'b1; // source pixel (2,2): pale pointer
                        expected = 24'hfffff7;
                    end
                    if (row == 21 && col == pointer_x + 30) begin
                        check_pixel = 1'b1; // source pixel (30,20): hair
                        expected = 24'hc6d7ff;
                    end
                    if (row == 51 && col == pointer_x + 10)
                        check_pixel = 1'b1; // transparent pixel
                    if (row == 1 && col == pointer_x + 65)
                        check_pixel = 1'b1; // outside the cursor box
                    tick(1, 0, check_pixel, expected);
                end
                tick(0, 0, 0, 24'h123456);
            end
            tick(0, 0, 1, 24'h123456);
        end
    endtask

    initial begin
        repeat (3) @(negedge clk);
        rst = 1'b0;
        online = 1'b1;
        repeat (4) tick(0, 0, 0, 24'h123456);
        frame(2);
        mailbox_x = 11'd6;
        req = 1'b1;
        repeat (4) tick(0, 0, 0, 24'h123456);
        if (!ack) $fatal(1, "cursor mailbox not acknowledged");
        frame(6);
        $display("PASS GT911 cursor: sprite RGB/transparency, RGB/DE/VS alignment, frame commit");
        $finish;
    end
endmodule
