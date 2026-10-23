`timescale 1ns/1ps
module tb_arbrace;
    reg clk = 0;
    always #5 clk = ~clk;
    reg rst = 1, write_req = 0, app_rd_busy = 0;
    reg [9:0] rdusedw = 0;
    wire app_wr_en, write_ack, write_finish, wr_busy, fifo_aclr;
    wire [20:0] app_wr_addr;

    frame_fifo_write #(.BURST_SIZE(16), .WRITE_V_FLIP(0)) dut (
        .view_layout(2'd0),.view_window(2'd0),
        .rst(rst), .mem_clk(clk), .Sdr_init_done(1'b1),
        .Sdr_init_ref_vld(1'b0), .Sdr_busy(1'b0),
        .App_rd_busy(app_rd_busy), .O_wr_busy(wr_busy),
        .App_wr_en(app_wr_en), .App_wr_addr(app_wr_addr),
        .write_req(write_req), .write_req_ack(write_ack),
        .write_finish(write_finish),
        .write_addr_0(21'd0), .write_addr_1(21'd100),
        .write_addr_2(21'd200), .write_addr_3(21'd300),
        .write_addr_index(2'd0), .write_len(21'd32),
        .vrow_off(20'sd0), .fifo_aclr(fifo_aclr), .rdusedw(rdusedw)
    );

    initial begin
        repeat (5) @(negedge clk);
        rst = 0;
        @(negedge clk); write_req = 1;
        wait(write_ack);
        @(negedge clk); write_req = 0;
        wait(dut.state == 2 && dut.into_burst_r == 0);
        @(negedge clk); rdusedw = 10'd512;
        @(posedge clk); #1;
        if (dut.state != 2 || dut.into_burst_r != 1)
            $fatal(1, "did not reach stale registered burst candidate");
        // Read engine can commit to a burst at that same edge because the
        // previous O_wr_busy was zero. Its busy reaches the write side now.
        @(negedge clk); app_rd_busy = 1;
        @(posedge clk); #1;
        $display("read busy=%0d, write state=%0d, App_wr_en=%0d",
                 app_rd_busy, dut.state, app_wr_en);
        if (dut.state == 3 || app_wr_en)
            $fatal(1, "write burst started from stale arbitration decision");
        @(negedge clk); app_rd_busy = 0;
        wait(dut.state == 3);
        $display("registered write arbitration: PASS");
        $finish;
    end
    initial begin
        #10000;
        $fatal(1, "arbitration test timeout");
    end
endmodule
