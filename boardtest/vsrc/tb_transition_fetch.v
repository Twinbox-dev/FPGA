`timescale 1ns/1ps
module tb_transition_fetch;
    reg mem_clk = 1'b0, video_clk = 1'b0;
    always #5 mem_clk = ~mem_clk;             // 100 MHz SDRAM domain
    always #6.667 video_clk = ~video_clk;     // 75 MHz pixel domain
    reg rst = 1'b1, start = 1'b0, de = 1'b0, vs = 1'b0;
    reg sdr_busy = 1'b0;
    wire done, req, ready, rd_bank, row_ready, active, prev;
    wire [9:0] line_num, rd_addr, wr_addr;
    wire [20:0] line_base, app_addr;
    wire [31:0] rd_data, wr_data;
    wire wr_en, wr_bank, line_hold, app_en, frame_valid;
    wire [1:0] mode;
    wire [8:0] alpha;
    wire [10:0] progress;
    reg [3:0] valid_pipe = 4'd0;
    reg [20:0] addr_pipe [0:3];
    wire sdr_valid = valid_pipe[3];
    wire [31:0] sdr_data = {11'd0, addr_pipe[3]};
    integer words = 0;

    transition_ctrl ctrl (
        .video_clk(video_clk), .rst(rst), .start_toggle_raw(start),
        .target_buf_raw(1'b1), .mode_raw(2'd1),
        .direction_prev_raw(1'b0), .done_toggle(done),
        .de_word(de), .vs_word(vs),
        .line_req_toggle(req), .line_num(line_num), .line_base(line_base),
        .line_ready_toggle_raw(ready),
        .line_rd_bank(rd_bank), .line_rd_addr(rd_addr),
        .row_ready(row_ready), .effect_active(active),
        .active_mode(mode), .direction_prev(prev),
        .fade_alpha(alpha), .wipe_progress(progress)
    );
    transition_line_read fetch (
        .mem_clk(mem_clk), .rst(rst), .sdr_init_done(1'b1),
        .sdr_busy(sdr_busy), .sdr_refresh(1'b0),
        .line_req_toggle(req), .line_num(line_num), .line_base(line_base),
        .line_ready_toggle(ready),
        .frame_rd_en(1'b0), .frame_rd_addr(21'd0), .frame_wr_en(1'b0),
        .frame_rd_busy(1'b0), .frame_wr_busy(1'b0),
        .video_fifo_words(9'd400), .line_hold(line_hold),
        .app_rd_en(app_en), .app_rd_addr(app_addr),
        .sdr_rd_valid(sdr_valid), .sdr_rd_data(sdr_data),
        .frame_rd_valid(frame_valid), .line_wr_en(wr_en),
        .line_wr_data(wr_data), .line_wr_addr(wr_addr),
        .line_wr_bank(wr_bank)
    );
    transition_line_buf rows (
        .mem_clk(mem_clk), .wr_en(wr_en), .wr_bank(wr_bank),
        .wr_addr(wr_addr), .wr_data(wr_data),
        .video_clk(video_clk), .rd_bank(rd_bank), .rd_addr(rd_addr),
        .rd_data(rd_data)
    );
    always @(posedge mem_clk) begin
        valid_pipe <= {valid_pipe[2:0], app_en};
        addr_pipe[0] <= app_addr;
        addr_pipe[1] <= addr_pipe[0];
        addr_pipe[2] <= addr_pipe[1];
        addr_pipe[3] <= addr_pipe[2];
        if (!rst && wr_en) words <= words + 1;
        if (!rst && frame_valid) $fatal(1, "line data leaked into frame path");
    end
    task automatic line_start;
        begin
            @(negedge video_clk); de = 1'b1;
            repeat (3) @(negedge video_clk);
            if (!row_ready) $fatal(1, "row %0d missed prefetch", ctrl.y_cnt);
        end
    endtask
    initial begin
        repeat (5) @(negedge video_clk);
        rst = 1'b0;
        start = 1'b1;
        repeat (8) @(negedge video_clk);
        vs = 1'b1;
        @(negedge video_clk); vs = 1'b0;
        repeat (1500) @(negedge video_clk);
        line_start();
        if (rd_data < 32'd460800 || rd_data >= 32'd461440)
            $fatal(1, "row 0 data %0d", rd_data);
        repeat (1277) @(negedge video_clk);
        de = 1'b0;
        repeat (370) @(negedge video_clk);
        line_start();
        if (rd_data < 32'd461440 || rd_data >= 32'd462080)
            $fatal(1, "row 1 data %0d", rd_data);
        if (words < 1280)
            $fatal(1, "two rows not loaded: %0d words", words);
        repeat (1277) @(negedge video_clk);
        de = 1'b0;
        repeat (800) @(negedge video_clk);
        sdr_busy = 1'b1;
        vs = 1'b1;
        @(negedge video_clk); vs = 1'b0;
        repeat (1500) @(negedge video_clk);
        de = 1'b1;
        repeat (3) @(negedge video_clk);
        if (row_ready)
            $fatal(1, "stalled SDRAM row must be marked invalid");
        $display("PASS transition fetch: 100/75 MHz banks and stalled-row fallback");
        $finish;
    end
    initial begin
        #200000;
        $fatal(1, "transition fetch timeout");
    end
endmodule
