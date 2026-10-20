`timescale 1ns/1ps
module tb_media_packet_drain;
    reg clk=0; always #4 clk=~clk;
    reg rst=1,rx_valid=0;
    reg [7:0] rx_data=0;
    wire frame_end_valid,frame_end_ok;
    wire [3:0] frame_end_reason;
    wire [15:0] frame_end_id;
    wire stream_word_valid,stream_done;
    wire [31:0] stream_word_data;
    wire stream_word_ready;
    wire [8:0] stream_word_count;
    wire stream_is_audio;
    reg end_seen=0,end_ok=0;
    reg [15:0] end_id=0;
    reg [3:0] end_reason=0;

    media_protocol_rx #(.FRAME_WORDS(21'd2)) dut (
        .clk(clk),.rst(rst),.rx_data(rx_data),.rx_valid(rx_valid),
        .ready_request(),.frame_begin_valid(),.frame_id(),.image_index(),
        .image_flags(),.image_total_words(),.stream_start(),.stream_is_audio(stream_is_audio),
        .stream_word_count(stream_word_count),.stream_word_data(stream_word_data),
        .stream_word_valid(stream_word_valid),.stream_word_ready(1'b1),.stream_done(stream_done),
        .frame_end_valid(frame_end_valid),.frame_end_ok(frame_end_ok),
        .frame_end_reason(frame_end_reason),.frame_end_id(frame_end_id),
        .audio_begin_valid(),.audio_frame_id(),.audio_sample_count(),
        .audio_end_valid(),.audio_end_ok(),.audio_end_id(),.protocol_error_toggle()
    );

    always @(posedge clk) begin
        if(rst) end_seen<=0;
        else if(frame_end_valid) begin
            end_seen<=1;end_ok<=frame_end_ok;end_id<=frame_end_id;
            end_reason<=frame_end_reason;
        end
    end

    task automatic byte_in(input [7:0] b);
        begin @(negedge clk);rx_data=b;rx_valid=1;end
    endtask
    task automatic close_pkt;
        begin @(negedge clk);rx_data=0;rx_valid=0;end
    endtask
    task automatic header(input [7:0] typ,input [15:0] len);
        begin byte_in(8'haa);byte_in(8'hbb);byte_in(8'hcc);byte_in(8'hdd);
              byte_in(typ);byte_in(0);byte_in(len[7:0]);byte_in(len[15:8]);end
    endtask
    task automatic begin_frame(input [15:0] id);
        begin header(8'h21,8);byte_in(id[7:0]);byte_in(id[15:8]);byte_in(0);byte_in(0);
              byte_in(2);byte_in(0);byte_in(0);byte_in(0);close_pkt();end
    endtask
    task automatic data_word(input [15:0] id,input [15:0] seq,input [31:0] word);
        begin header(8'h22,8);byte_in(id[7:0]);byte_in(id[15:8]);
              byte_in(seq[7:0]);byte_in(seq[15:8]);
              byte_in(word[7:0]);byte_in(word[15:8]);byte_in(word[23:16]);byte_in(word[31:24]);
              close_pkt();end
    endtask
    task automatic end_frame(input [15:0] id);
        reg [31:0] sum;
        begin sum=32'h11223344+32'h55667788;
              header(8'h23,8);byte_in(id[7:0]);byte_in(id[15:8]);
              byte_in(sum[7:0]);byte_in(sum[15:8]);byte_in(sum[23:16]);byte_in(sum[31:24]);
              byte_in(0);byte_in(0);close_pkt();end
    endtask

    task automatic reset_rx;
        begin rst=1;rx_valid=0;repeat(3)@(negedge clk);rst=0;repeat(2)@(negedge clk);end
    endtask
    integer i;
    initial begin
        repeat(3)@(negedge clk);rst=0;
        // Without an inter-packet gap, DATA2 arrives while DATA1 is still
        // draining from the receiver's single packet RAM and is discarded.
        begin_frame(16'h1111);
        data_word(16'h1111,0,32'h11223344);
        data_word(16'h1111,1,32'h55667788);
        end_frame(16'h1111);
        wait(end_seen);
        if(end_ok || end_reason!=4'd3)
            $fatal(1,"burst without drain gap: ok=%0d reason=%0d",end_ok,end_reason);

        reset_rx();end_seen=0;
        // The sender's 8us guard is far longer than this one-word drain.
        begin_frame(16'h2222);
        data_word(16'h2222,0,32'h11223344);
        repeat(1000)@(negedge clk);
        data_word(16'h2222,1,32'h55667788);
        repeat(1000)@(negedge clk);
        end_frame(16'h2222);
        wait(end_seen);
        if(!end_ok || end_reason!=0 || end_id!=16'h2222)
            $fatal(1,"gapped packets rejected: ok=%0d reason=%0d id=%04x",end_ok,end_reason,end_id);
        $display("PASS: receiver drops overlapping packet; drain gap restores complete frame");
        $finish;
    end
    initial begin #200000;$fatal(1,"timeout");end
endmodule
