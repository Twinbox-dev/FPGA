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
    integer row, col;
    reg [23:0] expected;

    gt911_cursor_overlay #(.INIT_X(11'd2), .INIT_Y(10'd1)) dut (
        .video_clk(clk), .rst(rst),
        .video_in(rgb), .de_in(de), .vs_in(vs),
        .online_raw(online),
        .cursor_req_toggle(req),
        .cursor_mailbox_x(mailbox_x), .cursor_mailbox_y(mailbox_y),
        .cursor_ack_toggle(ack),
        .video_out(out_rgb), .de_out(out_de), .vs_out(out_vs)
    );

    task automatic tick(input bit active, input bit vs_level,
                        input [23:0] expected_rgb);
        begin
            @(negedge clk);
            de = active;
            vs = vs_level;
            @(posedge clk);
            #1;
            if (out_de !== active || out_vs !== vs_level ||
                out_rgb !== expected_rgb)
                $fatal(1, "cursor pixel: de=%b vs=%b rgb=%h expected %h",
                       out_de, out_vs, out_rgb, expected_rgb);
        end
    endtask
    task automatic frame(input integer pointer_x);
        begin
            tick(0, 1, 24'h123456);
            tick(0, 0, 24'h123456);
            for (row = 0; row < 4; row = row + 1) begin
                for (col = 0; col < 20; col = col + 1) begin
                    expected = 24'h123456;
                    if (row >= 1 && col >= pointer_x &&
                        col <= pointer_x + row - 1)
                        expected = (row == 3 && col == pointer_x + 1) ?
                                   24'hffffff : 24'h101820;
                    tick(1, 0, expected);
                end
                tick(0, 0, 24'h123456);
            end
        end
    endtask
    initial begin
        repeat (3) @(negedge clk);
        rst = 1'b0;
        online = 1'b1;
        repeat (4) tick(0, 0, 24'h123456);
        frame(2);
        // A mailbox update during the old frame becomes visible next VS.
        mailbox_x = 11'd6;
        req = 1'b1;
        repeat (4) tick(0, 0, 24'h123456);
        if (!ack) $fatal(1, "cursor mailbox not acknowledged");
        frame(6);
        $display("PASS GT911 cursor: RGB/DE/VS alignment, frame commit, arrow colors");
        $finish;
    end
endmodule
