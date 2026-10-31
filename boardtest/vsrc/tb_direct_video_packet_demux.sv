module tb_direct_video_packet_demux;
    reg clk=0, rst=1;
    reg rx_valid=0, rx_packet_start=0, rx_packet_end=0;
    reg [7:0] rx_data=0;
    reg [15:0] rx_length=0;
    wire app_valid, app_packet_start, app_packet_end;
    wire [7:0] app_data;
    wire [15:0] app_length;
    wire video_valid, video_packet_start, video_packet_end;
    wire [7:0] video_data;
    wire [15:0] video_length;
    reg [7:0] app_got[0:7], video_got[0:7];
    integer app_count=0, video_count=0, app_starts=0, app_ends=0;
    integer video_starts=0, video_ends=0;

    always #5 clk=~clk;
    direct_video_packet_demux dut(
        .clk(clk),.rst(rst),.rx_valid(rx_valid),.rx_data(rx_data),
        .rx_length(rx_length),.rx_packet_start(rx_packet_start),
        .rx_packet_end(rx_packet_end),.app_valid(app_valid),.app_data(app_data),
        .app_length(app_length),.app_packet_start(app_packet_start),.app_packet_end(app_packet_end),
        .video_valid(video_valid),.video_data(video_data),.video_length(video_length),
        .video_packet_start(video_packet_start),.video_packet_end(video_packet_end)
    );
    always @(posedge clk) begin
        if (app_valid) begin
            app_got[app_count]=app_data;
            app_count=app_count+1;
            if (app_packet_start) app_starts=app_starts+1;
            if (app_packet_end) app_ends=app_ends+1;
        end
        if (video_valid) begin
            video_got[video_count]=video_data;
            video_count=video_count+1;
            if (video_packet_start) video_starts=video_starts+1;
            if (video_packet_end) video_ends=video_ends+1;
        end
    end

    task send(input [7:0] data, input start, input finish, input [15:0] length);
        begin
            @(negedge clk);
            rx_valid=1; rx_data=data; rx_packet_start=start;
            rx_packet_end=finish; rx_length=length;
        end
    endtask
    task idle;
        begin
            @(negedge clk); rx_valid=0; rx_packet_start=0; rx_packet_end=0;
        end
    endtask

    initial begin
        repeat(4) @(negedge clk);
        rst=0;
        send(8'hAA,1,0,4); send(8'hBB,0,0,4);
        send(8'h01,0,0,4); send(8'h02,0,1,4); idle(); idle(); repeat(2) @(posedge clk); #1;
        if (app_count!=4 || video_count!=0 || app_starts!=1 || app_ends!=1)
            $fatal(1,"ordinary packet split/count mismatch app=%0d video=%0d",app_count,video_count);
        if (app_got[0]!=8'hAA || app_got[1]!=8'hBB || app_got[2]!=1 || app_got[3]!=2)
            $fatal(1,"ordinary packet bytes changed");

        send(8'h56,1,0,4); send(8'h44,0,0,4);
        send(8'h01,0,0,4); send(8'h5A,0,1,4); idle(); idle(); repeat(2) @(posedge clk); #1;
        if (app_count!=4 || video_count!=4 || video_starts!=1 || video_ends!=1)
            $fatal(1,"video packet routing/count mismatch app=%0d video=%0d",app_count,video_count);
        if (video_got[0]!=8'h56 || video_got[1]!=8'h44 || video_got[2]!=1 || video_got[3]!=8'h5A)
            $fatal(1,"video packet bytes changed");

        $display("PASS direct-video packet demux: legacy payload preserved, VD packet isolated, boundaries aligned");
        $finish;
    end
endmodule
