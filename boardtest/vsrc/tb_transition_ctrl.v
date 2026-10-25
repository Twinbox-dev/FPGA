`timescale 1ns/1ps
module tb_transition_ctrl;
    reg clk = 1'b0;
    always #5 clk = ~clk;
    reg rst = 1'b1;
    reg start_toggle = 1'b0, target_buf = 1'b1;
    reg [1:0] mode = 2'd1;
    reg prev = 1'b0, de = 1'b0, vs = 1'b0;
    reg view_mode=0,release_toggle=0;
    reg [1:0] view_layout=0,view_window=0;
    reg ready_toggle = 1'b0;
    wire done_toggle, req_toggle, rd_bank, row_ready, active, active_prev;
    wire [9:0] line_num, rd_addr;
    wire [9:0] row_words;
    wire [20:0] line_base;
    wire [1:0] active_mode;
    wire view_active;
    wire [1:0] active_view_layout,active_view_window;
    wire [8:0] alpha;
    wire [10:0] progress;
    reg req_seen = 1'b0;
    reg done_before;
    integer ack_delay = 0, req_count = 0, frame, i;

    transition_ctrl dut (
        .video_clk(clk), .rst(rst), .start_toggle_raw(start_toggle),
        .target_buf_raw(target_buf), .mode_raw(mode),
        .direction_prev_raw(prev),.view_transition_raw(view_mode),
        .view_layout_raw(view_layout),.view_window_raw(view_window),.release_toggle_raw(release_toggle),
        .done_toggle(done_toggle),
        .de_word(de), .vs_word(vs),
        .line_req_toggle(req_toggle), .line_num(line_num),
        .line_base(line_base),.row_words(row_words),.line_ready_toggle_raw(ready_toggle),
        .line_rd_bank(rd_bank), .line_rd_addr(rd_addr),
        .row_ready(row_ready), .effect_active(active),
        .active_mode(active_mode), .direction_prev(active_prev),
        .fade_alpha(alpha), .wipe_progress(progress),.view_active(view_active),
        .active_view_layout(active_view_layout),.active_view_window(active_view_window)
    );
    always @(posedge clk) begin
        if (!rst) begin
            if (req_toggle != req_seen) begin
                req_seen <= req_toggle;
                ack_delay <= 3;
                req_count <= req_count + 1;
                if (!view_mode && (line_base != 21'd460800 || row_words!=640 || line_num > 10'd2))
                    $fatal(1, "wrong single line request base=%0d row=%0d words=%0d", line_base, line_num,row_words);
                if (view_mode && (line_base != 21'd806400 || row_words!=320 || line_num>10'd359))
                    $fatal(1, "wrong quad window line request base=%0d row=%0d words=%0d",line_base,line_num,row_words);
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
    task automatic scan_row_expect(input bit expected_ready);
        begin
            repeat (12) @(negedge clk);
            de=1'b1;repeat(4)@(negedge clk);
            if(row_ready!==expected_ready)
                $fatal(1,"view row-ready mismatch y=%0d got=%b expected=%b",dut.y_cnt,row_ready,expected_ready);
            de=1'b0;repeat(4)@(negedge clk);
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
        view_mode=1;view_layout=2;view_window=3;mode=2;target_buf=1;
        done_before=done_toggle;
        start_toggle=~start_toggle;repeat(8)@(negedge clk);
        if(!view_active || active_view_layout!=2 || active_view_window!=3 ||
           line_base!=21'd806400 || row_words!=320)
            $fatal(1,"quad window transition context was not captured");
        pulse_vs();
        scan_row_expect(0);
        for(i=1;i<360;i=i+1)scan_row_expect(0);
        scan_row_expect(1);
        for(frame=0;frame<=65;frame=frame+1)pulse_vs();
        if(done_toggle==done_before || !active || !view_active || alpha!=9'd256 || progress!=11'd640)
            $fatal(1,"view transition did not hold final new image until page commit");
        release_toggle=~release_toggle;repeat(8)@(negedge clk);
        if(active || view_active)$fatal(1,"view transition did not release after commit ack");
        $display("PASS transition control: full-screen and quad bottom-right row scheduler/hold");
        $finish;
    end
    initial begin
        #200000;
        $fatal(1, "transition controller timeout");
    end
endmodule
