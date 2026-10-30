`timescale 1ns/1ps
module tb_media_sensor_query;
    reg clk = 0;
    always #5 clk = ~clk;
    reg rst = 1;
    reg [7:0] cmd = 0;
    reg cmd_pending = 0;
    reg [7:0] uart_cmd = 0;
    reg uart_cmd_valid = 0;
    reg [7:0] rx_data = 0;
    reg rx_valid = 0;
    reg tx_done_tog = 0;
    reg sensor_snapshot_ready = 0;
    reg [335:0] sensor_snapshot_data = 0;

    wire cmd_ack_t, uart_cmd_ready;
    wire [1:0] uart_source_lock;
    wire uart_tx_req, bt_tx_req;
    wire [63:0] uart_tx_pkt;
    wire image_next_pulse, image_prev_pulse;
    wire tx_tog;
    wire [15:0] tx_type, tx_payload_len;
    wire [63:0] tx_pkt;
    wire debug_request, pc_snapshot_request, auto_on;
    wire [3:0] auto_period_s, volume, brightness, contrast;
    wire [1:0] effect, osd_mode, spectrum_sensitivity;
    wire [2:0] cv_mode;
    wire spectrum_on;
    wire [7:0] last_control_error;
    wire sensor_snapshot_request;
    wire sensor_snapshot_release_toggle;

    media_control_core #(.CLK_HZ(1000), .VIEW_ENABLE(1)) dut (
        .clk(clk), .rst(rst), .cmd(cmd), .cmd_pending(cmd_pending), .cmd_ack_t(cmd_ack_t),
        .uart_cmd(uart_cmd), .uart_cmd_valid(uart_cmd_valid), .uart_cmd_source(2'd1),
        .uart_cmd_ready(uart_cmd_ready), .uart_source_lock(uart_source_lock),
        .sd_diag_flags(8'd0), .sd_init_debug_word(16'd0),
        .image_read_cycles(32'd0), .sd_read_cycles(32'd0),
        .image_source_status(8'd0), .image_source_busy(1'b0),
        .sd_last_failure_lba(32'd0), .sd_last_failure_info(8'd0), .sd_stream_debug(32'd0),
        .uart_tx_ready(1'b0), .bt_tx_ready(1'b0), .local_auto_toggle(1'b0),
        .uart_tx_req(uart_tx_req), .bt_tx_req(bt_tx_req), .uart_tx_pkt(uart_tx_pkt),
        .image_next_pulse(image_next_pulse), .image_prev_pulse(image_prev_pulse),
        .rx_data(rx_data), .rx_valid(rx_valid), .tx_done_tog(tx_done_tog),
        .tx_tog(tx_tog), .tx_type(tx_type), .tx_payload_len(tx_payload_len), .tx_pkt(tx_pkt),
        .first_bmp(6'd0), .committed_index(5'd0), .committed_valid(1'b0), .paired_wav(1'b0),
        .fat_state(8'd0), .fat_error(1'b0), .media_state(8'd0),
        .debug_request(debug_request), .pc_snapshot_request(pc_snapshot_request),
        .auto_on(auto_on), .auto_period_s(auto_period_s), .volume(volume),
        .brightness(brightness), .contrast(contrast), .effect(effect), .cv_mode(cv_mode),
        .osd_mode(osd_mode), .spectrum_on(spectrum_on),
        .spectrum_sensitivity(spectrum_sensitivity), .last_control_error(last_control_error),
        .view_busy(1'b0), .uart_cmd_was_busy(1'b0),
        .layout_request(), .requested_layout(), .image_touch_request(),
        .sensor_snapshot_request(sensor_snapshot_request),
        .sensor_snapshot_release_toggle(sensor_snapshot_release_toggle),
        .sensor_snapshot_ready(sensor_snapshot_ready), .sensor_snapshot_data(sensor_snapshot_data)
    );

    // Model the Ethernet TX completion toggle after each packet is drained.
    always @(posedge clk) begin
        if (rst) tx_done_tog <= 0;
        else if (tx_tog != tx_done_tog) tx_done_tog <= tx_tog;
    end

    integer byte_index, chunk;
    reg old_tx_tog;
    initial begin
        for (byte_index=0; byte_index<42; byte_index=byte_index+1)
            sensor_snapshot_data[byte_index*8 +: 8] = byte_index[7:0];
        repeat (4) @(negedge clk);
        rst = 0;
        @(negedge clk);
        cmd = 8'h5A;
        cmd_pending = 1;
        wait(sensor_snapshot_request);
        @(negedge clk);
        sensor_snapshot_ready = 1;
        @(negedge clk);
        sensor_snapshot_ready = 0;

        old_tx_tog = tx_tog;
        for (chunk=0; chunk<7; chunk=chunk+1) begin
            wait(tx_tog != old_tx_tog);
            #1;
            if (tx_type !== 16'h004D || tx_payload_len !== 16'd8)
                $fatal(1, "sensor chunk %0d type/length incorrect", chunk);
            if (tx_pkt[7:0] !== 8'd1 || tx_pkt[15:8] !== chunk[7:0])
                $fatal(1, "sensor chunk %0d sequence/index incorrect: %h", chunk, tx_pkt[15:0]);
            for (byte_index=0; byte_index<6; byte_index=byte_index+1)
                if (tx_pkt[16+byte_index*8 +: 8] !== sensor_snapshot_data[(chunk*6+byte_index)*8 +: 8])
                    $fatal(1, "sensor chunk %0d byte %0d mismatch got=%02x expected=%02x packet=%016x", chunk, byte_index,
                           tx_pkt[16+byte_index*8 +: 8],sensor_snapshot_data[(chunk*6+byte_index)*8 +: 8],tx_pkt);
            old_tx_tog = tx_tog;
        end
        wait(cmd_ack_t == 1'b1);
        if(sensor_snapshot_release_toggle!==1'b1)
            $fatal(1,"sensor snapshot release was not toggled");
        if (dut.state !== 0) $fatal(1, "sensor query did not return to IDLE");
        $display("PASS sensor query: Z request returns seven ordered 0x004D packets and ACKs after drain");
        $finish;
    end

    initial begin
        #100000;
        $fatal(1, "timeout: state=%0d tx_type=%04x", dut.state, tx_type);
    end
endmodule
