`timescale 1ns/1ps
module tb_transition_framepath;
    reg mem_clk = 1'b0, video_clk = 1'b0;
    always #5 mem_clk = ~mem_clk;
    always #6.667 video_clk = ~video_clk;
    reg rst = 1'b1, read_req = 1'b0, video_pop = 1'b0;
    reg line_req_toggle = 1'b0;
    wire read_ack, read_finish, video_empty, mem_audio;
    wire [31:0] video_data;
    wire frame_cmd_en, mux_cmd_en, raw_valid, frame_valid;
    wire [20:0] frame_cmd_addr, mux_cmd_addr;
    wire frame_wr_en, frame_rd_busy, frame_wr_busy, line_hold;
    wire [8:0] fifo_words;
    wire line_ready, line_wr_en, line_wr_bank;
    wire [9:0] line_wr_addr;
    wire [31:0] line_wr_data;
    wire [20:0] unused_wr_addr;
    wire [31:0] unused_wr_data;
    wire [3:0] unused_wr_dm;
    reg [1:0] valid_pipe = 2'd0;
    reg [20:0] addr_d0 = 21'd0, addr_d1 = 21'd0;
    reg raw_valid_r = 1'b0;
    reg [31:0] raw_data = 32'd0;
    integer frame_words = 0, line_words = 0, empty_pops = 0;
    assign raw_valid = raw_valid_r;

    frame_read_write #(.FRAME_WIDTH(16), .FRAME_HEIGHT(64),
                       .BURST_SIZE(256), .WRITE_V_FLIP(0)) frame (
        .stream_clk(1'b0),
        .view_read_layout(2'd0),.view_write_layout(2'd0),.view_write_window(2'd0),.view_valid_mask(4'd1),.view_epoch(1'b0),.view_drained_epoch(),
        .rst(rst), .mem_clk(mem_clk),
        .Sdr_init_done(1'b1), .Sdr_init_ref_vld(1'b0), .Sdr_busy(1'b0),
        .App_rd_en(frame_cmd_en), .App_rd_addr(frame_cmd_addr),
        .Sdr_rd_en(frame_valid), .Sdr_rd_dout(raw_data),
        .o_mem_rd_busy(frame_rd_busy), .o_mem_wr_busy(frame_wr_busy),
        .o_vid_fifo_words(fifo_words), .line_hold(line_hold),
        .read_clk(video_clk), .read_req(read_req), .read_req_ack(read_ack),
        .read_finish(read_finish),
        .read_addr_0(21'd0), .read_addr_1(21'd1024),
        .read_addr_2(21'd2048), .read_addr_3(21'd3072),
        .read_addr_index(2'd0), .read_len(21'd1024),
        .read_en(video_pop), .read_data(video_data),
        .o_vid_rd_empty(video_empty), .o_mem_rd_audio(mem_audio),
        .aud_read_req(1'b0), .aud_read_req_ack(), .aud_read_finish(),
        .aud_read_addr_index(2'd2), .aud_read_len(21'd0),
        .aud_rd_en(1'b0), .aud_rd_data(),
        .App_wr_en(frame_wr_en), .App_wr_addr(unused_wr_addr),
        .App_wr_din(unused_wr_data), .App_wr_dm(unused_wr_dm),
        .write_clk(mem_clk), .write_req(1'b0), .write_req_ack(),
        .write_finish(), .write_addr_0(21'd0), .write_addr_1(21'd1024),
        .write_addr_2(21'd2048), .write_addr_3(21'd3072),
        .write_addr_index(2'd0), .write_len(21'd0),
        .vrow_off(20'sd0), .write_en(1'b0), .write_data(32'd0)
    );
    transition_line_read fetch (
        .mem_clk(mem_clk), .rst(rst), .sdr_init_done(1'b1),
        .sdr_busy(1'b0), .sdr_refresh(1'b0),
        .line_req_toggle(line_req_toggle), .line_num(10'd0),
        .line_base(21'd1024), .line_ready_toggle(line_ready),
        .frame_rd_en(frame_cmd_en), .frame_rd_addr(frame_cmd_addr),
        .frame_wr_en(frame_wr_en), .frame_rd_busy(frame_rd_busy),
        .frame_wr_busy(frame_wr_busy), .video_fifo_words(fifo_words),
        .line_hold(line_hold), .app_rd_en(mux_cmd_en),
        .app_rd_addr(mux_cmd_addr),
        .sdr_rd_valid(raw_valid), .sdr_rd_data(raw_data),
        .frame_rd_valid(frame_valid),
        .line_wr_en(line_wr_en), .line_wr_data(line_wr_data),
        .line_wr_addr(line_wr_addr), .line_wr_bank(line_wr_bank)
    );
    always @(posedge mem_clk) begin
        valid_pipe <= {valid_pipe[0], mux_cmd_en};
        addr_d0 <= mux_cmd_addr;
        addr_d1 <= addr_d0;
        raw_valid_r <= valid_pipe[1];
        if (valid_pipe[1])
            raw_data <= addr_d1 < 21'd1024 ?
                        (32'hA5000000 | {11'd0, addr_d1}) :
                        (32'hB5000000 | {11'd0, addr_d1 - 21'd1024});
        if (!rst && line_wr_en) begin
            if (line_wr_addr !== line_words || line_wr_bank ||
                line_wr_data !== (32'hB5000000 | line_words))
                $fatal(1, "line data mismatch at %0d: %h", line_words, line_wr_data);
            line_words <= line_words + 1;
        end
    end
    initial begin
        repeat (10) @(negedge mem_clk);
        rst = 1'b0;
        @(negedge video_clk); read_req = 1'b1;
        wait (read_ack);
        @(negedge video_clk); read_req = 1'b0;
        wait (fifo_words >= 9'd256);
        repeat (10) @(negedge video_clk);
        for (integer i = 0; i < 1024; i = i + 1) begin
            @(negedge video_clk);
            video_pop = 1'b1;
            if (video_empty) empty_pops = empty_pops + 1;
            @(negedge video_clk);
            video_pop = 1'b0;
            if (video_data !== (32'hA5000000 | i))
                $fatal(1, "old frame word %0d got %h", i, video_data);
            frame_words = frame_words + 1;
            if (i == 100) line_req_toggle = 1'b1;
        end
        wait (line_ready);
        if (frame_words != 1024 || line_words != 640 || empty_pops != 0)
            $fatal(1, "frame=%0d line=%0d empty=%0d",
                   frame_words, line_words, empty_pops);
        $display("PASS transition framepath: live video FIFO and 640-word prefetch coexist");
        $finish;
    end
    initial begin
        #1000000;
        $fatal(1, "transition framepath timeout frame=%0d line=%0d", frame_words, line_words);
    end
endmodule
