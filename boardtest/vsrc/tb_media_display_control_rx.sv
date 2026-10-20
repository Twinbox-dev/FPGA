`timescale 1ns/1ps

module tb_media_display_control_rx;
    reg clk=0; always #5 clk=~clk;
    reg rst=1;
    reg [7:0] rx_data=0;
    reg rx_valid=0;
    wire set_toggle;
    wire [7:0] set_op,set_value;
    wire status_req_valid;
    wire [7:0] status_sequence;
    wire control_ack_valid;
    wire [7:0] control_ack_sequence,control_ack_op,control_ack_status,control_ack_value;
    wire subtitle_write_toggle;
    wire [7:0] subtitle_write_index,subtitle_write_char;
    wire subtitle_commit_toggle;
    wire [7:0] subtitle_commit_length,subtitle_commit_sequence;

    media_display_control_rx dut(.*);
    integer set_edges=0, ack_count=0, write_edges=0, status_count=0;
    reg commit_seen=0;
    reg set_toggle_prev=0, write_toggle_prev=0, commit_toggle_prev=0;
    reg set_value_good=0, set_value_bad=0, subtitle_ack_bad=0;
    reg [7:0] expected_char [0:2];
    initial begin expected_char[0]=8'h41; expected_char[1]=8'h42; expected_char[2]=8'h43; end

    always @(posedge clk) begin
        if (set_toggle != set_toggle_prev) begin
            set_toggle_prev <= set_toggle;
            set_edges <= set_edges + 1;
            if (set_op==8'd1 && set_value==8'd5) set_value_good<=1;
        end
        if (status_req_valid) begin
            if (status_sequence!=8'h44) $fatal(1,"status sequence");
            status_count <= status_count+1;
        end
        if (control_ack_valid) begin
            ack_count <= ack_count+1;
            if (control_ack_op==8'd1 && control_ack_status==0 &&
                control_ack_sequence==8'h12 && control_ack_value==8'd5) set_value_good<=1;
            if (control_ack_op==8'd3 && control_ack_status==1) set_value_bad<=1;
            if (control_ack_op==8'd8 && control_ack_status==1) subtitle_ack_bad<=1;
        end
        if (subtitle_write_toggle != write_toggle_prev) begin
            write_toggle_prev <= subtitle_write_toggle;
            if (write_edges < 3 &&
                (subtitle_write_index>2 || subtitle_write_char!=expected_char[subtitle_write_index[1:0]]))
                $fatal(1,"subtitle character mismatch");
            write_edges<=write_edges+1;
        end
        if (subtitle_commit_toggle != commit_toggle_prev) begin
            commit_toggle_prev <= subtitle_commit_toggle;
            if (subtitle_commit_length!=3 || subtitle_commit_sequence!=8'h55)
                $fatal(1,"subtitle commit metadata");
            commit_seen<=1;
        end
    end

    task automatic send_byte(input [7:0] b);
        begin @(negedge clk); rx_data=b; rx_valid=1; end
    endtask
    task automatic finish_packet;
        begin @(negedge clk); rx_valid=0; rx_data=0; repeat(5) @(negedge clk); end
    endtask
    task automatic header(input [7:0] kind,input [15:0] len);
        begin
            send_byte(8'haa);send_byte(8'hbb);send_byte(8'hcc);send_byte(8'hdd);
            send_byte(0);send_byte(kind);send_byte(len[15:8]);send_byte(len[7:0]);
        end
    endtask
    task automatic subtitle_data(input [7:0] seq,input [7:0] offset,input [7:0] ch);
        begin
            header(8'h45,16'd3);send_byte(seq);send_byte(offset);send_byte(ch);finish_packet();
        end
    endtask

    initial begin
        repeat(4) @(negedge clk); rst=0;
        header(8'h40,16'd4);send_byte(8'h12);send_byte(8'd1);send_byte(8'd5);send_byte(0);finish_packet();
        header(8'h40,16'd4);send_byte(8'h13);send_byte(8'd3);send_byte(8'd7);send_byte(0);finish_packet();
        header(8'h42,16'd1);send_byte(8'h44);finish_packet();
        header(8'h44,16'd3);send_byte(8'h55);send_byte(3);send_byte(8'h43);finish_packet();
        subtitle_data(8'h55,0,8'h41);
        subtitle_data(8'h55,1,8'h42);
        subtitle_data(8'h55,2,8'h43);
        header(8'h46,16'd3);send_byte(8'h55);send_byte(3);send_byte(8'h43);finish_packet();
        header(8'h44,16'd3);send_byte(8'h56);send_byte(1);send_byte(8'h21);finish_packet();
        subtitle_data(8'h56,0,8'h58);
        header(8'h46,16'd3);send_byte(8'h56);send_byte(1);send_byte(8'h00);finish_packet();
        repeat(5) @(negedge clk);
        if (!set_value_good || !set_value_bad || !commit_seen || !subtitle_ack_bad ||
            write_edges!=4 || status_count!=1 || set_edges!=1 || ack_count!=3)
            $fatal(1,"control RX totals set=%0d ack=%0d status=%0d writes=%0d",set_edges,ack_count,status_count,write_edges);
        $display("PASS: SET ranges, status request, subtitle ordering/XOR commit and rejection");
        $finish;
    end
    initial begin #200000; $fatal(1,"timeout"); end
endmodule
