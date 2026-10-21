`timescale 1ns/1ps
module tb_media_control_reply_parse;
    reg clk=0;
    always #5 clk=~clk;
    reg rst=1;
    reg [7:0] cmd=0,uart_cmd=0,rx_data=0;
    reg cmd_pending=0,uart_cmd_valid=0,uart_tx_ready=1,local_auto_toggle=0,rx_valid=0;
    wire cmd_ack_t,uart_tx_req,image_next_pulse,image_prev_pulse,tx_tog;
    wire [63:0] uart_tx_pkt,tx_pkt;
    wire [15:0] tx_type,tx_payload_len;
    reg tx_done_tog=0;
    wire [3:0] volume,brightness,contrast;
    wire [1:0] effect,osd_mode,spectrum_sensitivity;
    wire spectrum_on;
    wire debug_request,pc_snapshot_request,auto_on;
    wire [3:0] auto_period_s;
    wire [7:0] last_control_error;

    always @(posedge clk) begin
        if(rst) tx_done_tog<=0;
        else tx_done_tog<=tx_tog;
    end

    media_control_core #(.CLK_HZ(1000)) dut (
        .clk(clk),.rst(rst),.cmd(cmd),.cmd_pending(cmd_pending),.cmd_ack_t(cmd_ack_t),
        .uart_cmd(uart_cmd),.uart_cmd_valid(uart_cmd_valid),.uart_cmd_source(2'd1),.uart_cmd_ready(),.uart_source_lock(),
        .sd_diag_flags(8'd0),.sd_init_debug_word(16'd0),.image_read_cycles(32'd0),.sd_read_cycles(32'd0),
        .image_source_status(8'd0),.image_source_busy(1'b0),
        .sd_last_failure_lba(32'd0),.sd_last_failure_info(8'd0),
        .sd_stream_debug(32'd0),
        .uart_tx_ready(uart_tx_ready),.bt_tx_ready(1'b0),.bt_tx_req(),
        .local_auto_toggle(local_auto_toggle),.uart_tx_req(uart_tx_req),.uart_tx_pkt(uart_tx_pkt),
        .image_next_pulse(image_next_pulse),.image_prev_pulse(image_prev_pulse),
        .rx_data(rx_data),.rx_valid(rx_valid),.tx_done_tog(tx_done_tog),.tx_tog(tx_tog),
        .tx_type(tx_type),.tx_payload_len(tx_payload_len),.tx_pkt(tx_pkt),
        .first_bmp(6'd0),.committed_index(5'd0),.committed_valid(1'b1),.paired_wav(1'b0),
        .fat_state(8'd0),.fat_error(1'b0),.media_state(4'd0),
        .debug_request(debug_request),.pc_snapshot_request(pc_snapshot_request),
        .auto_on(auto_on),.auto_period_s(auto_period_s),.volume(volume),
        .brightness(brightness),.contrast(contrast),.effect(effect),.osd_mode(osd_mode),
        .spectrum_on(spectrum_on),.spectrum_sensitivity(spectrum_sensitivity),
        .last_control_error(last_control_error)
    );

    task automatic send_byte(input [7:0] value);
        begin
            @(negedge clk);rx_data=value;rx_valid=1;
            @(posedge clk);
        end
    endtask
    task automatic send_reply(input [7:0] type_lo,input [15:0] length,input [63:0] body);
        integer i;
        begin
            send_byte(8'haa);send_byte(8'hbb);send_byte(8'hcc);send_byte(8'hdd);
            send_byte(8'h00);send_byte(type_lo);
            send_byte(length[15:8]);send_byte(length[7:0]);
            for(i=0;i<length;i=i+1)send_byte(body[i*8+:8]);
            @(negedge clk);rx_valid=0;
            @(posedge clk);
            repeat(3)@(posedge clk);
        end
    endtask
    task automatic send_command(input [7:0] value);
        begin
            @(negedge clk);cmd=value;cmd_pending=1;
            @(negedge clk);cmd_pending=0;
            repeat(4)@(posedge clk);
        end
    endtask

    initial begin
        repeat(3)@(negedge clk);rst=0;
        // Volume-down makes the display SET path request value 7.
        send_command(8'h2d);
        wait(dut.state==2);
        if(tx_type!==16'h0040)$fatal(1,"expected SET request, got %04x",tx_type);
        // V1 control replies send the type high byte first: [0x00,0x41].
        send_reply(8'h41,16'd4,{32'd0,8'd7,8'd0,8'd1,8'd0});
        if(volume!==4'd7 || last_control_error!==0)
            $fatal(1,"0x0041 ACK was not accepted: volume=%0d err=%0d",volume,last_control_error);

        wait(dut.state==0);
        send_command(8'h53);
        wait(dut.state==3);
        if(tx_type!==16'h0042)$fatal(1,"expected STATUS request, got %04x",tx_type);
        // [0x00,0x43] STATUS returns every display-side control setting.
        send_reply(8'h43,16'd8,{8'd3,8'd1,8'd2,8'd2,8'd3,8'd5,8'd7,8'd1});
        if(volume!==4'd7 || brightness!==4'd5 || contrast!==4'd3 ||
           effect!==2'd2 || osd_mode!==2'd2 || spectrum_on!==1'b1 || spectrum_sensitivity!==2'd3)
            $fatal(1,"0x0043 STATUS was not accepted: vol=%0d bri=%0d contrast=%0d effect=%0d osd=%0d spec=%b sens=%0d",
                   volume,brightness,contrast,effect,osd_mode,spectrum_on,spectrum_sensitivity);
        $display("PASS: media board accepts V1 big-endian 0x0041 ACK and 0x0043 STATUS replies");
        $finish;
    end
    initial begin
        #200000;
        $fatal(1,"timeout waiting for display reply parser");
    end
endmodule
