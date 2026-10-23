`timescale 1ns/1ps

module tb_media_uart_arbiter;
    reg clk=0;always #5 clk=~clk;
    reg rst=1;
    reg [7:0] usb_cmd=0,bt_cmd=0;
    reg usb_valid=0,bt_valid=0,cmd_ready=0;
    reg [1:0] source_lock=0;
    wire [7:0] cmd;
    wire [1:0] cmd_source;
    wire cmd_valid;
    reg view_busy=0;
    wire cmd_was_busy;
    wire [7:0] usb_overflow_count,bt_overflow_count;

    media_uart_arbiter dut (
        .view_busy(view_busy),.cmd_was_busy(cmd_was_busy),
        .clk(clk),.rst(rst),.usb_cmd(usb_cmd),.usb_valid(usb_valid),
        .bt_cmd(bt_cmd),.bt_valid(bt_valid),.source_lock(source_lock),.cmd(cmd),.cmd_source(cmd_source),
        .cmd_valid(cmd_valid),.cmd_ready(cmd_ready),
        .usb_overflow_count(usb_overflow_count),.bt_overflow_count(bt_overflow_count)
    );

    task automatic push_usb(input [7:0] value);
        begin @(negedge clk);usb_cmd=value;usb_valid=1;@(negedge clk);usb_valid=0;end
    endtask
    task automatic push_bt(input [7:0] value);
        begin @(negedge clk);bt_cmd=value;bt_valid=1;@(negedge clk);bt_valid=0;end
    endtask
    task automatic expect_pop(input [1:0] source,input [7:0] value);
        begin
            wait(cmd_valid);#1;
            if(cmd_source!==source || cmd!==value)
                $fatal(1,"queue order got source=%0d cmd=%02x expected source=%0d cmd=%02x",
                    cmd_source,cmd,source,value);
            @(negedge clk);cmd_ready=1;@(negedge clk);cmd_ready=0;
        end
    endtask

    initial begin
        repeat(3)@(negedge clk);rst=0;
        push_usb(8'h41);push_bt(8'h2B);push_usb(8'h42);push_bt(8'h5D);
        expect_pop(2'd1,8'h41);expect_pop(2'd2,8'h2B);
        expect_pop(2'd1,8'h42);expect_pop(2'd2,8'h5D);
        push_usb(8'h10);push_usb(8'h11);push_usb(8'h12);push_usb(8'h13);push_usb(8'h14);
        if(usb_overflow_count!=1) $fatal(1,"USB overflow counter expected 1, got %0d",usb_overflow_count);
        expect_pop(2'd1,8'h10);expect_pop(2'd1,8'h11);expect_pop(2'd1,8'h12);expect_pop(2'd1,8'h13);
        if(cmd_valid) $fatal(1,"queue did not drain");
        push_usb(8'h50);push_bt(8'h60);source_lock=2;
        expect_pop(2'd2,8'h60);
        if(cmd_valid) $fatal(1,"locked source did not pause the other UART FIFO");
        source_lock=0;expect_pop(2'd1,8'h50);
        view_busy=1;push_usb(8'h4e);view_busy=0;
        repeat(3)@(negedge clk);
        if(!cmd_was_busy)$fatal(1,"queued UART command lost busy-at-arrival tag");
        expect_pop(2'd1,8'h4e);
        push_bt(8'h50);
        if(cmd_was_busy)$fatal(1,"idle UART command inherited a stale busy tag");
        expect_pop(2'd2,8'h50);
        $display("PASS: per-source buffering, fair arbitration and bounded overflow");
        $finish;
    end
endmodule
