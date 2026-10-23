`timescale 1ns/1ps
module tb_media_frame_pad;
    localparam integer CW=16, CH=8, FW=(CW*CH)/2;
    reg clk=0; always #5 clk=~clk;
    reg rst=1,frame_begin=0,frame_end=0;
    reg [11:0] image_width=0,image_height=0;
    reg in_is_audio=0,in_start=0,in_done=0,in_valid=0;
    reg [8:0] in_count=0;
    reg [31:0] in_data=0;
    wire in_ready,out_start,out_is_audio,out_valid,out_done,frame_done;
    wire [8:0] out_count;
    wire [31:0] out_data;
    reg out_ready=1;

    media_frame_pad #(.FRAME_WIDTH(CW),.FRAME_HEIGHT(CH),.FRAME_WORDS(FW)) dut (
        .layout(2'd0),
        .clk(clk),.rst(rst),.frame_begin(frame_begin),
        .image_width(image_width),.image_height(image_height),.frame_end(frame_end),
        .in_is_audio(in_is_audio),.in_start(in_start),.in_count(in_count),
        .in_data(in_data),.in_valid(in_valid),.in_ready(in_ready),.in_done(in_done),
        .out_start(out_start),.out_is_audio(out_is_audio),.out_count(out_count),
        .out_data(out_data),.out_valid(out_valid),.out_ready(out_ready),
        .out_done(out_done),.frame_done(frame_done)
    );

    integer cfg_w=0,cfg_h=0,cfg_provided=0;
    integer source_words=0,source_sent=0,output_words=0,cycles=0;
    integer local_x,local_y,source_idx,expected_count;
    reg [15:0] expected_low,expected_high;
    reg [31:0] expected_word;
    reg image_complete=0;
    reg sticky_audio_case=0;

    function automatic [31:0] source_word(input integer wi);
        integer p0,p1;
        reg [15:0] lo,hi;
        begin
            p0=wi*2; p1=p0+1;
            lo=(p0<cfg_provided)?(p0+1):0;
            hi=(p1<cfg_provided)?(p1+1):0;
            source_word={hi,lo};
        end
    endfunction

    always @* begin
        in_valid = !rst && !in_is_audio && source_sent < source_words;
        in_data = source_word(source_sent);
    end

    always @(negedge clk) begin
        if (!rst) begin
            cycles = cycles + 1;
            out_ready = (cycles % 7) != 0;
        end else begin
            out_ready = 1;
        end
    end

    always @(posedge clk) begin
        if (rst) begin
            source_sent <= 0;
            output_words <= 0;
        end else begin
            if (in_valid && in_ready && !in_is_audio)
                source_sent <= source_sent + 1;
            if (out_valid && out_ready && !out_is_audio) begin
                if (output_words >= FW) $fatal(1,"too many padded output words");
                local_x=(output_words*2)%CW;
                local_y=(output_words*2)/CW;
                expected_low=0; expected_high=0;
                if (local_x >= (CW-cfg_w)/2 && local_x < (CW-cfg_w)/2+cfg_w &&
                    local_y >= (CH-cfg_h)-((CH-cfg_h)/2) &&
                    local_y < (CH-cfg_h)-((CH-cfg_h)/2)+cfg_h) begin
                    source_idx=(local_y-((CH-cfg_h)-((CH-cfg_h)/2)))*cfg_w+
                               (local_x-(CW-cfg_w)/2);
                    if(source_idx<cfg_provided) expected_low=source_idx+1;
                end
                if (local_x+1 >= (CW-cfg_w)/2 && local_x+1 < (CW-cfg_w)/2+cfg_w &&
                    local_y >= (CH-cfg_h)-((CH-cfg_h)/2) &&
                    local_y < (CH-cfg_h)-((CH-cfg_h)/2)+cfg_h) begin
                    source_idx=(local_y-((CH-cfg_h)-((CH-cfg_h)/2)))*cfg_w+
                               (local_x+1-(CW-cfg_w)/2);
                    if(source_idx<cfg_provided) expected_high=source_idx+1;
                end
                expected_word={expected_high,expected_low};
                if(out_data!==expected_word)
                    $fatal(1,"pad %0dx%0d word %0d got=%08x expected=%08x at %0d,%0d",
                           cfg_w,cfg_h,output_words,out_data,expected_word,local_x,local_y);
                output_words <= output_words+1;
            end
            if(frame_done) image_complete<=1;
        end
    end

    task automatic run_case(input integer w,input integer h,input integer provided);
        integer watchdog;
        begin
            cfg_w=w;cfg_h=h;cfg_provided=provided;
            source_words=(provided+1)/2;source_sent=0;output_words=0;
            image_complete=0;cycles=0;watchdog=0;
            @(negedge clk);image_width=w;image_height=h;in_is_audio=sticky_audio_case;frame_begin=1;
            @(negedge clk);frame_begin=0;
            if(sticky_audio_case) begin
                // After a WAV, the packet receiver retains its last DATA kind
                // until the first image DATA packet, even though BEGIN arrived.
                repeat(20)@(negedge clk);
                in_is_audio=0;
            end
            if(provided<w*h) begin
                wait(source_sent>=source_words);
                @(negedge clk);frame_end=1;
                @(negedge clk);frame_end=0;
            end
            while((output_words<FW || dut.frame_active) && watchdog<20000) begin
                @(negedge clk);watchdog=watchdog+1;
            end
            if(watchdog>=20000) $fatal(1,"pad timeout %0dx%0d sent=%0d out=%0d",w,h,source_sent,output_words);
            if(output_words!=FW) $fatal(1,"padded count %0d expected %0d",output_words,FW);
            $display("PASS: %0dx%0d source (%0d px provided) padded to %0d canvas words",w,h,provided,output_words);
            @(negedge clk);rst=1;repeat(3)@(negedge clk);rst=0;repeat(3)@(negedge clk);
        end
    endtask

    initial begin
        repeat(4)@(negedge clk);rst=0;
        run_case(16,8,16*8);
        run_case(5,3,15);
        sticky_audio_case=1;
        run_case(5,3,15);
        sticky_audio_case=0;
        run_case(1,1,1);
        run_case(7,4,9); // truncated transfer: missing source pixels must be black
        $display("PASS: variable-size frame padding, odd dimensions, and short-transfer black fill");
        $finish;
    end
    initial begin #1000000;$fatal(1,"timeout");end
endmodule
