`timescale 1ns/1ps
module tb_view_session_manager;
    reg clk=0,rst=1;always #4 clk=~clk;
    reg prep=0,status_req=0,local_step=0,begin_frame=0,wr_valid=0,drained=0;
    reg [63:0] request=0;
    reg [10:0] cx=0;reg [9:0] cy=0;
    reg [15:0] fid=1,gen=0;
    reg [1:0] fl=0,fw=0;
    reg [4:0] idx=1;
    reg [7:0] wr_result=0;
    reg sb=0,allow_drain=1;
    wire accept,owned,busy,tb,prep_valid,sv,res_valid,epoch,cb,abort_image;
    wire [1:0] tl,tw,layout,focus,cl;
    wire [3:0] mask,cm;
    wire [15:0] tg,ag,result_frame;
    wire [4:0] fi;
    wire [11:0] width,height;
    wire [63:0] reply;
    wire [127:0] view_status;
    wire [7:0] result;
    view_session_manager #(.CLK_HZ(1000)) dut(.clk(clk),.rst(rst),
        .prepare_valid(prep),.prepare_body(request),.status_request(status_req),
        .cursor_x(cx),.cursor_y(cy),.local_step(local_step),
        .frame_begin(begin_frame),.frame_id(fid),.frame_generation(gen),
        .frame_layout(fl),.frame_window(fw),.frame_index(idx),
        .frame_width(12'd571),.frame_height(12'd720),
        .writer_result_valid(wr_valid),.writer_result(wr_result),.single_display_buffer(sb),
        .cfg_drained_epoch(drained),.accepted_begin(accept),.image_owned(owned),.abort_image(abort_image),
        .target_buffer(tb),.target_layout(tl),.target_window(tw),.target_generation(tg),
        .busy(busy),.active_layout(layout),.active_mask(mask),.active_generation(ag),
        .focus_window(focus),.focus_index(fi),.focus_width(width),.focus_height(height),
        .prepare_reply_valid(prep_valid),.prepare_reply_body(reply),
        .view_status_valid(sv),.view_status_body(view_status),
        .image_result_valid(res_valid),.image_result(result),.image_result_frame(result_frame),
        .config_epoch(epoch),.config_buffer(cb),.config_layout(cl),.config_mask(cm));
    reg epoch_seen=0;
    integer delay_count=0;
    always @(posedge clk)begin
        if(epoch!=epoch_seen)begin epoch_seen<=epoch;delay_count<=15;end
        else if(delay_count>0 && allow_drain)begin
            delay_count<=delay_count-1;
            if(delay_count==1)drained<=epoch;
        end
    end
    integer seq=1;
    task automatic request_prepare(input integer action,input integer mode,input integer win,input integer generation);
        begin
            @(negedge clk);request={16'd0,16'(generation),8'(win),8'(mode),8'(action),8'(seq)};
            seq=seq+1;prep=1;@(negedge clk);prep=0;
        end
    endtask
    task automatic expect_reply(input integer code);
        integer n;
        begin
            n=0;while(!prep_valid && n<100)begin @(negedge clk);n=n+1;end
            if(!prep_valid || reply[15:8]!=code)$fatal(1,"prepare reply got=%h expected=%0d state=%0d",reply,code,dut.state);
            @(negedge clk);
        end
    endtask
    task automatic send_begin(input integer picture);
        begin
            @(negedge clk);fl=tl;fw=tw;gen=tg;idx=picture;fid=fid+1;begin_frame=1;
            #1;if(!accept)$fatal(1,"expected owned BEGIN");
            @(negedge clk);begin_frame=0;
        end
    endtask
    task automatic writer_reply(input integer code);
        begin
            @(negedge clk);wr_valid=1;wr_result=code;@(negedge clk);wr_valid=0;
        end
    endtask
    task automatic expect_result(input integer code);
        integer n;
        begin
            n=0;while(!res_valid && n<100)begin @(negedge clk);n=n+1;end
            if(!res_valid || result!=code || result_frame!=fid)
                $fatal(1,"result mismatch got=%0d expected=%0d frame=%0d/%0d state=%0d",result,code,result_frame,fid,dut.state);
            @(negedge clk);
        end
    endtask
    integer i;
    initial begin
        repeat(5)@(negedge clk);rst=0;
        request_prepare(0,0,255,0);expect_reply(0);send_begin(1);
        writer_reply(0);expect_result(0);sb=tb;writer_reply(2);expect_result(2);
        if(busy || layout!=0 || mask!=1)$fatal(1,"single commit");
        request_prepare(0,2,255,0);expect_reply(0);
        for(i=0;i<4;i=i+1)begin
            send_begin(i+2);writer_reply(0);expect_result(i==3 ? 2 : 3);
            if(i!=3 && layout!=0)$fatal(1,"partial page became visible");
        end
        if(busy || layout!=2 || mask!=15 || ag!=1)$fatal(1,"quad commit");
        request_prepare(0,1,255,1);expect_reply(2);
        request_prepare(1,2,255,0);expect_reply(3);
        cx=900;cy=550;repeat(3)@(negedge clk);allow_drain=0;
        request_prepare(1,2,255,1);
        repeat(20)begin @(negedge clk);if(prep_valid)$fatal(1,"in-place grant preceded drain");end
        cx=0;cy=0; // target must stay window 3, even while the hide is waiting
        if(mask!=7 || !busy)$fatal(1,"target not hidden");
        allow_drain=1;expect_reply(0);
        if(reply[23:16]!=3 || reply[55:48]!=5)$fatal(1,"target/base index moved with cursor: %h",reply);
        request_prepare(1,2,255,1);expect_reply(1);
        send_begin(9);writer_reply(8'h14);expect_result(8'h14);
        if(mask!=7 || !busy)$fatal(1,"failed update restored window");
        send_begin(9);writer_reply(0);expect_result(2);
        if(mask!=15 || busy || dut.indices[3]!=9 || dut.indices[0]!=2)$fatal(1,"isolated retry commit");
        // A local touch locks its focus before the relayed preparation arrives.
        cx=900;cy=0;local_step=1;@(negedge clk);local_step=0;cx=0;
        request_prepare(1,2,254,1);expect_reply(0);
        if(tw!=1)$fatal(1,"local touch target was not locked");
        send_begin(6);writer_reply(0);expect_result(2);
        cx=900;cy=550;repeat(3)@(negedge clk);
        request_prepare(0,0,255,1);expect_reply(0);
        if(reply[55:48]!=9)$fatal(1,"return single chose wrong image");
        send_begin(9);writer_reply(0);expect_result(0);sb=tb;writer_reply(2);expect_result(2);
        if(layout!=0 || ag!=2 || dut.indices[0]!=9)$fatal(1,"return single commit");
        request_prepare(4,0,255,2);expect_reply(0);
        request_prepare(1,0,255,2);expect_reply(1);
        request_prepare(5,0,255,2);expect_reply(0);
        if(busy)$fatal(1,"snapshot lock not released");
        $display("PASS: prepare/drain, atomic page, per-window retry, generation, local lock and snapshot arbitration");$finish;
    end
    initial begin #1000000;$fatal(1,"manager timeout");end
endmodule
