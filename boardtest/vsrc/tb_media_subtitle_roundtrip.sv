`timescale 1ns/1ps
module tb_media_subtitle_roundtrip;
    reg clk=0;
    always #5 clk=~clk;
    reg rst=1;
    reg [7:0] cmd=0,rx_data=0,display_rx_data=0;
    reg cmd_pending=0,rx_valid=0,display_rx_valid=0;
    reg tx_done_tog=0;
    reg tx_sent_tog=0;
    wire cmd_ack_t,uart_tx_req,image_next_pulse,image_prev_pulse,tx_tog;
    wire [63:0] uart_tx_pkt,tx_pkt;
    wire [15:0] tx_type,tx_payload_len;
    wire [3:0] volume,brightness,contrast;
    wire [1:0] effect,osd_mode,spectrum_sensitivity;
    wire spectrum_on,debug_request,pc_snapshot_request,auto_on;
    wire [3:0] auto_period_s;
    wire [7:0] last_control_error;

    wire set_toggle,status_req_valid,control_ack_valid;
    wire [7:0] set_op,set_value,status_sequence;
    wire [7:0] control_ack_sequence,control_ack_op,control_ack_status,control_ack_value;
    wire subtitle_write_toggle,subtitle_commit_toggle;
    wire [7:0] subtitle_write_index,subtitle_write_char;
    wire [7:0] subtitle_commit_length,subtitle_commit_sequence;

    media_control_core #(.CLK_HZ(10000)) u_media (
        .clk(clk),.rst(rst),.cmd(cmd),.cmd_pending(cmd_pending),.cmd_ack_t(cmd_ack_t),
        .uart_cmd(8'd0),.uart_cmd_valid(1'b0),.uart_cmd_source(2'd1),.uart_cmd_ready(),.uart_source_lock(),
        .sd_diag_flags(8'd0),.sd_init_debug_word(16'd0),.image_read_cycles(32'd0),.sd_read_cycles(32'd0),
        .image_source_status(8'd0),.image_source_busy(1'b0),
        .sd_last_failure_lba(32'd0),.sd_last_failure_info(8'd0),
        .sd_stream_debug(32'd0),
        .uart_tx_ready(1'b1),.bt_tx_ready(1'b0),.uart_tx_req(uart_tx_req),.bt_tx_req(),
        .local_auto_toggle(1'b0),.uart_tx_pkt(uart_tx_pkt),
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
    media_display_control_rx u_display (
        .clk(clk),.rst(rst),.rx_data(display_rx_data),.rx_valid(display_rx_valid),
        .set_toggle(set_toggle),.set_op(set_op),.set_value(set_value),
        .status_req_valid(status_req_valid),.status_sequence(status_sequence),
        .control_ack_valid(control_ack_valid),.control_ack_sequence(control_ack_sequence),
        .control_ack_op(control_ack_op),.control_ack_status(control_ack_status),
        .control_ack_value(control_ack_value),.subtitle_write_toggle(subtitle_write_toggle),
        .subtitle_write_index(subtitle_write_index),.subtitle_write_char(subtitle_write_char),
        .subtitle_commit_toggle(subtitle_commit_toggle),
        .subtitle_commit_length(subtitle_commit_length),
        .subtitle_commit_sequence(subtitle_commit_sequence)
    );

    task automatic send_pc_command_byte(input [7:0] value);
        begin
            @(negedge clk);cmd=value;cmd_pending=1;
            @(negedge clk);cmd_pending=0;
            @(negedge clk);
        end
    endtask
    task automatic send_display_byte(input [7:0] value);
        begin
            @(negedge clk);display_rx_data=value;display_rx_valid=1;
            @(posedge clk);
        end
    endtask
    task automatic send_to_display(input [7:0] type_lo,input [15:0] length,input [63:0] body);
        integer i;
        begin
            send_display_byte(8'haa);send_display_byte(8'hbb);
            send_display_byte(8'hcc);send_display_byte(8'hdd);
            send_display_byte(8'h00);send_display_byte(type_lo);
            send_display_byte(length[15:8]);send_display_byte(length[7:0]);
            for(i=0;i<length;i=i+1)send_display_byte(body[i*8+:8]);
            @(negedge clk);display_rx_valid=0;
            @(posedge clk);@(negedge clk);
        end
    endtask
    task automatic send_to_media(input [7:0] type_lo,input [15:0] length,input [63:0] body);
        integer i;
        begin
            @(negedge clk);rx_data=8'haa;rx_valid=1;@(posedge clk);
            @(negedge clk);rx_data=8'hbb;@(posedge clk);
            @(negedge clk);rx_data=8'hcc;@(posedge clk);
            @(negedge clk);rx_data=8'hdd;@(posedge clk);
            @(negedge clk);rx_data=8'h00;@(posedge clk);
            @(negedge clk);rx_data=type_lo;@(posedge clk);
            @(negedge clk);rx_data=length[15:8];@(posedge clk);
            @(negedge clk);rx_data=length[7:0];@(posedge clk);
            for(i=0;i<length;i=i+1)begin
                @(negedge clk);rx_data=body[i*8+:8];@(posedge clk);
            end
            @(negedge clk);rx_valid=0;@(posedge clk);repeat(3)@(posedge clk);
        end
    endtask
    task automatic service_media_packet(input [15:0] expected_type);
        reg [63:0] body;
        reg [15:0] length;
        reg [7:0] type_lo;
        begin
            while(tx_tog==tx_sent_tog)@(negedge clk);
            type_lo=tx_type[7:0];length=tx_payload_len;body=tx_pkt;
            if(tx_type!==expected_type)
                $fatal(1,"media packet type got=%04x expected=%04x",tx_type,expected_type);
            send_to_display(type_lo,length,body);
            tx_sent_tog=tx_tog;
            @(negedge clk);tx_done_tog=tx_sent_tog;
            repeat(2)@(negedge clk);
        end
    endtask

    initial begin
        repeat(3)@(negedge clk);rst=0;
        // V1 T transaction for ASCII "TEST": len 4, chars D4 C5 D3 D4,
        // XOR checksum 0x12 encoded as 81 82.
        send_pc_command_byte(8'h54);
        send_pc_command_byte(8'h84);
        send_pc_command_byte(8'hd4);
        send_pc_command_byte(8'hc5);
        send_pc_command_byte(8'hd3);
        send_pc_command_byte(8'hd4);
        send_pc_command_byte(8'h81);
        send_pc_command_byte(8'h82);

        service_media_packet(16'h0044);
        if(!u_display.subtitle_active || u_display.subtitle_length!=4 || u_display.subtitle_checksum!=8'h12)
            $fatal(1,"display rejected BEGIN len=%0d checksum=%02x",u_display.subtitle_length,u_display.subtitle_checksum);

        service_media_packet(16'h0045);
        if(!subtitle_write_toggle || subtitle_write_index!=0 || subtitle_write_char!=8'h54)
            $fatal(1,"first DATA mismatch index=%0d char=%02x",subtitle_write_index,subtitle_write_char);
        service_media_packet(16'h0045);
        if(subtitle_write_index!=1 || subtitle_write_char!=8'h45)$fatal(1,"second DATA mismatch");
        service_media_packet(16'h0045);
        if(subtitle_write_index!=2 || subtitle_write_char!=8'h53)$fatal(1,"third DATA mismatch");
        service_media_packet(16'h0045);
        if(subtitle_write_index!=3 || subtitle_write_char!=8'h54)$fatal(1,"fourth DATA mismatch");

        service_media_packet(16'h0046);
        if(subtitle_commit_toggle!==1'b1 || subtitle_commit_length!=4 || subtitle_commit_sequence!=0)
            $fatal(1,"display rejected END/commit");
        // The display's storage-domain commit ACK goes back over type 0x0041.
        send_to_media(8'h41,16'd4,{32'd0,8'd4,8'd0,8'd8,8'd0});
        while(tx_tog==tx_sent_tog)@(negedge clk);
        if(tx_type!==16'h0002 || tx_pkt[63]!==1'b1 || tx_pkt[7:0]!==8'h5a ||
           tx_pkt[15:8]!==8'h54 || tx_pkt[47:45]!==3'b101 ||
           tx_pkt[23:16]!==8'h12 || tx_pkt[31:24]!==8'd4 ||
           tx_pkt[39:32]!==8'd7 || tx_pkt[55:48]!==8'h12)
            $fatal(1,"PC did not receive successful V1 subtitle ACK pkt=%016x",tx_pkt);
        tx_sent_tog=tx_tog;@(negedge clk);tx_done_tog=tx_sent_tog;repeat(4)@(negedge clk);

        // A bad V1 checksum must be rejected locally and report stage 1.
        send_pc_command_byte(8'h54);send_pc_command_byte(8'h81);
        send_pc_command_byte(8'hc1);send_pc_command_byte(8'h84);send_pc_command_byte(8'h81);
        while(tx_tog==tx_sent_tog)@(negedge clk);
        if(tx_type!==16'h0002 || tx_pkt[63]!==1'b0 || tx_pkt[47:45]!==3'b101 ||
           ((tx_pkt[47:40]>>1)&8'h0f)!==4'd1 || tx_pkt[23:16]!==8'h41 ||
           tx_pkt[31:24]!==8'd1 || tx_pkt[39:32]!==8'd4 || tx_pkt[55:48]!==8'h40)
            $fatal(1,"PC reject ACK did not identify subtitle parser error 1, pkt=%016x",tx_pkt);
        $display("PASS: subtitle roundtrip commit plus V1 checksum failure code");
        $finish;
    end
    initial begin
        #200000;
        $fatal(1,"timeout in media/display subtitle round trip");
    end
endmodule
