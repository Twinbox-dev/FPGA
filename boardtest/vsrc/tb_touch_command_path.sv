`timescale 1ns/1ps

module tb_touch_command_path;
    reg clk=0;
    always #5 clk=~clk;
    reg rst=1;
    reg local_cmd_toggle=0;
    reg [7:0] local_cmd=0;
    reg cmd_ack_toggle=0;

    wire tx_request, tx_valid;
    wire [7:0] tx_data;
    wire [15:0] tx_length;
    wire [7:0] received_cmd;
    wire received_pending;

    media_display_tx #(.TX_GAP_CYCLES(2)) display_tx (
        .view_busy(1'b0),.view_prepare_valid(1'b0),.view_prepare_body(64'd0),.view_status_valid(1'b0),.view_status_body(128'd0),
        .clk(clk), .rst(rst),
        .local_cmd_toggle_async(local_cmd_toggle), .local_cmd_async(local_cmd),
        .ready_valid(1'b0), .image_result_valid(1'b0),
        .image_result_code(8'd0), .image_result_frame(16'd0),
        .audio_result_valid(1'b0), .audio_result_code(8'd0),
        .audio_result_frame(16'd0), .control_ack_valid(1'b0),
        .control_ack_sequence(8'd0), .control_ack_op(8'd0),
        .control_ack_status(8'd0), .control_ack_value(8'd0),
        .status_valid(1'b0), .status_payload(64'd0),
        .tx_request(tx_request), .tx_valid(tx_valid), .tx_data(tx_data),
        .tx_length(tx_length), .tx_ready(1'b1), .tx_ack(tx_request)
    );

    // Send the exact display TX bytes into the media board's production parser.
    eth_front media_rx (
        .app_rx_clk(clk), .app_tx_clk(clk), .reset(rst), .sys_rst(rst),
        .app_rx_data(tx_data), .app_rx_data_valid(tx_valid),
        .app_rx_data_length(tx_length),
        .udp_tx_ready(1'b0), .app_tx_ack(1'b0),
        .app_tx_data(), .app_tx_data_request(), .app_tx_data_valid(),
        .udp_data_length(), .cmd(received_cmd),
        .cmd_pending(received_pending), .cmd_ack_t(cmd_ack_toggle),
        .tx_tog(1'b0), .tx_type(16'd0), .tx_payload_len(16'd0),
        .tx_pkt(64'd0), .tx_done_tog(),
        .tap_clk(clk), .tap_val(1'b0), .tap_word(32'd0), .tap_end(1'b0),
        .tap2_clk(clk), .tap2_val(1'b0), .tap2_word(32'd0), .tap2_end(1'b0)
    );

    task automatic send_and_check(input [7:0] value);
        integer timeout;
        begin
            @(negedge clk);
            local_cmd = value;
            local_cmd_toggle = ~local_cmd_toggle;
            timeout=0;
            while (!received_pending && timeout < 100) begin
                @(negedge clk); timeout=timeout+1;
            end
            if (!received_pending)
                $fatal(1,"media eth_front did not accept touch command %h",value);
            if (received_cmd !== value)
                $fatal(1,"touch command mismatch: got %h expected %h",received_cmd,value);
            @(negedge clk); cmd_ack_toggle = ~cmd_ack_toggle;
            repeat (6) @(negedge clk);
            if (received_pending)
                $fatal(1,"media command pending did not clear after ACK");
        end
    endtask

    initial begin
        repeat (4) @(negedge clk);
        rst=0;
        send_and_check(8'h4e);
        send_and_check(8'h50);
        $display("PASS: GT911 next/previous packets are accepted by media eth_front");
        $finish;
    end

    initial begin
        #100000;
        $fatal(1,"timeout");
    end
endmodule
