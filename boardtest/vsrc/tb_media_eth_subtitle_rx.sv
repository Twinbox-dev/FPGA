`timescale 1ns/1ps
module tb_media_eth_subtitle_rx;
    reg clk=0;
    always #5 clk=~clk;
    reg rst=1;
    reg [7:0] rx_data=0;
    reg rx_valid=0;
    reg [15:0] rx_len=16'd10;
    wire [7:0] cmd;
    wire cmd_pending,cmd_ack_t,tx_tog,tx_done_tog;
    wire [15:0] tx_type,tx_payload_len;
    wire [63:0] tx_pkt;
    wire app_tx_data_request,app_tx_data_valid;
    wire [7:0] app_tx_data;
    wire [15:0] udp_data_length;

    eth_front u_eth_front (
        .app_rx_clk(clk),.app_tx_clk(clk),.reset(rst),.sys_rst(rst),
        .app_rx_data(rx_data),.app_rx_data_valid(rx_valid),.app_rx_data_length(rx_len),
        .udp_tx_ready(1'b0),.app_tx_ack(1'b0),.app_tx_data(app_tx_data),
        .app_tx_data_request(app_tx_data_request),.app_tx_data_valid(app_tx_data_valid),
        .udp_data_length(udp_data_length),.cmd(cmd),.cmd_pending(cmd_pending),
        .cmd_ack_t(cmd_ack_t),.tx_tog(tx_tog),.tx_type(tx_type),
        .tx_payload_len(tx_payload_len),.tx_pkt(tx_pkt),.tx_done_tog(tx_done_tog),
        .tap_clk(clk),.tap_val(1'b0),.tap_word(32'd0),.tap_end(1'b0),
        .tap2_clk(clk),.tap2_val(1'b0),.tap2_word(32'd0),.tap2_end(1'b0)
    );
    media_control_core #(.CLK_HZ(1000)) u_control (
        .clk(clk),.rst(rst),.cmd(cmd),.cmd_pending(cmd_pending),.cmd_ack_t(cmd_ack_t),
        .uart_cmd(8'd0),.uart_cmd_valid(1'b0),.uart_cmd_source(2'd1),.uart_cmd_ready(),.uart_source_lock(),
        .sd_diag_flags(8'd0),.sd_init_debug_word(16'd0),.image_read_cycles(32'd0),.sd_read_cycles(32'd0),
        .image_source_status(8'd0),.image_source_busy(1'b0),
        .sd_last_failure_lba(32'd0),.sd_last_failure_info(8'd0),
        .sd_stream_debug(32'd0),
        .uart_tx_ready(1'b1),.bt_tx_ready(1'b0),.uart_tx_req(),.bt_tx_req(),.uart_tx_pkt(),
        .local_auto_toggle(1'b0),
        .image_next_pulse(),.image_prev_pulse(),.rx_data(8'd0),.rx_valid(1'b0),
        .tx_done_tog(tx_done_tog),.tx_tog(tx_tog),.tx_type(tx_type),
        .tx_payload_len(tx_payload_len),.tx_pkt(tx_pkt),
        .first_bmp(6'd0),.committed_index(5'd0),.committed_valid(1'b1),.paired_wav(1'b0),
        .fat_state(8'd0),.fat_error(1'b0),.media_state(4'd0),
        .debug_request(),.pc_snapshot_request(),.auto_on(),.auto_period_s(),
        .volume(),.brightness(),.contrast(),.effect(),.osd_mode(),.spectrum_on(),
        .spectrum_sensitivity(),.last_control_error()
    );

    function automatic [7:0] datagram_byte(input integer index,input [7:0] value);
        begin
            case(index)
                0:datagram_byte=8'haa; 1:datagram_byte=8'hbb;
                2:datagram_byte=8'hcc; 3:datagram_byte=8'hdd;
                4:datagram_byte=8'h00; 5:datagram_byte=8'h01;
                6:datagram_byte=8'h00; 7:datagram_byte=8'h02;
                8:datagram_byte=value; 9:datagram_byte=~value;
                default:datagram_byte=8'h00;
            endcase
        end
    endfunction
    task automatic send_pc_command_byte(input [7:0] value);
        integer i;
        begin
            for(i=0;i<10;i=i+1)begin
                @(negedge clk);rx_data=datagram_byte(i,value);rx_valid=1;
                @(posedge clk);
            end
            @(negedge clk);rx_data=0;rx_valid=0;
            repeat(12)@(negedge clk);
        end
    endtask

    initial begin
        repeat(3)@(negedge clk);rst=0;
        // PC EthTransport format, one UDP packet per verified byte.
        send_pc_command_byte(8'h54);
        send_pc_command_byte(8'h81);
        send_pc_command_byte(8'hc1);
        send_pc_command_byte(8'h84);
        send_pc_command_byte(8'h80);
        repeat(20)@(negedge clk);
        if(tx_type!==16'h0044 || tx_payload_len!==16'd3 ||
           tx_pkt[7:0]!==8'd0 || tx_pkt[15:8]!==8'd1 || tx_pkt[23:16]!==8'h40)
            $fatal(1,"eth_front -> media_control_core subtitle mismatch: type=%04x len=%0d pkt=%016x",
                   tx_type,tx_payload_len,tx_pkt);
        if(u_control.subtitle_mem[0]!==8'h41)
            $fatal(1,"eth_front command handshake lost ASCII byte; mem[0]=%02x",u_control.subtitle_mem[0]);
        $display("PASS: actual UDP command framing and eth_front handshake preserve a valid subtitle stream");
        $finish;
    end
    initial begin
        #100000;
        $fatal(1,"timeout waiting for media subtitle BEGIN packet");
    end
endmodule
