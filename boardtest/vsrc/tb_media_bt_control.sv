`timescale 1ns/1ps

module tb_media_bt_control;
    localparam integer CLK_HZ=125000000;
    localparam integer BT_BIT_CYC=CLK_HZ/9600;
    localparam integer USB_BIT_CYC=CLK_HZ/1000000;
    reg clk=0;always #4 clk=~clk;
    reg rst=1;
    reg usb_rx=1,bt_rx=1;
    wire usb_tx,bt_tx;
    wire usb_ready,bt_ready;
    wire [7:0] usb_cmd,bt_cmd;
    wire usb_cmd_valid,bt_cmd_valid;
    wire [7:0] serial_cmd;
    wire [1:0] serial_source;
    wire [1:0] serial_source_lock;
    wire serial_valid,serial_ready;
    wire [7:0] usb_overflow,bt_overflow;
    reg [7:0] eth_cmd=0,rx_data=0;
    reg eth_cmd_pending=0,rx_valid=0;
    wire eth_cmd_ack;
    reg tx_done_tog=0;
    wire tx_tog;
    wire [15:0] tx_type,tx_payload_len;
    wire [63:0] tx_pkt;
    wire usb_tx_req,bt_tx_req;
    wire [63:0] serial_tx_pkt;
    wire next_pulse,prev_pulse,debug_request,pc_snapshot_request;
    wire auto_on;
    wire [3:0] auto_period,volume,brightness,contrast;
    wire [1:0] effect,osd_mode,spectrum_sensitivity;
    wire spectrum_on;
    wire [7:0] control_error;
    reg [4:0] committed_index=0;
    reg committed_valid=0,paired_wav=0,fat_error=0;
    reg [5:0] first_bmp=0;
    reg [7:0] fat_state=0,media_state=0;
    reg [7:0] sd_diag_test=8'hFD;
    reg [15:0] sd_init_debug_test=16'hFCFF;
    reg [7:0] source_status_test=0;
    reg source_busy_test=0;
    reg [31:0] sd_failure_lba_test=0;
    reg [7:0] sd_failure_info_test=0;
    reg hold_next_display=0,display_hold_active=0,release_display=0;
    reg [7:0] usb_packet [0:7],bt_packet0 [0:7],bt_packet1 [0:7];
    reg [7:0] command_table [0:18];
    reg [7:0] received_byte;
    reg tx_seen=0,old_tx_tog,old_eth_ack;
    integer i,j;

    uart_link #(.CLK_FREQ_HZ(CLK_HZ),.BAUD(1000000)) u_usb_uart (
        .tx_count(5'd8),
        .clk(clk),.rst(rst),.rx(usb_rx),.tx(usb_tx),.tx_ready(usb_ready),
        .cmd(usb_cmd),.cmd_val(usb_cmd_valid),.tx_req(usb_tx_req),.tx_pkt(serial_tx_pkt)
    );
    uart_link #(.CLK_FREQ_HZ(CLK_HZ),.BAUD(9600)) u_bt_uart (
        .tx_count(5'd8),
        .clk(clk),.rst(rst),.rx(bt_rx),.tx(bt_tx),.tx_ready(bt_ready),
        .cmd(bt_cmd),.cmd_val(bt_cmd_valid),.tx_req(bt_tx_req),.tx_pkt(serial_tx_pkt)
    );
    media_uart_arbiter u_arb (
        .view_busy(1'b0),.cmd_was_busy(),
        .clk(clk),.rst(rst),.usb_cmd(usb_cmd),.usb_valid(usb_cmd_valid),
        .bt_cmd(bt_cmd),.bt_valid(bt_cmd_valid),.cmd(serial_cmd),.cmd_source(serial_source),
        .source_lock(serial_source_lock),.cmd_valid(serial_valid),.cmd_ready(serial_ready),
        .usb_overflow_count(usb_overflow),.bt_overflow_count(bt_overflow)
    );
    media_control_core #(.CLK_HZ(CLK_HZ)) u_core (
        .view_busy(1'b0),.uart_cmd_was_busy(1'b0),.layout_request(),.requested_layout(),.image_touch_request(),
        .clk(clk),.rst(rst),.cmd(eth_cmd),.cmd_pending(eth_cmd_pending),.cmd_ack_t(eth_cmd_ack),
        .uart_cmd(serial_cmd),.uart_cmd_valid(serial_valid),.uart_cmd_source(serial_source),
        .uart_cmd_ready(serial_ready),.uart_source_lock(serial_source_lock),
        .sd_diag_flags(sd_diag_test),.sd_init_debug_word(sd_init_debug_test),
        .image_read_cycles(32'h12345678),.sd_read_cycles(32'h00001ABC),
        .image_source_status(source_status_test),.image_source_busy(source_busy_test),
        .sd_last_failure_lba(sd_failure_lba_test),.sd_last_failure_info(sd_failure_info_test),
        .sd_stream_debug(32'h12345678),
        .uart_tx_ready(usb_ready),.bt_tx_ready(bt_ready),
        .local_auto_toggle(1'b0),.uart_tx_req(usb_tx_req),.bt_tx_req(bt_tx_req),.uart_tx_pkt(serial_tx_pkt),
        .image_next_pulse(next_pulse),.image_prev_pulse(prev_pulse),
        .rx_data(rx_data),.rx_valid(rx_valid),.tx_done_tog(tx_done_tog),.tx_tog(tx_tog),
        .tx_type(tx_type),.tx_payload_len(tx_payload_len),.tx_pkt(tx_pkt),
        .first_bmp(first_bmp),.committed_index(committed_index),.committed_valid(committed_valid),
        .paired_wav(paired_wav),.fat_state(fat_state),.fat_error(fat_error),.media_state(media_state),
        .debug_request(debug_request),.pc_snapshot_request(pc_snapshot_request),
        .auto_on(auto_on),.auto_period_s(auto_period),.volume(volume),.brightness(brightness),
        .contrast(contrast),.effect(effect),.osd_mode(osd_mode),.spectrum_on(spectrum_on),
        .spectrum_sensitivity(spectrum_sensitivity),.last_control_error(control_error)
    );

    task automatic send_uart_byte(input use_bt,input [7:0] value);
        integer n,period;
        begin
            period=use_bt?BT_BIT_CYC:USB_BIT_CYC;
            if(use_bt)bt_rx=0;else usb_rx=0;
            repeat(period)@(posedge clk);
            for(n=0;n<8;n=n+1)begin
                if(use_bt)bt_rx=value[n];else usb_rx=value[n];
                repeat(period)@(posedge clk);
            end
            if(use_bt)bt_rx=1;else usb_rx=1;
            repeat(period)@(posedge clk);
        end
    endtask

    task automatic send_pair_bt(input [7:0] value);
        begin send_uart_byte(1'b1,value);send_uart_byte(1'b1,~value);end
    endtask
    task automatic send_pair_usb(input [7:0] value);
        begin send_uart_byte(1'b0,value);send_uart_byte(1'b0,~value);end
    endtask

    task automatic receive_uart_byte(input use_bt,output [7:0] value);
        integer n,period;
        begin
            period=use_bt?BT_BIT_CYC:USB_BIT_CYC;
            if(use_bt)begin while(bt_tx!==1'b0)@(posedge clk);end
            else begin while(usb_tx!==1'b0)@(posedge clk);end
            repeat(period+period/2)@(posedge clk);
            for(n=0;n<8;n=n+1)begin
                if(use_bt)value[n]=bt_tx;else value[n]=usb_tx;
                repeat(period)@(posedge clk);
            end
            if(use_bt && bt_tx!==1'b1)$fatal(1,"HC-08 TX stop bit failed");
            if(!use_bt && usb_tx!==1'b1)$fatal(1,"USB UART TX stop bit failed");
        end
    endtask

    task automatic receive_packet(input use_bt,output reg [7:0] packet[0:7]);
        integer n;
        reg [7:0] b;
        begin
            for(n=0;n<8;n=n+1)begin receive_uart_byte(use_bt,b);packet[n]=b;end
        end
    endtask

    task automatic check_packet_key(input use_bt,input [7:0] expected_key);
        reg [7:0] p[0:7];
        begin
            receive_packet(use_bt,p);
            if(p[0]!==8'h5A || p[1]!==expected_key)
                $fatal(1,"ACK route/key mismatch on %0s: [%02x,%02x], expected key %02x",
                    use_bt?"BT":"USB",p[0],p[1],expected_key);
        end
    endtask

    task automatic emit_display_reply(input [15:0] kind,input [7:0] seq,
                                      input [7:0] op,input [7:0] value);
        reg [7:0] body[0:7];
        integer n;
        begin
            body[0]=seq;body[1]=op;body[2]=0;body[3]=value;
            body[4]=6;body[5]=5;body[6]=4;body[7]=8'h07;
            @(negedge clk);rx_data=8'hAA;rx_valid=1;
            @(negedge clk);rx_data=8'hBB;
            @(negedge clk);rx_data=8'hCC;
            @(negedge clk);rx_data=8'hDD;
            @(negedge clk);rx_data=kind[15:8];
            @(negedge clk);rx_data=kind[7:0];
            @(negedge clk);rx_data=0;
            @(negedge clk);rx_data=(kind==16'h0041)?4:8;
            for(n=0;n<((kind==16'h0041)?4:8);n=n+1)begin
                @(negedge clk);rx_data=body[n];
            end
            @(negedge clk);rx_valid=0;
        end
    endtask

    task automatic emit_display_status(input [7:0] seq);
        integer n;
        reg [7:0] body[0:7];
        begin
            body[0]=seq;body[1]=6;body[2]=5;body[3]=4;
            body[4]=2;body[5]=1;body[6]=1;body[7]=3;
            @(negedge clk);rx_data=8'hAA;rx_valid=1;
            @(negedge clk);rx_data=8'hBB;
            @(negedge clk);rx_data=8'hCC;
            @(negedge clk);rx_data=8'hDD;
            @(negedge clk);rx_data=8'h00;
            @(negedge clk);rx_data=8'h43;
            @(negedge clk);rx_data=0;
            @(negedge clk);rx_data=8;
            for(n=0;n<8;n=n+1)begin @(negedge clk);rx_data=body[n];end
            @(negedge clk);rx_valid=0;
        end
    endtask

    // PC/display stand-in: it drains every outgoing packet and returns V1 ACKs.
    initial begin : mock_display
        reg [7:0] seq,op,value;
        wait(!rst);
        forever begin
            @(tx_tog);#1;
            if(tx_tog!=tx_seen)begin
                tx_seen=tx_tog;
                repeat(2)@(posedge clk);
                tx_done_tog=tx_tog;
                if(tx_type==16'h0040)begin
                    seq=tx_pkt[7:0];op=tx_pkt[15:8];value=tx_pkt[23:16];
                    if(hold_next_display)begin
                        hold_next_display=0;display_hold_active=1;
                        wait(release_display);display_hold_active=0;release_display=0;
                    end
                    emit_display_reply(16'h0041,seq,op,value);
                end else if(tx_type==16'h0046)begin
                    seq=tx_pkt[7:0];value=tx_pkt[15:8];
                    emit_display_reply(16'h0041,seq,8, value);
                end else if(tx_type==16'h0042)begin
                    seq=tx_pkt[7:0];emit_display_status(seq);
                end
            end
        end
    end

    task automatic check_bt_command(input [7:0] key);
        reg [7:0] p[0:7];
        begin
            send_pair_bt(key);receive_packet(1'b1,p);
            if(p[0]!==8'h5A || p[1]!==key)
                $fatal(1,"Bluetooth ACK mismatch for %02x: %02x %02x",key,p[0],p[1]);
            if(control_error!=0) $fatal(1,"control error %0d after Bluetooth command %02x",control_error,key);
        end
    endtask

    initial begin : test_main
        integer k,diag_wait;
        repeat(8)@(posedge clk);rst=0;

        // A corrupt pair is ignored, then a valid command is decoded from the
        // actual 9600 baud RX waveform and its ACK returns on the BT TX pin.
        send_uart_byte(1'b1,8'h41);send_uart_byte(1'b1,8'h00);
        repeat(300000)@(posedge clk);
        if(!bt_ready || bt_tx!==1'b1)$fatal(1,"bad pair generated an HC-08 response");
        check_bt_command(8'h41);
        if(!auto_on)$fatal(1,"Bluetooth 0x41 did not toggle auto-play");
        $display("BT test stage: local command");$fflush;

        // USB UART keeps its own reply route while HC-08 uses the same core.
        send_pair_usb(8'h3E);
        check_packet_key(1'b0,8'h3E);
        if(auto_period!=2)$fatal(1,"USB command changed auto period to %0d",auto_period);
        $display("BT test stage: USB route");$fflush;

        // All display-setting command keys traverse the 9600-baud input and
        // mocked display ACK path; core semantics stay shared with USB/ETH.
        command_table[0]=8'h2B;command_table[1]=8'h2D;
        command_table[2]=8'h5D;command_table[3]=8'h5B;
        command_table[4]=8'h2E;command_table[5]=8'h2C;
        command_table[6]=8'h30;command_table[7]=8'h31;command_table[8]=8'h32;
        command_table[9]=8'h33;command_table[10]=8'h34;command_table[11]=8'h35;
        command_table[12]=8'h51;command_table[13]=8'h27;command_table[14]=8'h3B;
        command_table[15]=8'h3E;command_table[16]=8'h3C;
        for(k=0;k<17;k=k+1)check_bt_command(command_table[k]);
        if(volume!=7 || brightness!=4 || contrast!=2 || effect!=2 || osd_mode!=2 ||
           !spectrum_on || spectrum_sensitivity!=1 || auto_period!=2)
            $fatal(1,"display settings did not retain the expected values");
        $display("BT test stage: display settings");$fflush;

        // Status request returns the display snapshot and then the command ACK.
        send_pair_bt(8'h53);
        receive_packet(1'b1,bt_packet0);
        if(bt_packet0[0]!==8'hA5)$fatal(1,"Bluetooth status packet header mismatch");
        check_packet_key(1'b1,8'h53);
        $display("BT test stage: status");$fflush;

        sd_diag_test=8'h09;sd_init_debug_test=16'hFCFF;
        send_pair_bt(8'h49);receive_packet(1'b1,bt_packet0);
        if(bt_packet0[0]!==8'hA6 || bt_packet0[1]!==8'h09 ||
           bt_packet0[2]!==8'h78 || bt_packet0[3]!==8'h56 ||
           bt_packet0[4]!==8'h34 || bt_packet0[5]!==8'h12 ||
           bt_packet0[6]!==8'hFF || bt_packet0[7]!==8'hFC)
            $fatal(1,"SD diagnostic query packet mismatch");
        wait(u_core.state==0);
        $display("BT test stage: serial SD diagnostic");$fflush;
        sd_diag_test=8'hFD;sd_init_debug_test=16'hD555;
        old_tx_tog=tx_tog;old_eth_ack=eth_cmd_ack;
        eth_cmd=8'h49;eth_cmd_pending=1;
        diag_wait=0;
        while(tx_tog==old_tx_tog && diag_wait<1000)begin @(posedge clk);diag_wait=diag_wait+1;end
        if(tx_tog==old_tx_tog)begin
            $display("I command stuck: core_state=%0d seen=%0b valid=%0b consume=%0b source=%0d",
                u_core.state,u_core.cmd_seen,u_core.event_valid,u_core.subtitle_consume,u_core.event_source);
            $fatal(1,"Ethernet SD diagnostic request was not emitted");
        end
        #1;
        if(tx_type!==16'h0047 || tx_payload_len!==8 || tx_pkt[7:0]!==8'hA6 ||
           tx_pkt[15:8]!==8'hFD || tx_pkt[63:48]!==16'hD555)
            $fatal(1,"Ethernet SD diagnostic response format mismatch");
        diag_wait=0;
        while(eth_cmd_ack==old_eth_ack && diag_wait<1000)begin @(posedge clk);diag_wait=diag_wait+1;end
        if(eth_cmd_ack==old_eth_ack)$fatal(1,"Ethernet SD diagnostic ACK was not returned");
        eth_cmd_pending=0;
        repeat(2)@(posedge clk);
        $display("BT test stage: Ethernet SD diagnostic");$fflush;

        // A6 uses a tagged field to report a stuck source/FAT state while the
        // SD host itself remains initialized and idle.
        wait(u_core.state==0);
        sd_diag_test=8'hF5;source_status_test=8'h25;source_busy_test=1;fat_state=8'h02;
        old_tx_tog=tx_tog;old_eth_ack=eth_cmd_ack;eth_cmd=8'h49;eth_cmd_pending=1;
        diag_wait=0;
        while(tx_tog==old_tx_tog && diag_wait<1000)begin @(posedge clk);diag_wait=diag_wait+1;end
        if(tx_tog==old_tx_tog)$fatal(1,"busy-source A6 diagnostic response was not emitted");
        #1;
        if(tx_pkt[15:8]!==8'hFD || tx_pkt[63:48]!==16'hF252 || tx_pkt[47:16]!==32'h12345678)
            $fatal(1,"busy-source A6 field mismatch flags=%02x field=%04x stream=%08x",
                tx_pkt[15:8],tx_pkt[63:48],tx_pkt[47:16]);
        diag_wait=0;
        while(eth_cmd_ack==old_eth_ack && diag_wait<1000)begin @(posedge clk);diag_wait=diag_wait+1;end
        if(eth_cmd_ack==old_eth_ack)$fatal(1,"busy-source A6 ACK was not returned");
        eth_cmd_pending=0;source_busy_test=0;repeat(2)@(posedge clk);
        $display("BT test stage: source/FAT diagnostic");$fflush;

        wait(u_core.state==0);
        sd_diag_test=8'hF5;source_busy_test=0;fat_state=8'h02;
        old_tx_tog=tx_tog;old_eth_ack=eth_cmd_ack;eth_cmd=8'h49;eth_cmd_pending=1;
        diag_wait=0;
        while(tx_tog==old_tx_tog && diag_wait<1000)begin @(posedge clk);diag_wait=diag_wait+1;end
        if(tx_tog==old_tx_tog)$fatal(1,"adapter-state A6 diagnostic response was not emitted");
        #1;
        if(tx_pkt[63:48]!==16'hE002 || tx_pkt[47:16]!==32'h12345678 || tx_pkt[15:8]!==8'hFD)
            $fatal(1,"adapter-state A6 field mismatch marker=%04x stream=%08x flags=%02x",
                tx_pkt[63:48],tx_pkt[47:16],tx_pkt[15:8]);
        diag_wait=0;
        while(eth_cmd_ack==old_eth_ack && diag_wait<1000)begin @(posedge clk);diag_wait=diag_wait+1;end
        if(eth_cmd_ack==old_eth_ack)$fatal(1,"adapter-state A6 ACK was not returned");
        eth_cmd_pending=0;repeat(2)@(posedge clk);
        $display("BT test stage: SD adapter state diagnostic");$fflush;

        wait(u_core.state==0);
        sd_diag_test=8'hF5;source_busy_test=1;fat_state=8'h09;
        sd_failure_lba_test=32'd1234;sd_failure_info_test=8'h38;
        old_tx_tog=tx_tog;old_eth_ack=eth_cmd_ack;eth_cmd=8'h49;eth_cmd_pending=1;
        diag_wait=0;
        while(tx_tog==old_tx_tog && diag_wait<1000)begin @(posedge clk);diag_wait=diag_wait+1;end
        if(tx_tog==old_tx_tog)$fatal(1,"failed-LBA A6 diagnostic response was not emitted");
        #1;
        if(tx_pkt[63:48]!==16'hD038 || tx_pkt[47:16]!==32'd1234 || tx_pkt[15:8]!==8'hFD)
            $fatal(1,"failed-LBA A6 field mismatch marker=%04x lba=%0d flags=%02x",
                tx_pkt[63:48],tx_pkt[47:16],tx_pkt[15:8]);
        diag_wait=0;
        while(eth_cmd_ack==old_eth_ack && diag_wait<1000)begin @(posedge clk);diag_wait=diag_wait+1;end
        if(eth_cmd_ack==old_eth_ack)$fatal(1,"failed-LBA A6 ACK was not returned");
        eth_cmd_pending=0;source_busy_test=0;
        $display("BT test stage: failed SD LBA diagnostic");$fflush;

        // Upload the maximum 160-character ASCII subtitle over the real UART
        // waveform, then verify successful commit ACK is routed back to BT.
        $display("BT test stage: begin maximum subtitle");$fflush;
        fork
            begin
                send_pair_bt(8'h54);$display("BT test stage: subtitle T received");$fflush;
                send_pair_bt(8'h20);
                for(k=0;k<160;k=k+1)send_pair_bt(8'hC1);
                send_pair_bt(8'h8A);send_pair_bt(8'h80);
                $display("BT test stage: subtitle bytes sent");$fflush;
            end
            begin wait(u_core.subtitle_active);$display("BT test stage: subtitle source locked");$fflush;send_pair_usb(8'h41);end
        join
        $display("BT test stage: subtitle inputs drained");$fflush;
        receive_packet(1'b1,bt_packet0);
        $display("BT test stage: subtitle ACK received");$fflush;
        if(bt_packet0[0]!==8'h5A || bt_packet0[1]!==8'h54 || !bt_packet0[7][7])
            $fatal(1,"160-character subtitle did not return successful BT ACK");
        if(u_core.subtitle_mem[0]!==8'h41 || u_core.subtitle_mem[159]!==8'h41 || u_core.subtitle_length!=160)
            $fatal(1,"maximum subtitle bytes not stored correctly");
        check_packet_key(1'b0,8'h41);
        $display("BT test stage: max subtitle and source lock");$fflush;

        // Clear subtitle uses the same source ownership and ACK route.
        send_pair_bt(8'h54);send_pair_bt(8'h80);send_pair_bt(8'h80);send_pair_bt(8'h80);
        receive_packet(1'b1,bt_packet0);
        if(bt_packet0[0]!==8'h5A || bt_packet0[1]!==8'h54 || !bt_packet0[7][7])
            $fatal(1,"subtitle clear ACK failed");
        if(u_core.subtitle_length!=0)$fatal(1,"subtitle clear length was not committed");
        $display("BT test stage: clear subtitle");$fflush;

        // Hold one display operation open while both serial sources queue
        // commands.  The queue must preserve each source and route ACKs back.
        hold_next_display=1;
        send_pair_bt(8'h5D);
        wait(display_hold_active);
        fork
            begin send_pair_usb(8'h41);send_pair_bt(8'h3E);end
            begin receive_packet(1'b1,bt_packet0);receive_packet(1'b1,bt_packet1);end
            begin receive_packet(1'b0,usb_packet);end
            begin
                wait(u_arb.usb_count==1 && u_arb.bt_count==1);
                release_display=1;
            end
        join
        $display("queued responses BT0=%02x/%02x BT1=%02x/%02x USB=%02x/%02x",
            bt_packet0[0],bt_packet0[1],bt_packet1[0],bt_packet1[1],usb_packet[0],usb_packet[1]);
        if(bt_packet0[0]!==8'h5A || bt_packet0[1]!==8'h5D ||
           bt_packet1[0]!==8'h5A || bt_packet1[1]!==8'h3E ||
           usb_packet[0]!==8'h5A || usb_packet[1]!==8'h41)
            $fatal(1,"queued UART ACKs crossed source routes");
        if(usb_overflow!=0 || bt_overflow!=0)
            $fatal(1,"UART queue overflowed during bounded concurrent requests");
        $display("BT test stage: concurrent routed ACKs");$fflush;

        $display("PASS: HC-08 9600 8N1 controls, settings, status, 160-char/clear subtitle, recovery and routing");
        $finish;
    end

    initial begin
        #2_000_000_000;
        $fatal(1,"Bluetooth control test watchdog: core=%0d",u_core.state);
    end
endmodule
