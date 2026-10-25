`timescale 1ns/1ps
module tb_multiview_transition_fetch;
    reg mem_clk=0,video_clk=0;
    always #5 mem_clk=~mem_clk;
    always #6.666 video_clk=~video_clk;
    reg rst=1,start=0,de=0,vs=0,view_mode=1,release_toggle=0;
    reg target_buffer=1;
    reg [1:0] layout=1,window=1,mode=1;
    reg sdr_busy=0;
    wire done,req,ready,rd_bank,row_ready,active,view_active,prev;
    wire [9:0] line_num,rd_addr,row_words,wr_addr;
    wire [20:0] line_base,app_addr;
    wire [31:0] rd_data,wr_data;
    wire wr_en,wr_bank,line_hold,app_en,frame_valid;
    reg [3:0] valid_pipe=0;
    reg [20:0] addr_pipe[0:3];
    wire sdr_valid=valid_pipe[3];
    wire [31:0] sdr_data={11'd0,addr_pipe[3]};
    wire [1:0] active_layout,active_window;
    wire [8:0] alpha;
    wire [10:0] progress;
    integer words=0,commands=0,expected_start=0;
    reg check_first=0;
    reg seen_ready;

    transition_ctrl #(.BUF0_ADDR(21'd0),.BUF1_ADDR(21'd460800)) ctrl(
        .video_clk(video_clk),.rst(rst),.start_toggle_raw(start),
        .target_buf_raw(target_buffer),.mode_raw(mode),.direction_prev_raw(1'b0),
        .view_transition_raw(view_mode),.view_layout_raw(layout),.view_window_raw(window),
        .release_toggle_raw(release_toggle),.done_toggle(done),.de_word(de),.vs_word(vs),
        .line_req_toggle(req),.line_num(line_num),.line_base(line_base),.row_words(row_words),
        .line_ready_toggle_raw(ready),.line_rd_bank(rd_bank),.line_rd_addr(rd_addr),
        .row_ready(row_ready),.effect_active(active),.active_mode(),.direction_prev(prev),
        .fade_alpha(alpha),.wipe_progress(progress),.view_active(view_active),
        .active_view_layout(active_layout),.active_view_window(active_window)
    );
    transition_line_read fetch(
        .mem_clk(mem_clk),.rst(rst),.sdr_init_done(1'b1),.sdr_busy(sdr_busy),.sdr_refresh(1'b0),
        .line_req_toggle(req),.line_num(line_num),.line_base(line_base),.row_words(row_words),
        .line_ready_toggle(ready),.frame_rd_en(1'b0),.frame_rd_addr(21'd0),
        .frame_wr_en(1'b0),.frame_rd_busy(1'b0),.frame_wr_busy(1'b0),
        .video_fifo_words(9'd400),.line_hold(line_hold),.app_rd_en(app_en),.app_rd_addr(app_addr),
        .sdr_rd_valid(sdr_valid),.sdr_rd_data(sdr_data),.frame_rd_valid(frame_valid),
        .line_wr_en(wr_en),.line_wr_data(wr_data),.line_wr_addr(wr_addr),.line_wr_bank(wr_bank)
    );
    transition_line_buf rows(.mem_clk(mem_clk),.wr_en(wr_en),.wr_bank(wr_bank),
        .wr_addr(wr_addr),.wr_data(wr_data),.video_clk(video_clk),.rd_bank(rd_bank),
        .rd_addr(rd_addr),.rd_data(rd_data));

    always @(posedge mem_clk)begin
        if(rst)begin valid_pipe<=0;words<=0;commands<=0;end
        else begin
            valid_pipe<={valid_pipe[2:0],app_en};
            addr_pipe[0]<=app_addr;addr_pipe[1]<=addr_pipe[0];
            addr_pipe[2]<=addr_pipe[1];addr_pipe[3]<=addr_pipe[2];
            if(check_first && app_en)begin
                if(app_addr!==expected_start+commands)
                    $fatal(1,"window row address mismatch cmd=%0d got=%0d expected=%0d",
                           commands,app_addr,expected_start+commands);
                commands<=commands+1;
            end
            if(check_first && wr_en)begin
                if(wr_addr!==words || wr_data!==32'(expected_start+words) || wr_bank!==1'b0)
                    $fatal(1,"window row data mismatch word=%0d addr=%0d data=%0d bank=%b",
                           words,wr_addr,wr_data,wr_bank);
                words<=words+1;
            end
            if(frame_valid)$fatal(1,"transition row data leaked into active frame FIFO");
        end
    end

    task automatic pulse_vs;
        begin @(negedge video_clk);vs=1;@(negedge video_clk);vs=0;end
    endtask

    task automatic start_case(input [1:0] new_layout,input [1:0] new_window,
                              input integer expected_base,input integer visible_start);
        integer timeout;
        begin
            rst=1;start=0;de=0;vs=0;layout=new_layout;window=new_window;
            release_toggle=0;check_first=0;
            repeat(6)@(negedge video_clk);
            rst=0;start=1;expected_start=expected_base;check_first=1;
            repeat(8)@(negedge video_clk);
            if(!view_active || active_layout!=new_layout || active_window!=new_window ||
               line_base!=expected_base || row_words!=320)
                $fatal(1,"wrong target row mapping layout=%0d window=%0d base=%0d words=%0d",
                       active_layout,active_window,line_base,row_words);
            seen_ready=ready;pulse_vs();timeout=0;
            while(ready==seen_ready && timeout<2000)begin @(negedge mem_clk);timeout=timeout+1;end
            if(timeout==2000)$fatal(1,"window line prefetch timeout");
            repeat(4)@(negedge mem_clk);
            if(commands!=320 || words!=320)
                $fatal(1,"window row fetch count cmd=%0d data=%0d",commands,words);
            check_first=0;

            // Scan visible rows. A bottom quad window must remain untouched
            // until its screen row, then report the prefetched local row.
            if(visible_start==360)begin
                for(timeout=0;timeout<360;timeout=timeout+1)begin
                    @(negedge video_clk);de=1;repeat(8)@(negedge video_clk);
                    if(row_ready)$fatal(1,"bottom window blended into upper screen row %0d",timeout);
                    de=0;@(negedge video_clk);
                end
                @(negedge video_clk);de=1;repeat(8)@(negedge video_clk);
                if(!row_ready)$fatal(1,"bottom-right window row 360 was not ready");
            end else begin
                @(negedge video_clk);de=1;repeat(8)@(negedge video_clk);
                if(!row_ready)$fatal(1,"side-by-side target row was not ready");
            end

            // At the target window's right edge, the line RAM address wraps
            // to local word zero; the next pair advances to local word one.
            repeat(632)@(negedge video_clk);
            if(rd_addr!=0)$fatal(1,"window-local row did not start at word 0: %0d",rd_addr);
            repeat(2)@(negedge video_clk);
            if(rd_addr!=1)$fatal(1,"window-local row did not advance to word 1: %0d",rd_addr);
            de=0;
        end
    endtask

    initial begin
        start_case(1,1,21'd691200,0);
        start_case(2,3,21'd806400,360);
        $display("PASS multiview transition fetch: dual-right and quad-bottom-right rows use 320-word local slots");
        $finish;
    end
    initial begin #20000000;$fatal(1,"multiview transition fetch timeout");end
endmodule
