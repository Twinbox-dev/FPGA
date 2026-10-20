`timescale 1ns/1ps

module tb_media_control_snapshot;
    reg clk=0; always #5 clk=~clk;
    reg rst=1;
    reg [7:0] cmd=0, uart_cmd=0, rx_data=0;
    reg cmd_pending=0, uart_cmd_valid=0, uart_tx_ready=1;
    reg local_auto_toggle=0, rx_valid=0, tx_done_tog=0;
    wire cmd_ack_t, uart_tx_req, tx_tog, debug_request, pc_snapshot_request;
    wire [63:0] uart_tx_pkt, tx_pkt;
    wire [15:0] tx_type,tx_payload_len;
    wire image_next_pulse,image_prev_pulse,auto_on;
    wire [3:0] auto_period_s,volume,brightness,contrast;
    wire [1:0] effect,osd_mode,spectrum_sensitivity;
    wire spectrum_on;
    wire [7:0] last_control_error;
    reg old_tx_tog;

    media_control_core #(.CLK_HZ(1000)) dut (
        .clk(clk),.rst(rst),.cmd(cmd),.cmd_pending(cmd_pending),.cmd_ack_t(cmd_ack_t),
        .uart_cmd(uart_cmd),.uart_cmd_valid(uart_cmd_valid),.uart_tx_ready(uart_tx_ready),
        .local_auto_toggle(local_auto_toggle),.uart_tx_req(uart_tx_req),.uart_tx_pkt(uart_tx_pkt),
        .image_next_pulse(image_next_pulse),.image_prev_pulse(image_prev_pulse),
        .rx_data(rx_data),.rx_valid(rx_valid),.tx_done_tog(tx_done_tog),
        .tx_tog(tx_tog),.tx_type(tx_type),.tx_payload_len(tx_payload_len),.tx_pkt(tx_pkt),
        .first_bmp(6'd0),.committed_index(5'd0),.committed_valid(1'b1),.paired_wav(1'b0),
        .fat_state(8'd0),.fat_error(1'b0),.media_state(4'd0),
        .debug_request(debug_request),.pc_snapshot_request(pc_snapshot_request),
        .auto_on(auto_on),.auto_period_s(auto_period_s),.volume(volume),
        .brightness(brightness),.contrast(contrast),.effect(effect),.osd_mode(osd_mode),
        .spectrum_on(spectrum_on),.spectrum_sensitivity(spectrum_sensitivity),
        .last_control_error(last_control_error)
    );

    initial begin
        repeat(4) @(negedge clk); rst=0;
        old_tx_tog=tx_tog;
        @(negedge clk); cmd=8'h44;cmd_pending=1;
        wait(pc_snapshot_request);
        if(debug_request) $fatal(1,"Ethernet D incorrectly launched UART raw probe");
        if(tx_type!=16'h0002) $fatal(1,"Ethernet D lost its V1 command ACK");
        wait(tx_tog!=old_tx_tog);
        @(negedge clk); tx_done_tog=tx_tog;cmd_pending=0;
        repeat(5) @(negedge clk);
        if(pc_snapshot_request) $fatal(1,"PC snapshot request was not a pulse");
        $display("PASS: Ethernet D requests formal PC snapshot and retains V1 ACK");
        $finish;
    end

    initial begin #100000; $fatal(1,"timeout"); end
endmodule
