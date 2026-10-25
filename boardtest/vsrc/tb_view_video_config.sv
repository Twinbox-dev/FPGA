`timescale 1ns/1ps
module tb_view_video_config;
    reg clk=0,rst=1,vs=0;
    always #5 clk=~clk;
    reg raw_epoch=0,raw_buffer=0;
    reg [1:0] raw_layout=0;
    reg [3:0] raw_mask=0,raw_window_buffers=0;
    wire epoch,buffer_index;
    wire [1:0] layout;
    wire [3:0] valid_mask,window_buffers;

    view_video_config dut(
        .clk(clk),.rst(rst),.vs(vs),.raw_epoch(raw_epoch),.raw_buffer(raw_buffer),
        .raw_layout(raw_layout),.raw_mask(raw_mask),.raw_window_buffers(raw_window_buffers),
        .epoch(epoch),.buffer_index(buffer_index),.layout(layout),
        .valid_mask(valid_mask),.window_buffers(window_buffers)
    );

    task automatic commit_vs;
        begin
            @(negedge clk);vs=1;
            @(negedge clk);vs=0;
            repeat(2)@(negedge clk);
        end
    endtask

    initial begin
        repeat(4)@(negedge clk);rst=0;
        raw_buffer=1;raw_layout=2;raw_mask=4'b1111;raw_window_buffers=0;raw_epoch=1;
        repeat(6)@(negedge clk);commit_vs();
        if(!epoch || !buffer_index || layout!=2 || valid_mask!=15 || window_buffers!=0)
            $fatal(1,"initial quad config did not latch atomically");

        // Changing the source page for one window is still one VS mailbox
        // update: all four bits must be installed together.
        raw_buffer=0;raw_window_buffers=4'b0100;raw_mask=4'b1011;raw_epoch=0;
        repeat(6)@(negedge clk);
        if(buffer_index!=1 || window_buffers!=0 || valid_mask!=15)
            $fatal(1,"configuration changed before the frame boundary");
        commit_vs();
        if(epoch || buffer_index || layout!=2 || valid_mask!=4'b1011 ||
           window_buffers!=4'b0100)
            $fatal(1,"per-window page selection was not latched atomically");

        // A mode field change without a new epoch must not tear mid-frame.
        raw_layout=1;raw_mask=4'b0011;raw_window_buffers=4'b0010;
        repeat(6)@(negedge clk);commit_vs();
        if(layout!=2 || valid_mask!=4'b1011 || window_buffers!=4'b0100)
            $fatal(1,"mailbox fields changed without epoch");

        raw_epoch=1;repeat(6)@(negedge clk);commit_vs();
        if(!epoch || layout!=1 || valid_mask!=3 || window_buffers!=2)
            $fatal(1,"dual layout mailbox update failed");
        $display("PASS view video config: base page, per-window selectors and fields commit only at VS");
        $finish;
    end
    initial begin #200000;$fatal(1,"view config timeout");end
endmodule
