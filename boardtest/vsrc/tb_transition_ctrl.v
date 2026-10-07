`timescale 1ns/1ps
module tb_transition_ctrl;
    reg clk = 1'b0;
    always #5 clk = ~clk;
    reg rst = 1'b1;
    reg start_toggle = 1'b0, target_buf = 1'b1;
    reg [1:0] mode = 2'd1;
    reg prev = 1'b0, de = 1'b0, vs = 1'b0;
    reg ready_toggle = 1'b0;
    wire done_toggle, req_toggle, rd_bank, row_ready, active, active_prev;
    wire [9:0] line_num, rd_addr;
    wire [20:0] line_base;
    wire [1:0] active_mode;
    wire [8:0] alpha;
    wire [10:0] progress;
    reg req_seen = 1'b0;
    integer ack_delay = 0, req_count = 0, frame;

    transition_ctrl dut (
        .video_clk(clk), .rst(rst), .start_toggle_raw(start_toggle),
        .target_buf_raw(target_buf), .mode_raw(mode),
        .direction_prev_raw(prev), .done_toggle(done_toggle),
        .de_word(de), .vs_word(vs),
        .line_req_toggle(req_toggle), .line_num(line_num),
        .line_base(line_base), .line_ready_toggle_raw(ready_toggle),
        .line_rd_bank(rd_bank), .line_rd_addr(rd_addr),
        .row_ready(row_ready), .effect_active(active),
        .active_mode(active_mode), .direction_prev(active_prev),
        .fade_alpha(alpha), .wipe_progress(progress)
    );
    always @(posedge clk) begin
        if (!rst) begin
            if (req_toggle != req_seen) begin
                req_seen <= req_toggle;
                ack_delay <= 3;
                req_count <= req_count + 1;
                if (line_base != 21'd460800 || line_num > 10'd2)
                    $fatal(1, "wrong line request base=%0d row=%0d", line_base, line_num);
            end else if (ack_delay > 0) begin
                ack_delay <= ack_delay - 1;
                if (ack_delay == 1)
                    ready_toggle <= ~ready_toggle;
            end
        end
    end

    task automatic pulse_vs;
        begin
            @(negedge clk); vs = 1'b1;
            @(negedge clk); vs = 1'b0;
        end
    endtask
    task automatic one_row;
        begin
            repeat (12) @(negedge clk);
            de = 1'b1;
            repeat (4) @(negedge clk);
            if (!row_ready) $fatal(1, "row was not marked ready");
            de = 1'b0;
            repeat (4) @(negedge clk);
        end
    endtask

    initial begin
        repeat (4) @(negedge clk);
        rst = 1'b0;
        start_toggle = 1'b1;
        repeat (8) @(negedge clk);
        for (frame = 0; frame <= 65; frame = frame + 1) begin
            pulse_vs();
            if (frame == 64 && (alpha != 9'd256 || progress != 11'd1280))
                $fatal(1, "effect did not reach full new frame");
            if (frame < 65) begin
                one_row();
                one_row();
            end
        end
        repeat (3) @(negedge clk);
        if (!done_toggle || active || req_count < 100)
            $fatal(1, "effect completion missing active=%b req=%0d", active, req_count);
        $display("PASS transition control: row ready and 64-step fade completion");
        $finish;
    end
    initial begin
        #200000;
        $fatal(1, "transition controller timeout");
    end
endmodule
