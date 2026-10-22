`timescale 1ns/1ps
module tb_display_frame_digest;
    reg mem_clk=0,app_clk=0,rst=1;
    always #5 mem_clk=~mem_clk;
    always #4 app_clk=~app_clk;
    reg ack=0,valid=0,audio=0,rx_valid=0;
    reg [31:0] data=0;
    reg [7:0] rx=0;
    reg app_begin=0,app_valid=0;
    reg [31:0] app_data=0;
    wire req,tx_valid;
    wire [7:0] tx;
    wire [15:0] length;
    display_frame_digest #(.WORDS(64),.FIRST_ADDR0(0),.BANK_WORDS(1024)) dut (
        .mem_clk(mem_clk),.app_clk(app_clk),.producer_clk(app_clk),.rst(rst),.video_ack(ack),
        .video_valid(valid),.video_audio(audio),.video_data(data),.video_bank(2'd1),
        .write_valid(valid && !audio),.write_addr(data[20:0]),.write_data(data),
        .image_begin(app_begin),.producer_start(app_begin),.source_words(21'd64),.raw_valid(app_valid),.padded_valid(app_valid),
        .raw_data(app_data),.padded_data(app_data),
        .rx_data(rx),.rx_valid(rx_valid),.tx_request(req),.tx_valid(tx_valid),
        .tx_data(tx),.tx_length(length),.tx_ready(1'b1),.tx_ack(req)
    );
    reg [575:0] packet=0;
    integer bytes=0,i;
    reg [31:0] expected_hash=0;
    always @(posedge app_clk) if(tx_valid) begin
        packet[8*bytes+:8]=tx;bytes=bytes+1;
    end
    task automatic byte_send(input [7:0] b);
        @(negedge app_clk);rx_valid=1;rx=b;
    endtask
    initial begin
        repeat(5)@(negedge mem_clk);rst=0;
        @(negedge mem_clk);ack=1;
        @(negedge mem_clk);ack=0;
        for(i=0;i<64;i=i+1)begin
            @(negedge mem_clk);valid=1;audio=0;data=i;
            expected_hash=((expected_hash<<5)+expected_hash)^i;
            if(i==17)begin
                @(negedge mem_clk);audio=1;data=32'hdeadbeef;
            end
        end
        @(negedge mem_clk);valid=0;
        @(negedge app_clk);app_begin=1;
        @(negedge app_clk);app_begin=0;
        for(i=0;i<64;i=i+1)begin @(negedge app_clk);app_valid=1;app_data=i;end
        @(negedge app_clk);app_valid=0;
        repeat(8)@(negedge app_clk);
        byte_send('haa);byte_send('hbb);byte_send('hcc);byte_send('hdd);
        byte_send(0);byte_send('h47);byte_send(0);byte_send(0);
        @(negedge app_clk);rx_valid=0;
        wait(bytes==72);@(negedge app_clk);
        if(length!=72 || packet[71*8+:8]!==expected_hash[31:24] ||
           packet[68*8+:32]!==expected_hash || packet[64*8+:32]!==32'd2016 ||
           packet[60*8+:32]!==32'd64 || packet[58*8+:8]!==8'hdc ||
           packet[52*8+:32]!==expected_hash || packet[48*8+:32]!==32'd2016 ||
           packet[44*8+:32]!==32'd64 || packet[42*8+:8]!==8'hdd ||
           packet[36*8+:32]!==expected_hash || packet[32*8+:32]!==32'd2016 ||
           packet[28*8+:32]!==32'd64 || packet[26*8+:8]!==8'hda ||
           packet[20*8+:32]!==expected_hash || packet[16*8+:32]!==32'd2016 ||
           packet[12*8+:32]!==32'd64 || packet[10*8+:8]!==8'hd9 || packet[11*8+:8]!==1)
            $fatal(1,"digest mismatch packet=%h hash=%08x",packet,expected_hash);
        $display("PASS: passive SDRAM video digest excludes audio and returns coherent count/sum/ordered hash");
        $finish;
    end
    initial begin #100000;$fatal(1,"digest timeout");end
endmodule
