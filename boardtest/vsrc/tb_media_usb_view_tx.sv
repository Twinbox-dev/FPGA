`timescale 1ns/1ps
module tb_media_usb_view_tx;
    reg clk=0,rst=1;always #5 clk=~clk;
    reg ctrl_req=0,view_valid=0;
    reg [63:0] ctrl_packet=64'h080706050403025a;
    reg [127:0] view_body=128'hffeeddccbbaa99887766554433221100;
    wire ctrl_ready,phy_ready,send,tx;
    wire [135:0] packet;
    wire [4:0] count;
    media_usb_view_tx mux(.clk(clk),.rst(rst),.physical_ready(phy_ready),
        .control_request(ctrl_req),.control_packet(ctrl_packet),.control_ready(ctrl_ready),
        .view_valid(view_valid),.view_body(view_body),.tx_request(send),.tx_packet(packet),.tx_count(count));
    uart_link #(.CLK_FREQ_HZ(80000000),.BAUD(10000000),.TX_BYTES(17)) serial(
        .clk(clk),.rst(rst),.rx(1'b1),.tx(tx),.tx_ready(phy_ready),.cmd(),.cmd_val(),
        .tx_req(send),.tx_pkt(packet),.tx_count(count));
    integer received=0;
    reg [7:0] bytes_seen[0:32];
    reg [7:0] value;
    integer b;
    initial begin
        forever begin
            @(negedge tx);#120;
            for(b=0;b<8;b=b+1)begin value[b]=tx;#80;end
            if(tx!==1'b1)$fatal(1,"UART stop bit");
            bytes_seen[received]=value;received=received+1;
        end
    end
    integer i;
    initial begin
        repeat(8)@(negedge clk);rst=0;wait(ctrl_ready);
        // Core observed ready before a new unsolicited view arrived. Its next
        // registered request must still win; the 17-byte view waits intact.
        @(negedge clk);view_valid=1;
        @(negedge clk);view_valid=0;ctrl_req=1;
        @(negedge clk);ctrl_req=0;
        wait(received==25);wait(ctrl_ready);
        for(i=0;i<8;i=i+1)if(bytes_seen[i]!=ctrl_packet[8*i+:8])$fatal(1,"control interleave");
        if(bytes_seen[8]!=8'ha7)$fatal(1,"missing A7");
        for(i=0;i<16;i=i+1)if(bytes_seen[i+9]!=view_body[8*i+:8])$fatal(1,"view interleave");
        @(negedge clk);ctrl_req=1;@(negedge clk);ctrl_req=0;
        wait(received==33);wait(ctrl_ready);
        for(i=0;i<8;i=i+1)if(bytes_seen[i+25]!=ctrl_packet[8*i+:8])$fatal(1,"UART 17 to 8 byte restart");
        $display("PASS: actual UART waveform, 8/17/8 byte packets and registered-control/view race");$finish;
    end
    initial begin #200000;$fatal(1,"UART view timeout bytes=%0d",received);end
endmodule
