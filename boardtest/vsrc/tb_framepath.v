`timescale 1ns/1ps
module tb_framepath;
    localparam N = 1024;
    reg sd_clk = 0, mem_clk = 0, video_clk = 0;
    always #5     sd_clk = ~sd_clk;       // 100 MHz
    always #5     mem_clk = ~mem_clk;     // 当前板上 SDRAM 为 100 MHz
    always #6.666 video_clk = ~video_clk; // 75 MHz
    reg rst = 1;

    reg write_req = 0, write_en = 0;
    reg [31:0] write_data = 0;
    wire write_ack, write_finish;
    reg read_req = 0, read_en = 0;
    wire read_ack, read_finish, vid_empty;
    wire [31:0] read_data;
    wire app_wr_en, app_rd_en, sdr_rd_en;
    wire [20:0] app_wr_addr, app_rd_addr;
    wire [31:0] app_wr_din;
    wire [3:0] app_wr_dm;
    reg [31:0] sdr_rd_dout = 0;

    frame_read_write #(.FRAME_WIDTH(16), .FRAME_HEIGHT(64),
                       .BURST_SIZE(256), .WRITE_V_FLIP(0)) dut (
        .stream_clk(1'b0),
        .view_read_layout(2'd0),.view_write_layout(2'd0),.view_write_window(2'd0),.view_valid_mask(4'd1),.view_epoch(1'b0),.view_drained_epoch(),
        .rst(rst), .mem_clk(mem_clk),
        .Sdr_init_done(1'b1), .Sdr_init_ref_vld(1'b0), .Sdr_busy(1'b0),
        .App_rd_en(app_rd_en), .App_rd_addr(app_rd_addr),
        .Sdr_rd_en(sdr_rd_en), .Sdr_rd_dout(sdr_rd_dout),
        .read_clk(video_clk), .read_req(read_req), .read_req_ack(read_ack),
        .read_finish(read_finish),
        .read_addr_0(21'd0), .read_addr_1(21'd1024),
        .read_addr_2(21'd2048), .read_addr_3(21'd3072),
        .read_addr_index(2'd0), .read_len(21'd1024),
        .read_en(read_en), .read_data(read_data), .o_vid_rd_empty(vid_empty),
        .o_mem_rd_audio(),
        .aud_read_req(1'b0), .aud_read_req_ack(), .aud_read_finish(),
        .aud_read_addr_index(2'd2), .aud_read_len(21'd0),
        .aud_rd_en(1'b0), .aud_rd_data(),
        .App_wr_en(app_wr_en), .App_wr_addr(app_wr_addr),
        .App_wr_din(app_wr_din), .App_wr_dm(app_wr_dm),
        .write_clk(sd_clk), .write_req(write_req), .write_req_ack(write_ack),
        .write_finish(write_finish),
        .write_addr_0(21'd0), .write_addr_1(21'd1024),
        .write_addr_2(21'd2048), .write_addr_3(21'd3072),
        .write_addr_index(2'd0), .write_len(21'd1024),
        .vrow_off(20'sd0), .write_en(write_en), .write_data(write_data)
    );

    // 两种写口采样相位并列记录：厂商控制器内部未公开，
    // 这里测接口流本身是否能按同一相位连续映射到地址。
    reg [31:0] mem_now [0:4095];
    reg [31:0] mem_dly [0:4095];
    reg wr_en_d = 0;
    reg [20:0] wr_addr_d = 0;
    reg [1:0] rd_valid_d = 0;
    reg [20:0] rd_addr_d0 = 0, rd_addr_d1 = 0;
    reg sdr_rd_en_r = 0;
    integer app_wr_total = 0;
    reg [20:0] app_wr_last_addr = 0;
    assign sdr_rd_en = sdr_rd_en_r;
    always @(posedge mem_clk) begin
        if (app_wr_en) begin
            app_wr_total = app_wr_total + 1;
            app_wr_last_addr = app_wr_addr;
        end
        if (app_wr_en && app_wr_addr < 4096) mem_now[app_wr_addr] <= app_wr_din;
        wr_en_d <= app_wr_en;
        wr_addr_d <= app_wr_addr;
        if (wr_en_d && wr_addr_d < 4096) mem_dly[wr_addr_d] <= app_wr_din;

        rd_valid_d <= {rd_valid_d[0], app_rd_en};
        rd_addr_d0 <= app_rd_addr;
        rd_addr_d1 <= rd_addr_d0;
        sdr_rd_en_r <= rd_valid_d[1];
        if (rd_valid_d[1]) sdr_rd_dout <= mem_now[rd_addr_d1];
    end

    integer i, bad_now, bad_dly, bad_read, stage = 0;
    initial begin
        repeat (10) @(negedge sd_clk);
        rst = 0;
        repeat (10) @(negedge sd_clk);
        write_req = 1;
        stage = 1;
        wait(write_ack);
        stage = 2;
        @(negedge sd_clk); write_req = 0;
        // 与 sd_card_bmp 的 LD_IMG_SETTLE=16 拍一致：源端首字进入前，
        // 存储侧的 fifo_aclr 和写域内部复位都必须已释放。
        repeat (16) @(negedge sd_clk);
        if (dut.write_fifo_aclr || dut.write_buf.wr_rst)
            $fatal(1, "write FIFO reset still asserted after image settle window");
        for (i = 0; i < N + 1; i = i + 1) begin
            @(negedge sd_clk);
            write_en = 1;
            write_data = 32'hA5000000 | i;
        end
        @(negedge sd_clk); write_en = 0;
        stage = 3;
        wait(write_finish);
        stage = 4;
        repeat (20) @(negedge mem_clk);
        bad_now = 0; bad_dly = 0;
        for (i = 0; i < N; i = i + 1) begin
            if (mem_now[i] !== (32'hA5000000 | i)) bad_now = bad_now + 1;
            if (mem_dly[i] !== (32'hA5000000 | i)) bad_dly = bad_dly + 1;
        end
        $display("write phase: same-cycle bad=%0d, delayed-data bad=%0d / %0d",
                 bad_now, bad_dly, N);
        $display("App_wr_en count=%0d (length=%0d), last address=%0d",
                 app_wr_total, N, app_wr_last_addr);
        if (app_wr_total != N || app_wr_last_addr != N-1)
            $fatal(1, "extra or missing SDRAM application write beat");
        if (bad_now != 0) $fatal(1, "write FIFO or address sequence corrupted");

        @(negedge video_clk); read_req = 1;
        stage = 5;
        wait(read_ack);
        stage = 6;
        @(negedge video_clk); read_req = 0;
        repeat (100) @(negedge video_clk);
        bad_read = 0;
        for (i = 0; i < N; i = i + 1) begin
            @(negedge video_clk); read_en = 1;
            @(negedge video_clk); read_en = 0;
            if (read_data !== (32'hA5000000 | i)) begin
                if (bad_read < 8)
                    $display("read mismatch i=%0d got=%08x", i, read_data);
                bad_read = bad_read + 1;
            end
        end
        $display("read path: bad=%0d / %0d", bad_read, N);
        if (bad_read != 0) $fatal(1, "read FIFO data order corrupted");
        $display("Frame path 100/100/75MHz: PASS");
        $finish;
    end

    initial begin
        #1000000;
        $display("timeout stage=%0d wr_state=%0d wr_count=%0d wr_len=%0d wr_fifo=%0d rd_state=%0d",
                 stage, dut.frame_fifo_write_m0.state,
                 dut.frame_fifo_write_m0.write_cnt,
                 dut.frame_fifo_write_m0.write_len_latch,
                 dut.rdusedw, dut.frame_fifo_read_m0.state);
        $fatal(1, "framepath timeout");
    end
endmodule
