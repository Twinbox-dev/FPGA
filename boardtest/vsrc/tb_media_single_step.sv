`timescale 1ns/1ps
module tb_media_single_step;
    reg clk=0; always #4 clk=~clk;
    reg rst=1;
    reg [7:0] cmd=0;
    reg cmd_pending=0;
    wire cmd_ack_t,uart_tx_req,image_next_pulse,image_prev_pulse,tx_tog;
    wire [63:0] uart_tx_pkt,tx_pkt;
    wire [15:0] tx_type,tx_payload_len;
    reg tx_done_tog=0;
    wire [3:0] volume,brightness,contrast;
    wire [1:0] effect,osd_mode,spectrum_sensitivity;
    wire spectrum_on,debug_request,pc_snapshot_request,auto_on;
    wire [3:0] auto_period_s;
    wire [7:0] last_control_error;

    always @(posedge clk) begin
        if(rst) tx_done_tog<=0;
        else tx_done_tog<=tx_tog;
    end

    media_control_core #(.CLK_HZ(1000)) u_control (
        .clk(clk),.rst(rst),.cmd(cmd),.cmd_pending(cmd_pending),.cmd_ack_t(cmd_ack_t),
        .uart_cmd(8'd0),.uart_cmd_valid(1'b0),.uart_tx_ready(1'b1),.uart_tx_req(uart_tx_req),
        .uart_tx_pkt(uart_tx_pkt),.local_auto_toggle(1'b0),
        .image_next_pulse(image_next_pulse),.image_prev_pulse(image_prev_pulse),
        .rx_data(8'd0),.rx_valid(1'b0),.tx_done_tog(tx_done_tog),.tx_tog(tx_tog),
        .tx_type(tx_type),.tx_payload_len(tx_payload_len),.tx_pkt(tx_pkt),
        .first_bmp(6'd1),.committed_index(5'd1),.committed_valid(1'b1),.paired_wav(1'b0),
        .fat_state(8'd0),.fat_error(1'b0),.media_state(4'd0),
        .debug_request(debug_request),.pc_snapshot_request(pc_snapshot_request),
        .auto_on(auto_on),.auto_period_s(auto_period_s),.volume(volume),
        .brightness(brightness),.contrast(contrast),.effect(effect),.osd_mode(osd_mode),
        .spectrum_on(spectrum_on),.spectrum_sensitivity(spectrum_sensitivity),
        .last_control_error(last_control_error)
    );

    wire start_toggle,audio_start_toggle,fifo_read,tx_request,tx_valid,busy;
    wire committed_valid,committed_wav,media_to_pc;
    wire [4:0] source_index,audio_file_index,committed_index;
    wire [7:0] tx_data,error_code;
    wire [15:0] tx_length;
    wire [3:0] state_code;
    media_image_tx #(.CLK_HZ(1000),.FRAME_WORDS(2)) u_tx (
        .clk(clk),.rst(rst),.mounted(1'b1),.source_busy(1'b0),.source_error(1'b0),
        .first_bmp(6'd1),.bmp_next(192'd0),.bmp_prev(192'd0),
        // N/P use only the control-core pulse path; raw commands are disabled.
        .cmd(8'd0),.cmd_pending(1'b0),.auto_next(1'b0),.auto_status(1'b0),
        .pc_snapshot_request(1'b0),.local_next(image_next_pulse),.local_prev(image_prev_pulse),
        .prepared_toggle(1'b0),.done_toggle(1'b0),.source_has_wav_async(1'b0),
        .source_wav_index_async(5'd0),.audio_prepared_toggle(1'b0),
        .audio_done_toggle(1'b0),.audio_sample_count_async(32'd0),
        .audio_source_error_async(1'b0),.start_toggle(start_toggle),.source_index(source_index),
        .audio_start_toggle(audio_start_toggle),.audio_file_index(audio_file_index),
        .fifo_empty(1'b1),.fifo_data(32'd0),.fifo_read(fifo_read),
        .rx_data(8'd0),.rx_valid(1'b0),.tx_request(tx_request),.tx_valid(tx_valid),
        .tx_data(tx_data),.tx_length(tx_length),.tx_ack(1'b0),.busy(busy),
        .committed_index(committed_index),.committed_valid(committed_valid),
        .committed_wav(committed_wav),.error_code(error_code),.state_code(state_code),
        .media_to_pc(media_to_pc)
    );

    integer starts=0;
    reg start_seen=0;
    always @(posedge clk) begin
        if(rst) begin starts<=0;start_seen<=0;end
        else if(start_toggle!=start_seen) begin
            start_seen<=start_toggle;
            starts<=starts+1;
        end
    end

    initial begin
        repeat(3) @(negedge clk);
        rst=0;
        // Model the normal post-READY idle point after a frame is committed.
        u_tx.state=4'd9;
        u_tx.receiver_ready=1'b1;
        u_tx.committed_valid=1'b1;
        u_tx.committed_index=5'd1;
        @(negedge clk);cmd=8'h4e;cmd_pending=1;
        @(negedge clk);cmd_pending=0;cmd=0;
        repeat(12) @(negedge clk);
        if(starts!=1 || state_code!=4'd1 || u_tx.pending_next)
            $fatal(1,"one PC N must start exactly one image load: starts=%0d state=%0d pending=%0d",
                   starts,state_code,u_tx.pending_next);
        $display("PASS: one PC N pulse starts one image load and leaves no queued duplicate");
        $finish;
    end
    initial begin #10000;$fatal(1,"timeout");end
endmodule
