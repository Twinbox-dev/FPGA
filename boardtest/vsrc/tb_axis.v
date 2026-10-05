`timescale 1ns/1ps
module tb_axis;
    reg clk = 1'b0;
    always #5 clk = ~clk;
    reg rst = 1'b1, vs = 1'b0, de = 1'b0;
    reg [23:0] rgb = 24'd0;
    wire user, valid, last;
    wire [23:0] data;

    video_rgb_to_axis_640x480 #(.H_ACTIVE(1280)) dut (
        .I_clk(clk), .I_rst(rst), .I_vs(vs), .I_de(de), .I_rgb(rgb),
        .O_video_user(user), .O_video_valid(valid),
        .O_video_last(last), .O_video_data(data)
    );

    integer x = 0, lines = 0, users = 0, errors = 0;
    always @(posedge clk) begin
        #1;
        if (rst) begin
            x = 0;
        end else if (valid) begin
            if (last !== (x == 1279)) begin
                $display("FAIL: TLAST at line=%0d x=%0d", lines, x);
                errors = errors + 1;
            end
            if (user) begin
                if (lines != 0 || x != 0) begin
                    $display("FAIL: SOF at line=%0d x=%0d", lines, x);
                    errors = errors + 1;
                end
                users = users + 1;
            end
            x = x + 1;
        end else if (x != 0) begin
            if (x != 1280) begin
                $display("FAIL: line length=%0d", x);
                errors = errors + 1;
            end
            lines = lines + 1;
            x = 0;
        end
    end

    integer i;
    initial begin
        repeat (5) @(negedge clk);
        rst = 1'b0;
        @(negedge clk); vs = 1'b1;
        @(negedge clk); vs = 1'b0;
        repeat (10) @(negedge clk);
        for (i = 0; i < 1280; i = i + 1) begin
            @(negedge clk); de = 1'b1; rgb = i;
        end
        @(negedge clk); de = 1'b0;
        repeat (10) @(negedge clk);
        for (i = 0; i < 1280; i = i + 1) begin
            @(negedge clk); de = 1'b1; rgb = i;
        end
        @(negedge clk); de = 1'b0;
        repeat (4) @(negedge clk);
        if (lines != 2 || users != 1 || errors != 0)
            $fatal(1, "AXI 720p check failed: lines=%0d SOF=%0d errors=%0d", lines, users, errors);
        $display("AXI 1280-pixel TLAST and SOF: PASS");
        $finish;
    end
endmodule
