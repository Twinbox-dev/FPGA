`timescale 1ns/1ps
module tb_transition_line_read;
    reg clk = 1'b0;
    always #5 clk = ~clk;
    reg rst = 1'b1;
    reg req_toggle = 1'b0;
    reg sdr_busy = 1'b1;
    reg sdr_refresh = 1'b0;
    reg frame_rd_en = 1'b0;
    reg [20:0] frame_rd_addr = 21'd50000;
    wire ready_toggle, hold, app_rd_en, frame_valid, line_wr_en;
    wire [20:0] app_rd_addr;
    wire [31:0] line_wr_data;
    wire [9:0] line_wr_addr;
    wire line_wr_bank;
    reg [3:0] valid_pipe = 4'd0;
    reg [20:0] addr_pipe [0:3];
    wire sdr_valid = valid_pipe[3];
    wire [31:0] sdr_data = {11'd0, addr_pipe[3]};
    integer commands = 0, words = 0, yield_cycles = 0, frame_words = 0;
    reg seen_line = 1'b0;

    transition_line_read dut (
        .mem_clk(clk), .rst(rst), .sdr_init_done(1'b1),
        .sdr_busy(sdr_busy), .sdr_refresh(sdr_refresh),
        .line_req_toggle(req_toggle), .line_num(10'd3),
        .line_base(21'd1000), .line_ready_toggle(ready_toggle),
        .frame_rd_en(frame_rd_en), .frame_rd_addr(frame_rd_addr),
        .frame_wr_en(1'b0), .frame_rd_busy(1'b0), .frame_wr_busy(1'b0),
        .video_fifo_words(9'd400), .line_hold(hold),
        .app_rd_en(app_rd_en), .app_rd_addr(app_rd_addr),
        .sdr_rd_valid(sdr_valid), .sdr_rd_data(sdr_data),
        .frame_rd_valid(frame_valid), .line_wr_en(line_wr_en),
        .line_wr_data(line_wr_data), .line_wr_addr(line_wr_addr),
        .line_wr_bank(line_wr_bank)
    );

    always @(posedge clk) begin
        valid_pipe <= {valid_pipe[2:0], app_rd_en};
        addr_pipe[0] <= app_rd_addr;
        addr_pipe[1] <= addr_pipe[0];
        addr_pipe[2] <= addr_pipe[1];
        addr_pipe[3] <= addr_pipe[2];
        if (!rst) begin
            if (app_rd_en && !frame_rd_en) begin
                if (app_rd_addr !== 21'd2920 + commands)
                    $fatal(1, "line command %0d address %0d", commands, app_rd_addr);
                commands <= commands + 1;
                seen_line <= 1'b1;
            end
            if (seen_line && commands < 640 && !hold)
                yield_cycles <= yield_cycles + 1;
            if (line_wr_en) begin
                if (line_wr_addr !== words ||
                    line_wr_data !== 32'(21'd2920 + words) || !line_wr_bank)
                    $fatal(1, "line response %0d addr=%0d data=%0d bank=%b",
                           words, line_wr_addr, line_wr_data, line_wr_bank);
                words <= words + 1;
            end
            if (frame_valid) begin
                if (line_wr_en || sdr_data !== 32'd50000)
                    $fatal(1, "frame response was routed to line bank");
                frame_words <= frame_words + 1;
            end
        end
    end

    initial begin
        repeat (5) @(negedge clk);
        rst = 1'b0;
        repeat (5) @(negedge clk);
        req_toggle = 1'b1;
        repeat (8) @(negedge clk);
        if (commands != 0) $fatal(1, "read started while SDRAM busy");
        sdr_busy = 1'b0;
        wait (ready_toggle);
        @(negedge clk);
        if (commands != 640 || words != 640 || yield_cycles < 4)
            $fatal(1, "line incomplete cmd=%0d data=%0d yields=%0d",
                   commands, words, yield_cycles);
        frame_rd_en = 1'b1;
        @(negedge clk);
        frame_rd_en = 1'b0;
        repeat (8) @(negedge clk);
        if (frame_words != 1) $fatal(1, "frame response missing");
        $display("PASS transition line read: 640 words, five yields, frame isolated");
        $finish;
    end
    initial begin
        #200000;
        $fatal(1, "transition line read timeout");
    end
endmodule
