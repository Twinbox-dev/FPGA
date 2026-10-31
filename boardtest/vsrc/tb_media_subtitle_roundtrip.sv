`timescale 1ns/1ps
module tb_media_subtitle_roundtrip;
    reg clk=0;
    always #5 clk=~clk;
    reg rst=1;
    reg [7:0] cmd=0,rx_data=0,display_rx_data=0;
    reg cmd_pending=0,rx_valid=0,display_rx_valid=0;
    reg tx_done_tog=0;
    reg tx_sent_tog=0;
    reg corrupt_subtitle_end=0;
    integer cycle_count=0,previous_subtitle_packet_cycle=-1;
    always @(posedge clk) cycle_count<=cycle_count+1;
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
    reg video_clk=0,vs=0;
    always #7 video_clk=~video_clk;
    wire [7:0] subtitle_active_len,subtitle_rd_char;
    wire subtitle_store_ack_toggle;
    reg [7:0] subtitle_rd_index=0;
    reg [2:0] subtitle_write_sync_sd=0,subtitle_commit_sync_sd=0,subtitle_store_ack_sync=0;
    reg subtitle_write_seen_sd=0,subtitle_commit_seen_sd=0,subtitle_store_ack_seen=0;
    reg [7:0] subtitle_index_s0=0,subtitle_index_s1=0,subtitle_char_s0=0,subtitle_char_s1=0;
    reg [7:0] subtitle_length_s0=0,subtitle_length_s1=0,subtitle_sequence_s0=0,subtitle_sequence_s1=0;
    reg subtitle_wr_en_sd=0,subtitle_commit_toggle_sd=0,subtitle_waiting_ack_sd=0;
    reg [7:0] subtitle_wr_index_sd=0,subtitle_wr_char_sd=8'h20,subtitle_commit_len_sd=0;
    reg [7:0] subtitle_pending_sequence_sd=0,subtitle_pending_length_sd=0;
    reg subtitle_ack_toggle_sd=0;
    reg [7:0] subtitle_ack_sequence_sd=0,subtitle_ack_value_sd=0;
    reg subtitle_ack_seen_eth=0;
    reg [2:0] subtitle_ack_sync_eth=0;
    reg [7:0] subtitle_ack_seq_e0=0,subtitle_ack_seq_e1=0;
    reg [7:0] subtitle_ack_value_e0=0,subtitle_ack_value_e1=0;
    reg [7:0] subtitle_ack_sequence_eth=0,subtitle_ack_value_eth=0;
    reg subtitle_ack_valid_eth=0;

    subtitle_store u_store(.sd_clk(clk),.video_clk(video_clk),.rst(rst),
        .wr_en(subtitle_wr_en_sd),.wr_index(subtitle_wr_index_sd),.wr_char(subtitle_wr_char_sd),
        .commit_toggle(subtitle_commit_toggle_sd),.commit_len(subtitle_commit_len_sd),
        .swap_ack_toggle(subtitle_store_ack_toggle),.vs(vs),.rd_index(subtitle_rd_index),
        .rd_char(subtitle_rd_char),.active_len(subtitle_active_len),.text_changed_pulse());

    // Mirror the production SD/video/ETH subtitle commit handshake so this
    // regression checks the storage acknowledgement and returned length too.
    always @(posedge clk or posedge rst) begin
        if(rst) begin
            subtitle_write_sync_sd<=0;subtitle_commit_sync_sd<=0;subtitle_store_ack_sync<=0;
            subtitle_write_seen_sd<=0;subtitle_commit_seen_sd<=0;subtitle_store_ack_seen<=0;
            subtitle_index_s0<=0;subtitle_index_s1<=0;subtitle_char_s0<=0;subtitle_char_s1<=0;
            subtitle_length_s0<=0;subtitle_length_s1<=0;subtitle_sequence_s0<=0;subtitle_sequence_s1<=0;
            subtitle_wr_en_sd<=0;subtitle_wr_index_sd<=0;subtitle_wr_char_sd<=8'h20;
            subtitle_commit_toggle_sd<=0;subtitle_commit_len_sd<=0;
            subtitle_pending_sequence_sd<=0;subtitle_pending_length_sd<=0;subtitle_waiting_ack_sd<=0;
            subtitle_ack_toggle_sd<=0;subtitle_ack_sequence_sd<=0;subtitle_ack_value_sd<=0;
            subtitle_ack_sync_eth<=0;subtitle_ack_seen_eth<=0;
            subtitle_ack_seq_e0<=0;subtitle_ack_seq_e1<=0;subtitle_ack_value_e0<=0;subtitle_ack_value_e1<=0;
            subtitle_ack_sequence_eth<=0;subtitle_ack_value_eth<=0;subtitle_ack_valid_eth<=0;
        end else begin
            subtitle_write_sync_sd<={subtitle_write_sync_sd[1:0],subtitle_write_toggle};
            subtitle_commit_sync_sd<={subtitle_commit_sync_sd[1:0],subtitle_commit_toggle};
            subtitle_store_ack_sync<={subtitle_store_ack_sync[1:0],subtitle_store_ack_toggle};
            subtitle_index_s0<=subtitle_write_index;subtitle_index_s1<=subtitle_index_s0;
            subtitle_char_s0<=subtitle_write_char;subtitle_char_s1<=subtitle_char_s0;
            subtitle_length_s0<=subtitle_commit_length;subtitle_length_s1<=subtitle_length_s0;
            subtitle_sequence_s0<=subtitle_commit_sequence;subtitle_sequence_s1<=subtitle_sequence_s0;
            subtitle_wr_en_sd<=0;subtitle_ack_valid_eth<=0;
            if(subtitle_write_sync_sd[2]!=subtitle_write_seen_sd)begin
                subtitle_write_seen_sd<=subtitle_write_sync_sd[2];
                subtitle_wr_index_sd<=subtitle_index_s1;subtitle_wr_char_sd<=subtitle_char_s1;
                subtitle_wr_en_sd<=1;
            end
            if(subtitle_commit_sync_sd[2]!=subtitle_commit_seen_sd)begin
                subtitle_commit_seen_sd<=subtitle_commit_sync_sd[2];
                subtitle_commit_len_sd<=subtitle_length_s1;
                subtitle_pending_length_sd<=subtitle_length_s1;
                subtitle_pending_sequence_sd<=subtitle_sequence_s1;
                subtitle_commit_toggle_sd<=~subtitle_commit_toggle_sd;
                subtitle_waiting_ack_sd<=1;
            end
            if(subtitle_store_ack_sync[2]!=subtitle_store_ack_seen)begin
                subtitle_store_ack_seen<=subtitle_store_ack_sync[2];
                if(subtitle_waiting_ack_sd)begin
                    subtitle_ack_sequence_sd<=subtitle_pending_sequence_sd;
                    subtitle_ack_value_sd<=subtitle_pending_length_sd;
                    subtitle_ack_toggle_sd<=~subtitle_ack_toggle_sd;
                    subtitle_waiting_ack_sd<=0;
                end
            end
            subtitle_ack_sync_eth<={subtitle_ack_sync_eth[1:0],subtitle_ack_toggle_sd};
            subtitle_ack_seq_e0<=subtitle_ack_sequence_sd;subtitle_ack_seq_e1<=subtitle_ack_seq_e0;
            subtitle_ack_value_e0<=subtitle_ack_value_sd;subtitle_ack_value_e1<=subtitle_ack_value_e0;
            if(subtitle_ack_sync_eth[2]!=subtitle_ack_seen_eth)begin
                subtitle_ack_seen_eth<=subtitle_ack_sync_eth[2];
                subtitle_ack_sequence_eth<=subtitle_ack_seq_e1;
                subtitle_ack_value_eth<=subtitle_ack_value_e1;
                subtitle_ack_valid_eth<=1;
            end
        end
    end

    media_control_core #(.CLK_HZ(10000)) u_media (
        .view_busy(1'b0),.uart_cmd_was_busy(1'b0),.layout_request(),.requested_layout(),.image_touch_request(),
        .sensor_snapshot_request(),.sensor_snapshot_release_toggle(),
        .sensor_snapshot_ready(1'b0),.sensor_snapshot_data(336'd0),
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
        reg reject_seen;
        reg [7:0] reject_seq,reject_op,reject_status,reject_value;
        begin
            while(tx_tog==tx_sent_tog)@(negedge clk);
            type_lo=tx_type[7:0];length=tx_payload_len;body=tx_pkt;
            if(tx_type!==expected_type)
                $fatal(1,"media packet type got=%04x expected=%04x",tx_type,expected_type);
            if(expected_type==16'h0046 && corrupt_subtitle_end)
                body[23:16]=body[23:16]^8'h01;
            if(expected_type==16'h0044 || expected_type==16'h0045 || expected_type==16'h0046)begin
                if(previous_subtitle_packet_cycle>=0 && cycle_count-previous_subtitle_packet_cycle<10)
                    $fatal(1,"subtitle UDP packets spaced too closely: %0d cycles",cycle_count-previous_subtitle_packet_cycle);
                previous_subtitle_packet_cycle=cycle_count;
            end
            send_to_display(type_lo,length,body);
            reject_seen=control_ack_valid;
            reject_seq=control_ack_sequence;reject_op=control_ack_op;
            reject_status=control_ack_status;reject_value=control_ack_value;
            tx_sent_tog=tx_tog;
            @(negedge clk);tx_done_tog=tx_sent_tog;
            repeat(2)@(negedge clk);
            if(expected_type==16'h0046 && corrupt_subtitle_end)begin
                if(!reject_seen || reject_op!=8'd8 || reject_status!=8'd1 || reject_value!=8'd5)
                    $fatal(1,"display reject diagnostic mismatch seen=%b op=%0d status=%0d value=%0d",
                           reject_seen,reject_op,reject_status,reject_value);
                send_to_media(8'h41,16'd4,
                    {32'd0,reject_value,reject_status,reject_op,reject_seq});
            end
        end
    endtask

    initial begin
        repeat(3)@(negedge clk);rst=0;
        // V1 T transaction for a 13-character string. This exercises the
        // observed board case: length, all character DATA packets, checksum,
        // display END acceptance and the returned length value.
        send_pc_command_byte(8'h54);
        send_pc_command_byte(8'h8d); // len 13
        send_pc_command_byte(8'hd3);send_pc_command_byte(8'hf5);
        send_pc_command_byte(8'he2);send_pc_command_byte(8'hf4);
        send_pc_command_byte(8'he9);send_pc_command_byte(8'hf4);
        send_pc_command_byte(8'hec);send_pc_command_byte(8'he5);
        send_pc_command_byte(8'ha0);send_pc_command_byte(8'hb2);
        send_pc_command_byte(8'hb0);send_pc_command_byte(8'hb2);
        send_pc_command_byte(8'hb6);
        send_pc_command_byte(8'h80);send_pc_command_byte(8'h8f); // checksum 0x0f

        service_media_packet(16'h0044);
        if(!u_display.subtitle_active || u_display.subtitle_length!=13 || u_display.subtitle_checksum!=8'h0f)
            $fatal(1,"display rejected BEGIN len=%0d checksum=%02x",u_display.subtitle_length,u_display.subtitle_checksum);
        for(integer char_idx=0;char_idx<13;char_idx=char_idx+1)begin
            service_media_packet(16'h0045);
            if(u_display.subtitle_next_offset!=char_idx+1 || u_display.subtitle_bad)
                $fatal(1,"display rejected DATA idx=%0d next=%0d bad=%b",char_idx,u_display.subtitle_next_offset,u_display.subtitle_bad);
        end
        service_media_packet(16'h0046);
        if(subtitle_commit_toggle!==1'b1 || subtitle_commit_length!=13 || subtitle_commit_sequence!=0)
            $fatal(1,"display rejected END/commit len=%0d seq=%0d",subtitle_commit_length,subtitle_commit_sequence);
        // Commit into the actual dual-clock subtitle store, wait for a VS
        // boundary, and return its synchronized length ACK to the media core.
        wait(u_store.pending);
        @(negedge video_clk);vs=1;@(negedge video_clk);vs=0;
        wait(subtitle_ack_valid_eth);
        if(subtitle_active_len!=13 || subtitle_ack_value_eth!=13 || subtitle_ack_sequence_eth!=0)
            $fatal(1,"subtitle store ACK mismatch active=%0d ack_len=%0d seq=%0d",
                   subtitle_active_len,subtitle_ack_value_eth,subtitle_ack_sequence_eth);
        send_to_media(8'h41,16'd4,{32'd0,subtitle_ack_value_eth,8'd0,8'd8,subtitle_ack_sequence_eth});
        while(tx_tog==tx_sent_tog)@(negedge clk);
        if(tx_type!==16'h0002 || tx_pkt[63]!==1'b1 || tx_pkt[7:0]!==8'h5a ||
           tx_pkt[15:8]!==8'h54 || tx_pkt[47:45]!==3'b101 ||
           tx_pkt[23:16]!==8'h0f || tx_pkt[31:24]!==8'd13 ||
           tx_pkt[39:32]!==8'd16 || tx_pkt[55:48]!==8'h0f)
            $fatal(1,"PC did not receive successful 13-char subtitle ACK pkt=%016x",tx_pkt);
        tx_sent_tog=tx_tog;@(negedge clk);tx_done_tog=tx_sent_tog;repeat(4)@(negedge clk);

        // Force display END checksum rejection three times and ensure the
        // specific reject value reaches the existing PC ACK diagnostic byte.
        send_pc_command_byte(8'h54);send_pc_command_byte(8'h81);
        send_pc_command_byte(8'hc1);send_pc_command_byte(8'h84);send_pc_command_byte(8'h80);
        corrupt_subtitle_end=1;
        for(integer attempt=0;attempt<3;attempt=attempt+1)begin
            service_media_packet(16'h0044);
            service_media_packet(16'h0045);
            service_media_packet(16'h0046);
        end
        corrupt_subtitle_end=0;
        while(tx_tog==tx_sent_tog)@(negedge clk);
        if(tx_type!==16'h0002 || tx_pkt[63]!==1'b0 || tx_pkt[47:45]!==3'b101 ||
           ((tx_pkt[47:40]>>1)&8'h0f)!==4'd2 || tx_pkt[55:48]!==8'h85)
            $fatal(1,"PC ACK did not preserve display rejection reason 5, pkt=%016x",tx_pkt);
        tx_sent_tog=tx_tog;@(negedge clk);tx_done_tog=tx_sent_tog;repeat(4)@(negedge clk);

        // A bad V1 checksum must be rejected locally and report stage 1.
        send_pc_command_byte(8'h54);send_pc_command_byte(8'h81);
        send_pc_command_byte(8'hc1);send_pc_command_byte(8'h84);send_pc_command_byte(8'h81);
        while(tx_tog==tx_sent_tog)@(negedge clk);
        if(tx_type!==16'h0002 || tx_pkt[63]!==1'b0 || tx_pkt[47:45]!==3'b101 ||
           ((tx_pkt[47:40]>>1)&8'h0f)!==4'd1 || tx_pkt[23:16]!==8'h41 ||
           tx_pkt[31:24]!==8'd1 || tx_pkt[39:32]!==8'd4 || tx_pkt[55:48]!==8'h40)
            $fatal(1,"PC reject ACK did not identify subtitle parser error 1, pkt=%016x",tx_pkt);
        $display("PASS: subtitle commit, display END reject reason propagation, 1ms pacing and PC checksum failure");
        $finish;
    end
    initial begin
        #200000;
        $fatal(1,"timeout in media/display subtitle round trip");
    end
endmodule
