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
    reg [1:0] effect_mode=0;
    reg view_vs=0;
    reg sb=0,allow_drain=1;
    wire accept,owned,busy,tb,prep_valid,sv,res_valid,epoch,cb,abort_image;
    wire [15:0] owned_frame_id;
    wire [1:0] tl,tw,layout,focus,cl;
    wire [3:0] mask,cm;
    wire [15:0] tg,ag,result_frame;
    wire [4:0] fi;
    wire [11:0] width,height;
    wire [63:0] reply;
    wire [127:0] view_status;
    wire [7:0] result;
    wire [3:0] cfg_window_buffers;
    wire trans_start,trans_release,trans_active,trans_prev;
    wire [1:0] trans_mode;
    wire transition_done;
    wire transition_line_req;
    wire [9:0] transition_line_num,transition_row_words,transition_line_addr;
    wire [20:0] transition_line_base;
    wire transition_line_bank,transition_row_ready,transition_effect_active;
    wire [1:0] transition_active_mode,transition_view_layout,transition_view_window;
    wire transition_direction;
    wire [8:0] transition_alpha;
    wire [10:0] transition_wipe;
    wire transition_view_active;
    view_session_manager #(.CLK_HZ(1000)) dut(.clk(clk),.rst(rst),
        .prepare_valid(prep),.prepare_body(request),.status_request(status_req),
        .cursor_x(cx),.cursor_y(cy),.local_step(local_step),
        .frame_begin(begin_frame),.frame_id(fid),.frame_generation(gen),
        .frame_layout(fl),.frame_window(fw),.frame_index(idx),
        .frame_width(12'd571),.frame_height(12'd720),
        .writer_result_valid(wr_valid),.writer_result(wr_result),
        .transition_mode_cfg(effect_mode),.transition_done_toggle(transition_done),.single_display_buffer(sb),
        .cfg_drained_epoch(drained),.accepted_begin(accept),.image_owned(owned),
        .owned_frame_id(owned_frame_id),.abort_image(abort_image),
        .target_buffer(tb),.target_layout(tl),.target_window(tw),.target_generation(tg),
        .busy(busy),.active_layout(layout),.active_mask(mask),.active_generation(ag),
        .focus_window(focus),.focus_index(fi),.focus_width(width),.focus_height(height),
        .prepare_reply_valid(prep_valid),.prepare_reply_body(reply),
        .view_status_valid(sv),.view_status_body(view_status),
        .image_result_valid(res_valid),.image_result(result),.image_result_frame(result_frame),
        .config_epoch(epoch),.config_buffer(cb),.config_layout(cl),.config_mask(cm),
        .config_window_buffers(cfg_window_buffers),.view_transition_start_toggle(trans_start),
        .view_transition_mode(trans_mode),.view_transition_direction_prev(trans_prev),
        .view_transition_release_toggle(trans_release),.view_transition_active(trans_active));
    transition_ctrl #(.BUF0_ADDR(21'd0),.BUF1_ADDR(21'd460800)) transition(.video_clk(clk),.rst(rst),
        .start_toggle_raw(trans_start),.target_buf_raw(tb),.mode_raw(trans_mode),
        .direction_prev_raw(trans_prev),.view_transition_raw(trans_active),
        .view_layout_raw(tl),.view_window_raw(tw),.release_toggle_raw(trans_release),
        .done_toggle(transition_done),.de_word(1'b0),.vs_word(view_vs),
        .line_req_toggle(transition_line_req),.line_num(transition_line_num),
        .line_base(transition_line_base),.row_words(transition_row_words),
        .line_ready_toggle_raw(transition_line_req),.line_rd_bank(transition_line_bank),
        .line_rd_addr(transition_line_addr),.row_ready(transition_row_ready),
        .effect_active(transition_effect_active),.active_mode(transition_active_mode),
        .direction_prev(transition_direction),.fade_alpha(transition_alpha),
        .wipe_progress(transition_wipe),.view_active(transition_view_active),
        .active_view_layout(transition_view_layout),.active_view_window(transition_view_window));
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
    task automatic pulse_view_vs;
        begin
            @(negedge clk);view_vs=1;@(negedge clk);view_vs=0;
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
        expect_reply(0);
        cx=0;cy=0; // target must stay window 3 after focus moves
        if(mask!=15 || !busy || tb==cb)$fatal(1,"old window was hidden or target page not inactive");
        if(reply[23:16]!=3 || reply[55:48]!=5)$fatal(1,"target/base index moved with cursor: %h",reply);
        send_begin(9);writer_reply(8'h14);expect_result(8'h14);
        if(mask!=15 || !busy || dut.indices[3]!=5)$fatal(1,"failed update changed visible window");
        allow_drain=1;
        send_begin(9);writer_reply(0);expect_result(2);
        if(mask!=15 || busy || dut.indices[3]!=9 || dut.indices[0]!=2 || cfg_window_buffers[3]!=1)
            $fatal(1,"inactive-bank retry commit");
        // A local touch locks its focus before the relayed preparation arrives.
        effect_mode=1;
        cx=900;cy=0;local_step=1;@(negedge clk);local_step=0;cx=0;
        request_prepare(1,2,254,1);expect_reply(0);
        if(tw!=1)$fatal(1,"local touch target was not locked");
        send_begin(6);writer_reply(0);
        if(!trans_active || mask!=15 || dut.indices[1]!=3 || !busy)
            $fatal(1,"transition staging hid/replaced the focused window early");
        repeat(8)@(negedge clk);
        if(!transition_view_active || transition_active_mode!=1 ||
           transition_view_layout!=2 || transition_view_window!=1 ||
           transition_row_words!=320 || transition_line_base!=21'd115200)
            $fatal(1,"transition controller did not target staged quad window");
        for(i=0;i<68;i=i+1)pulse_view_vs();
        expect_result(2);
        repeat(8)@(negedge clk); // allow the release toggle to cross into video_clk
        if(trans_active || transition_effect_active || dut.indices[1]!=6 || cfg_window_buffers!=4'b1010)
            $fatal(1,"per-window transition commit/release failed active=%b effect=%b index=%0d selectors=%b state=%0d done=%b epoch=%b drained=%b",
                   trans_active,transition_effect_active,dut.indices[1],cfg_window_buffers,dut.state,
                   transition_done,epoch,drained);
        effect_mode=2;
        cx=900;cy=0;repeat(3)@(negedge clk);
        request_prepare(1,2,254,1);expect_reply(0);
        send_begin(7);writer_reply(0);
        repeat(8)@(negedge clk);
        if(!transition_view_active || transition_active_mode!=2 || transition_view_window!=1)
            $fatal(1,"soft-wipe transition did not target the selected quad window view=%b mode=%0d win=%0d manager=%b start=%b layout=%0d target=%0d state=%0d",
                   transition_view_active,transition_active_mode,transition_view_window,trans_active,
                   trans_start,transition_view_layout,tw,dut.state);
        for(i=0;i<68;i=i+1)pulse_view_vs();
        expect_result(2);repeat(8)@(negedge clk);
        if(trans_active || transition_effect_active || dut.indices[1]!=7 || cfg_window_buffers!=4'b1000)
            $fatal(1,"soft-wipe window commit/release failed");
        effect_mode=0;
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
