`timescale 1ns/1ps
module tb_subtitle_cmd;
    reg clk = 1'b0;
    always #5 clk = ~clk;
    reg rst = 1'b1, val = 1'b0, swap_ack = 1'b0;
    reg [7:0] cmd = 8'd0;
    wire consume, wr_en, commit, ack_pulse, ack_ok;
    wire [7:0] wr_index, wr_char, commit_len;
    integer words = 0, good_ack = 0, bad_ack = 0;
    reg [7:0] expected [0:2];

    subtitle_cmd dut (
        .clk(clk), .rst(rst), .cmd(cmd), .cmd_val(val),
        .swap_ack_toggle_raw(swap_ack), .consume_cmd(consume),
        .wr_en(wr_en), .wr_index(wr_index), .wr_char(wr_char),
        .commit_toggle(commit), .commit_len(commit_len),
        .ack_pulse(ack_pulse), .ack_ok(ack_ok)
    );
    always @(posedge clk) if (!rst) begin
        if (wr_en) begin
            if (words >= 3 || wr_index !== words || wr_char !== expected[words])
                $fatal(1, "subtitle write %0d index=%0d char=%h", words, wr_index, wr_char);
            words <= words + 1;
        end
        if (ack_pulse) begin
            if (ack_ok) good_ack <= good_ack + 1;
            else bad_ack <= bad_ack + 1;
        end
    end
    task automatic send_byte(input [7:0] b);
        begin
            @(negedge clk); cmd = b; val = 1'b1;
            #1;
            if (!consume && (b == 8'h54 || dut.state != 0))
                $fatal(1, "upload byte escaped to normal command decoder");
            @(negedge clk); val = 1'b0;
            repeat (2) @(negedge clk);
        end
    endtask
    initial begin
        expected[0] = 8'h4e; // N is also an ordinary next-image command
        expected[1] = 8'h30; // 0 is also a transition-mode command
        expected[2] = 8'h50; // P is also an ordinary previous-image command
        repeat (3) @(negedge clk); rst = 1'b0;
        send_byte(8'h54); // T
        send_byte(8'h83);
        send_byte(expected[0] | 8'h80);
        send_byte(expected[1] | 8'h80);
        send_byte(expected[2] | 8'h80);
        send_byte(8'h82); // checksum 0x2d, high nibble
        send_byte(8'h8d); // low nibble
        if (words != 3 || !commit || commit_len != 3 || good_ack != 1)
            $fatal(1, "valid upload not committed");
        send_byte(8'h54); // bank swap still pending: reject a second upload
        if (bad_ack != 1) $fatal(1, "pending swap must reject new upload");
        swap_ack = 1'b1;
        repeat (5) @(negedge clk);
        send_byte(8'h54);
        send_byte(8'h80); // encoded length zero
        send_byte(8'h80); // checksum high nibble
        send_byte(8'h80); // checksum low nibble clears subtitle
        if (commit || commit_len != 0 || good_ack != 2)
            $fatal(1, "clear upload not committed");
        $display("PASS subtitle command: atomic upload, reserved bytes, bank ack, clear");
        $finish;
    end
endmodule
