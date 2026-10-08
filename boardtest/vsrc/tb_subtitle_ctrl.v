`timescale 1ns/1ps
module tb_subtitle_ctrl;
    reg clk=0;
    always #5 clk=~clk;
    reg rst=1, cmd_val=0;
    reg [7:0] cmd=0;
    wire consume, wr_en, commit_toggle, ack_pulse, ack_ok;
    wire [7:0] wr_index, wr_char, commit_len;
    wire vk_next_n, vk_prev_n, vk_auto_n, tx_req;
    wire [63:0] tx_pkt;
    wire [3:0] vol_gain;
    wire [1:0] effect, osd_mode;
    integer tx_count=0;
    reg [63:0] last_pkt=0;
    subtitle_cmd #(.TIMEOUT_CYCLES(1000)) uploader (
        .clk(clk), .rst(rst), .cmd(cmd), .cmd_val(cmd_val),
        .swap_ack_toggle_raw(1'b0), .consume_cmd(consume),
        .wr_en(wr_en), .wr_index(wr_index), .wr_char(wr_char),
        .commit_toggle(commit_toggle), .commit_len(commit_len),
        .ack_pulse(ack_pulse), .ack_ok(ack_ok)
    );
    ctrl_core #(.VK_PULSE_CYC(50)) ctrl (
        .clk(clk), .rst(rst), .cmd(cmd), .cmd_val(cmd_val),
        .subtitle_consume(consume), .subtitle_ack_pulse(ack_pulse),
        .subtitle_ack_ok(ack_ok), .vk_next_n(vk_next_n),
        .vk_auto_n(vk_auto_n), .vk_prev_n(vk_prev_n),
        .tx_req(tx_req), .tx_pkt(tx_pkt), .vol_gain(vol_gain),
        .transition_mode(effect), .osd_mode(osd_mode),
        .auto_period_s(), .vol_gray(), .bri_gray(), .ct_gray(),
        .bar_en(), .bar_sens_gray(),
        .pl_dump_start(), .rdump_start(),
        .pl_pkt(64'd0), .pl_pkt_val(1'b0), .ld_diag(8'd0),
        .state_code(4'd0), .dbg_fat_state(8'd0),
        .flag_a(4'd0), .flag_b(4'd0), .dbg_underrun(4'd0),
        .img_idx(5'd0), .img_wav(1'b0), .auto_on(1'b0)
    );
    always @(posedge clk)
        if (tx_req) begin
            tx_count <= tx_count+1;
            last_pkt <= tx_pkt;
        end
    task send_byte(input [7:0] value);
        begin
            @(negedge clk); cmd=value; cmd_val=1;
            @(negedge clk); cmd_val=0;
            @(negedge clk);
        end
    endtask
    initial begin
        repeat (3) @(negedge clk); rst=0;
        // Decoded text contains normal controls N, 0, P; encoded bytes do not.
        send_byte(8'h54); send_byte(8'h83);
        send_byte(8'hce); send_byte(8'hb0); send_byte(8'hd0);
        send_byte(8'h82); send_byte(8'h8d); // checksum 0x2d
        repeat (4) @(negedge clk);
        if (!commit_toggle || commit_len!==8'd3)
            $fatal(1,"upload did not commit");
        if (!vk_next_n || !vk_prev_n || !vk_auto_n ||
            effect!==2'd0 || osd_mode!==2'd1 || vol_gain!==4'd8)
            $fatal(1,"subtitle payload escaped into normal controls");
        if (tx_count!==1 || last_pkt[15:0]!==16'h545a || !last_pkt[63])
            $fatal(1,"subtitle final ACK wrong count=%0d pkt=%h",tx_count,last_pkt);
        $display("PASS subtitle/controller integration: reserved control bytes and one T ACK");
        $finish;
    end
endmodule
