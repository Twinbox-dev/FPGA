`timescale 1ns/1ps
module tb_view_commands;
    reg clk=0,rst=1;always #4 clk=~clk;
    reg [7:0] cmd=0,ucmd=0;
    reg pending=0,uv=0,view_busy=0,was_busy=0;
    wire ack,ur,ut,bt,nt,pt,lr,touch,tx;
    wire [1:0] requested;
    wire [15:0] typ,len;
    wire [63:0] pkt,upkt;
    wire [7:0] error;
    reg txdone=0,lasttx=0,uart_ready=1;
    integer txdelay=0,uart_delay=0,nexts=0,prevs=0,layouts=0,last_layout=-1,requests=0;
    media_control_core #(.VIEW_ENABLE(1),.CLK_HZ(1000)) dut(.clk(clk),.rst(rst),
        .cmd(cmd),.cmd_pending(pending),.cmd_ack_t(ack),.uart_cmd(ucmd),.uart_cmd_valid(uv),
        .uart_cmd_source(2'd1),.uart_cmd_ready(ur),.uart_source_lock(),
        .sd_diag_flags(8'd0),.sd_init_debug_word(16'd0),.image_read_cycles(32'd0),.sd_read_cycles(32'd0),
        .image_source_status(8'd0),.image_source_busy(1'b0),.sd_last_failure_lba(32'd0),
        .sd_last_failure_info(8'd0),.sd_stream_debug(32'd0),.uart_tx_ready(uart_ready),.bt_tx_ready(1'b1),
        .local_auto_toggle(1'b0),.uart_tx_req(ut),.bt_tx_req(bt),.uart_tx_pkt(upkt),
        .image_next_pulse(nt),.image_prev_pulse(pt),.rx_data(8'd0),.rx_valid(1'b0),
        .tx_done_tog(txdone),.tx_tog(tx),.tx_type(typ),.tx_payload_len(len),.tx_pkt(pkt),
        .first_bmp(6'd1),.committed_index(5'd1),.committed_valid(1'b1),.paired_wav(1'b1),
        .fat_state(8'h08),.fat_error(1'b0),.media_state(8'h09),.debug_request(),.pc_snapshot_request(),
        .auto_on(),.auto_period_s(),.volume(),.brightness(),.contrast(),.effect(),.cv_mode(),.osd_mode(),
        .spectrum_on(),.spectrum_sensitivity(),.last_control_error(error),
        .view_busy(view_busy),.uart_cmd_was_busy(was_busy),.layout_request(lr),
        .image_touch_request(touch),.requested_layout(requested));
    always @(posedge clk)begin
        if(nt)nexts<=nexts+1;if(pt)prevs<=prevs+1;
        if(lr)begin layouts<=layouts+1;last_layout<=requested;end
        if(tx!=lasttx)begin lasttx<=tx;txdelay<=3;if(typ==16'h0040 || typ==16'h0042)requests<=requests+1;end
        else if(txdelay>0)begin txdelay<=txdelay-1;if(txdelay==1)txdone<=tx;end
        if(ut)begin uart_ready<=0;uart_delay<=8;end
        else if(uart_delay>0)begin uart_delay<=uart_delay-1;if(uart_delay==1)uart_ready<=1;end
    end
    task automatic eth(input [7:0] key);
        reg oldack;
        integer n;
        begin
            @(negedge clk);oldack=ack;cmd=key;pending=1;n=0;
            while(ack==oldack && n<10000)begin @(negedge clk);n=n+1;end
            if(n==10000)$fatal(1,"command timeout key=%h state=%0d",key,dut.state);
            pending=0;repeat(5)@(negedge clk);
        end
    endtask
    task automatic uart(input [7:0] key);
        begin wait(ur);@(negedge clk);ucmd=key;uv=1;@(negedge clk);uv=0;end
    endtask
    integer baseline;
    initial begin
        repeat(8)@(negedge clk);rst=0;
        eth(8'h36);if(last_layout!=0)$fatal(1,"single layout key");
        eth(8'h37);if(last_layout!=1)$fatal(1,"dual layout key");
        eth(8'h38);if(last_layout!=2)$fatal(1,"quad layout key");
        eth(8'h4e);eth(8'h50);
        if(layouts!=3 || nexts!=1 || prevs!=1)$fatal(1,"normal image commands");
        view_busy=1;eth(8'h4e);eth(8'h50);eth(8'h44);eth(8'h36);eth(8'h37);eth(8'h38);
        if(layouts!=3 || nexts!=1 || prevs!=1 || error!=8)$fatal(1,"busy commands escaped");
        baseline=requests;eth(8'h53);
        if(requests<=baseline)$fatal(1,"S was blocked while busy");
        view_busy=0;was_busy=1;uart(8'h4e);repeat(30)@(negedge clk);wait(ur);
        if(nexts!=1)$fatal(1,"busy-tagged UART ran after idle");was_busy=0;
        // A USB setting is awaiting display ACK while Ethernet N arrives busy.
        // The busy flag may clear before dispatch; the ingress tag must survive.
        uart(8'h5d);wait(dut.state==2);view_busy=1;
        @(negedge clk);cmd=8'h4e;pending=1;
        repeat(8)@(negedge clk);view_busy=0;
        wait(dut.state==0);repeat(100)@(negedge clk);pending=0;
        if(nexts!=1)$fatal(1,"busy-at-arrival Ethernet N was deferred into execution");
        $display("PASS: layout keys, busy admission, S recovery and USB/Ethernet busy-at-arrival tags");$finish;
    end
    initial begin #500000;$fatal(1,"view commands watchdog");end
endmodule
