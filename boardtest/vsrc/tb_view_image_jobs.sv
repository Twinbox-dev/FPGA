`timescale 1ns/1ps
// Production formal sender in external schedule mode; wire-level BEGIN, odd
// tail, staged/final replies, audio suppression and PC snapshot completion.
module tb_view_image_jobs;
    reg clk=0,rst=1;always #4 clk=~clk;
    reg launch=0,snapshot=0;
    reg [1:0] layout=0,window=0;
    reg [15:0] generation=0;
    wire ready,done,start,audio_start,request,valid,fifo_read,to_pc;
    wire [7:0] result,data,error;
    wire [15:0] length;
    wire [4:0] source_index;
    reg prepared=0,source_done=0,seen=0;
    reg [3:0] source_count=8;
    reg [31:0] source_data=0;
    integer prepare_delay=-1,starts=0,audio_packets=0,packet_pos=0;
    reg [7:0] packet[0:1023],response[0:22];
    reg response_active=0;
    integer response_pos=0,response_length=0;
    wire rv=response_active && response_pos!=11;
    wire [7:0] rd=response[response_pos];
    reg [7:0] wanted_result=3;
    wire [191:0] unused_list=0;
    media_image_tx #(.EXTERNAL_SCHEDULE(1),.CLK_HZ(1000)) dut(
        .clk(clk),.rst(rst),.mounted(1'b1),.source_busy(1'b0),.source_error(1'b0),
        .first_bmp(6'd1),.bmp_next(unused_list),.bmp_prev(unused_list),.image_width(12'd5),.image_height(12'd3),
        .cmd(8'd0),.cmd_pending(1'b0),.auto_next(1'b0),.auto_status(1'b0),.pc_snapshot_request(1'b0),
        .local_next(1'b0),.local_prev(1'b0),.prepared_toggle(prepared),.done_toggle(source_done),
        .source_has_wav_async(1'b1),.source_wav_index_async(5'd2),
        .audio_prepared_toggle(1'b0),.audio_done_toggle(1'b0),.audio_sample_count_async(32'd0),
        .audio_source_error_async(1'b0),.start_toggle(start),.source_index(source_index),
        .audio_start_toggle(audio_start),.audio_file_index(),.fifo_empty(source_count>=8),
        .fifo_data(source_data),.fifo_read(fifo_read),.rx_data(rd),.rx_valid(rv),
        .tx_request(request),.tx_valid(valid),.tx_data(data),.tx_length(length),.tx_ack(request),
        .busy(),.committed_index(),.committed_valid(),.committed_wav(),.error_code(error),.state_code(),.media_to_pc(to_pc),
        .job_start(launch),.job_snapshot(snapshot),.job_previous(1'b0),.job_index(5'd1),
        .job_layout(layout),.job_window(window),.job_generation(generation),.job_ready(ready),.job_done(done),.job_result(result));
    task automatic reply_header(input integer offset,input [7:0] kind,input integer len);
        begin response[offset]=8'haa;response[offset+1]=8'hbb;response[offset+2]=8'hcc;response[offset+3]=8'hdd;
            response[offset+4]=kind;response[offset+5]=0;response[offset+6]=len;response[offset+7]=0;end
    endtask
    task automatic result_reply(input integer offset,input [7:0] kind,input [7:0] code);
        begin reply_header(offset,kind,3);response[offset+8]=packet[8];response[offset+9]=packet[9];response[offset+10]=code;end
    endtask
    integer k;
    always @(posedge clk)begin
        if(start!=seen)begin seen<=start;starts<=starts+1;source_count<=0;prepare_delay<=4;end
        else if(prepare_delay>0)prepare_delay<=prepare_delay-1;
        else if(prepare_delay==0)begin prepared<=~prepared;prepare_delay<=-1;end
        if(fifo_read)begin
            source_data<=source_count==7 ? 32'h00001234 : (32'h89abcdef ^ source_count);
            source_count<=source_count+1'b1;if(source_count==7)source_done<=~source_done;
        end
        if(response_active)begin
            if(response_pos+1==response_length)begin response_active<=0;response_pos<=0;end
            else response_pos<=response_pos+1;
        end
        if(valid)begin packet[packet_pos]=data;packet_pos<=packet_pos+1;end
        else if(packet_pos!=0)begin
            if(response_active)$fatal(1,"test receiver overlap");
            if(packet[4]==8'h20)begin reply_header(0,8'h20,1);response[8]=1;response_length<=9;response_active<=1;end
            if(packet[4]==8'h21)begin
                if(packet_pos!=24 || packet[20]!=layout || packet[21]!=window ||
                   {packet[23],packet[22]}!=generation || packet[12]!=8 || packet[16]!=5 || packet[18]!=3 ||
                   packet[11][3] || to_pc!=snapshot)$fatal(1,"job BEGIN/route/flags mismatch");
            end
            if(packet[4]==8'h22)begin
                if(packet_pos!=44 || {packet[43],packet[42],packet[41],packet[40]}!=32'h00001234)
                    $fatal(1,"native odd tail mismatch");
            end
            if(packet[4]==8'h23)begin
                result_reply(0,8'h24,snapshot ? 0 : wanted_result);response_length<=11;response_active<=1;
            end
            if(packet[4]==8'h30 || packet[4]==8'h31 || packet[4]==8'h32)begin
                audio_packets<=audio_packets+1;
                if(!snapshot)$fatal(1,"multiview emitted WAV transaction");
            end
            if(packet[4]==8'h32)begin
                result_reply(0,8'h33,0);result_reply(12,8'h24,2);response_length<=23;response_active<=1;
            end
            response_pos<=0;packet_pos<=0;
        end
    end
    task automatic job(input integer mode,win,gen,code,input bit pc);
        integer n;
        begin
            wait(ready);@(negedge clk);layout=mode;window=win;generation=gen;wanted_result=code;snapshot=pc;launch=1;
            @(negedge clk);launch=0;n=0;
            while(!done && n<10000)begin @(negedge clk);n=n+1;end
            if(!done || result!=code || error!=0 || audio_start)$fatal(1,"job failed result=%0d error=%0d state=%0d",result,error,dut.state);
            @(negedge clk);
        end
    endtask
    initial begin
        repeat(8)@(negedge clk);rst=0;wait(ready);
        repeat(20)@(negedge clk);if(starts!=0)$fatal(1,"source read started before a scheduled job");
        job(2,0,7,3,0);job(2,3,7,2,0);job(0,0,0,2,1);
        if(starts!=3 || audio_packets!=2)$fatal(1,"source/audio transaction count");
        $display("PASS: explicit formal jobs, native BEGIN/odd tail, staged result, no multiview WAV and routed D");$finish;
    end
    initial begin #1000000;$fatal(1,"job watchdog");end
endmodule
