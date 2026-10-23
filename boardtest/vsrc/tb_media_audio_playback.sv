`timescale 1ns/1ps

module tb_media_audio_playback;
    reg clk=0; always #5 clk=~clk;
    reg rst=1,source_toggle=0,pair_on=0;
    reg [1:0] source_buffer=2;
    reg [20:0] source_length=256;
    reg [31:0] source_samples=4;
    wire read_req;
    wire [1:0] read_index;
    wire [20:0] read_length;
    wire read_en;
    reg [31:0] read_data=0;
    reg [9:0] read_fifo_words=512;
    wire audio_tick,audio_valid,audio_underrun;
    wire [23:0] audio_left,audio_right;
    integer rd_ptr=0,tick_index=0;
    reg [23:0] samples[0:3];

    media_audio_playback dut (
        .clk(clk),.rst(rst),.source_toggle(source_toggle),.pair_on(pair_on),
        .source_buffer(source_buffer),.source_length(source_length),.source_samples(source_samples),
        .read_req(read_req),.read_req_ack_async(read_req),.read_index(read_index),
        .read_length(read_length),.read_en(read_en),.read_data(read_data),
        .read_fifo_words(read_fifo_words),.audio_tick(audio_tick),.audio_valid(audio_valid),
        .audio_left(audio_left),.audio_right(audio_right),.audio_underrun(audio_underrun)
    );

    always @(posedge clk) begin
        if (read_en) begin
            read_data <= 32'h20ff0080;
            rd_ptr <= rd_ptr+1;
        end
        if (audio_tick) begin
            if (!audio_valid || audio_underrun) $fatal(1,"audio tick invalid/underrun");
            if (audio_left !== samples[tick_index/2] || audio_right !== samples[tick_index/2])
                $fatal(1,"sample %0d left=%h expected=%h",tick_index,audio_left,samples[tick_index/2]);
            tick_index<=tick_index+1;
            if (tick_index==7) begin
                if (read_index!=2 || read_length!=256 || rd_ptr==0) $fatal(1,"audio SDRAM read not started");
                $display("PASS: 8-bit unsigned PCM maps to signed 24-bit and duplicates at 48 kHz");
                $finish;
            end
        end
    end

    initial begin
        samples[0]=24'h000000;
        samples[1]=24'h000000;
        samples[2]=24'h000000;
        samples[3]=24'h000000;
        // Four bytes in the packed SDRAM word are 0x80, 0x00, 0xff, 0x20.
        samples[0]=24'h000000;
        samples[1]=24'h800000;
        samples[2]=24'h7f0000;
        samples[3]=24'ha00000;
        repeat(5) @(negedge clk);rst=0;
        @(negedge clk);source_toggle=1;
        repeat(100)@(negedge clk);
        if(read_req || rd_ptr!=0)$fatal(1,"muted source read before layout commit");
        pair_on=1;
        #1000000;$fatal(1,"timeout");
    end
endmodule
