`timescale 1ns/1ps
// Both production control/serialization paths, with a bounded source/write
// completion model. Pixel/FIFO correctness is covered by view-framepath and
// view-bilinear; this test covers the actual PREPARE/STATUS/RESULT byte streams.
module tb_view_control_path;
    reg clk=0,rst=1;always #4 clk=~clk;
    reg nr=0,pr=0,dr=0,lr=0,tr=0,local_step=0;
    reg [1:0] requested=0;
    reg [10:0] cx=0;reg [9:0] cy=0;
    reg [191:0] nexts=0,prevs=0;
    wire js,jpc,jprev,jready,jdone;
    wire [4:0] ji,current;
    wire [1:0] jl,jw,media_layout;
    wire [15:0] jg,media_gen;
    wire [7:0] jr;
    wire mbusy,current_valid,media_view_valid;
    wire [3:0] media_mask;
    wire [127:0] media_view;
    wire mreq,mvalid,mpc;
    wire [7:0] mdata;
    wire [15:0] mlen;
    wire dreq,dvalid;
    wire [7:0] ddata;
    wire [15:0] dlen;
    media_view_scheduler #(.CLK_HZ(10000)) media(.clk(clk),.rst(rst),.link_ready(jready),
        .next_request(nr),.prev_request(pr),.snapshot_request(dr),.layout_request(lr),.touch_request(tr),
        .requested_layout(requested),.first_bmp(6'd1),.bmp_next(nexts),.bmp_prev(prevs),
        .rx_data(ddata),.rx_valid(dvalid),.job_start(js),.job_snapshot(jpc),.job_previous(jprev),
        .job_index(ji),.job_layout(jl),.job_window(jw),.job_generation(jg),
        .job_done(jdone),.job_result(jr),.busy(mbusy),.current_index(current),.current_valid(current_valid),
        .active_layout(media_layout),.active_mask(media_mask),.active_generation(media_gen),
        .view_status_valid(media_view_valid),.view_status_body(media_view),
        .tx_request(mreq),.tx_valid(mvalid),.tx_data(mdata),.tx_length(mlen),.tx_to_pc(mpc),.tx_ack(mreq));
    wire pv,sq;wire [63:0] pb;
    view_protocol_rx decode(.clk(clk),.rst(rst),.data(mdata),.valid(mvalid && !mpc),
        .prepare_valid(pv),.prepare_body(pb),.status_request(sq));
    reg fb=0,wvalid=0,drain=0;
    reg [7:0] wresult=0;
    reg [15:0] fid=0;
    wire accepted,owned,abort_image,targetbuf,dbusy,pa,vs,rv,epoch,cb;
    wire [15:0] ownedid,tg,ag,rf;
    wire [1:0] tl,tw,al,focus,cl;
    wire [3:0] am,cm;
    wire [63:0] pbody;
    wire [127:0] vbody;
    wire [7:0] result;
    view_session_manager #(.CLK_HZ(10000)) display(.clk(clk),.rst(rst),
        .prepare_valid(pv),.prepare_body(pb),.status_request(sq),.cursor_x(cx),.cursor_y(cy),.local_step(local_step),
        .frame_begin(fb),.frame_id(fid),.frame_generation(jg),.frame_layout(jl),.frame_window(jw),.frame_index(ji),
        .frame_width(12'd571),.frame_height(12'd720),.writer_result_valid(wvalid),.writer_result(wresult),
        .transition_mode_cfg(2'd0),.transition_done_toggle(1'b0),
        .single_display_buffer(targetbuf),.cfg_drained_epoch(drain),.accepted_begin(accepted),.image_owned(owned),
        .owned_frame_id(ownedid),.abort_image(abort_image),.target_buffer(targetbuf),.target_layout(tl),
        .target_window(tw),.target_generation(tg),.busy(dbusy),.active_layout(al),.active_mask(am),
        .active_generation(ag),.focus_window(focus),.focus_index(),.focus_width(),.focus_height(),
        .prepare_reply_valid(pa),.prepare_reply_body(pbody),.view_status_valid(vs),.view_status_body(vbody),
        .image_result_valid(rv),.image_result(result),.image_result_frame(rf),
        .config_epoch(epoch),.config_buffer(cb),.config_layout(cl),.config_mask(cm),
        .config_window_buffers(),.view_transition_start_toggle(),.view_transition_mode(),
        .view_transition_direction_prev(),.view_transition_release_toggle(),.view_transition_active());
    media_display_tx #(.VIEW_ENABLE(1),.TX_GAP_CYCLES(4)) reply(.clk(clk),.rst(rst),
        .local_cmd_toggle_async(1'b0),.local_cmd_async(8'd0),.ready_valid(1'b0),
        .image_result_valid(rv),.image_result_code(result),.image_result_frame(rf),
        .audio_result_valid(1'b0),.audio_result_code(8'd0),.audio_result_frame(16'd0),
        .control_ack_valid(1'b0),.control_ack_sequence(8'd0),.control_ack_op(8'd0),
        .control_ack_status(8'd0),.control_ack_value(8'd0),.status_valid(1'b0),.status_payload(64'd0),
        .tx_request(dreq),.tx_valid(dvalid),.tx_data(ddata),.tx_length(dlen),.tx_ready(1'b1),.tx_ack(dreq),
        .view_busy(dbusy),.view_prepare_valid(pa),.view_prepare_body(pbody),.view_status_valid(vs),.view_status_body(vbody));
    reg epoch_seen=0;
    integer drain_count=0,job_clock=-1,jobs=0,display_position=0,pc_snapshots=0;
    reg [7:0] display_bytes[0:23];
    reg jdone_r=0;reg [7:0] jr_r=0;
    assign jdone=jdone_r;assign jr=jr_r;assign jready=job_clock<0;
    always @(posedge clk)begin
        fb<=0;wvalid<=0;jdone_r<=0;
        if(epoch_seen!=epoch)begin epoch_seen<=epoch;drain_count<=35;end
        else if(drain_count>0)begin drain_count<=drain_count-1;if(drain_count==1)drain<=epoch;end
        if(js)begin
            jobs<=jobs+1;job_clock<=0;fid<=fid+1;
            if(jpc)pc_snapshots<=pc_snapshots+1;
            else fb<=1;
        end else if(job_clock>=0)begin
            job_clock<=job_clock+1;
            if(job_clock==10 && !jpc)begin wvalid<=1;wresult<=0;end
            if(job_clock==15 && !jpc && jl==0)begin wvalid<=1;wresult<=2;end
            if(job_clock==20 && jpc)begin jdone_r<=1;jr_r<=2;job_clock<=-1;end
        end
        if(dvalid)begin display_bytes[display_position]<=ddata;display_position<=display_position+1;end
        else if(display_position!=0)begin
            if(display_position==11 && display_bytes[4]==8'h24 && display_bytes[5]==0 &&
               display_bytes[8]==fid[7:0] && display_bytes[9]==fid[15:8] &&
               (display_bytes[10]==2 || display_bytes[10]==3) && job_clock>=0)begin
                jdone_r<=1;jr_r<=display_bytes[10];job_clock<=-1;
            end
            display_position<=0;
        end
    end
    task automatic idle;
        integer n;
        begin
            n=0;
            do begin @(negedge clk);n=n+1;end while((mbusy || !current_valid) && n<40000);
            if(n==40000)$fatal(1,"control path timeout mstate=%0d dstate=%0d mask=%b gen=%0d jobs=%0d",media.state,display.state,am,ag,jobs);
            repeat(10)@(negedge clk);
        end
    endtask
    task automatic mode(input integer value);
        begin @(negedge clk);lr=1;requested=value;@(negedge clk);lr=0;repeat(5)@(negedge clk);idle();end
    endtask
    task automatic step(input bit previous);
        begin @(negedge clk);nr=!previous;pr=previous;@(negedge clk);nr=0;pr=0;repeat(5)@(negedge clk);idle();end
    endtask
    integer before_jobs;
    initial begin
        nexts[6*1+:6]=3;nexts[6*3+:6]=5;nexts[6*5+:6]=6;nexts[6*6+:6]=7;nexts[6*7+:6]=9;nexts[6*9+:6]=1;
        prevs[6*1+:6]=9;prevs[6*3+:6]=1;prevs[6*5+:6]=3;prevs[6*6+:6]=5;prevs[6*7+:6]=6;prevs[6*9+:6]=7;
        repeat(10)@(negedge clk);rst=0;idle();
        if(jobs!=1 || display.indices[0]!=1)$fatal(1,"boot schedule");
        mode(1);
        if(am!=3 || al!=1 || display.indices[0]!=1 || display.indices[1]!=3)$fatal(1,"dual initial page");
        cx=900;cy=200;before_jobs=jobs;
        @(negedge clk);nr=1;@(negedge clk);nr=0;
        wait(job_clock>=0);cx=10;
        @(negedge clk);nr=1;@(negedge clk);nr=0;
        idle();if(jobs!=before_jobs+1 || display.indices[1]!=5 || display.indices[0]!=1)$fatal(1,"busy step queued or focus moved");
        before_jobs=jobs;mode(2);
        if(al!=1 || jobs!=before_jobs)$fatal(1,"illegal dual to quad accepted");
        cx=900;mode(0);if(display.indices[0]!=5 || al!=0)$fatal(1,"focused return single");
        mode(2);
        if(al!=2 || am!=15 || display.indices[0]!=5 || display.indices[1]!=6 || display.indices[2]!=7 || display.indices[3]!=9)
            $fatal(1,"quad list initialization");
        cx=900;cy=500;step(0);if(display.indices[3]!=1)$fatal(1,"list wrap next");
        step(1);if(display.indices[3]!=9)$fatal(1,"list wrap previous");
        cx=900;cy=0;@(negedge clk);local_step=1;@(negedge clk);local_step=0;cx=0;
        tr=1;pr=1;@(negedge clk);tr=0;pr=0;repeat(5)@(negedge clk);idle();
        if(display.indices[1]!=5 || display.indices[0]!=5)$fatal(1,"local touch focus lock");
        cx=900;cy=500;@(negedge clk);dr=1;@(negedge clk);dr=0;repeat(5)@(negedge clk);idle();
        if(pc_snapshots!=1 || ji!=9 || al!=2)$fatal(1,"snapshot transaction selected wrong source");
        $display("PASS: paired PREPARE/STATUS packets, boot, 2/4 windows, independent N/P, wrap, busy drop, touch and D");$finish;
    end
    initial begin #10000000;$fatal(1,"control path watchdog");end
endmodule
