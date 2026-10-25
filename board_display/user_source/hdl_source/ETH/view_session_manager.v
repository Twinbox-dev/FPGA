`timescale 1ns/1ps
// UDP-domain owner of layout transactions. Same-layout window updates keep the
// old window visible while its opposite page is written, then commit that
// window's relative page bit at VS and wait for the memory-reader drain ACK.
module view_session_manager #(
    parameter integer CLK_HZ=125000000
)(
    input wire clk,rst,
    input wire prepare_valid,
    input wire [63:0] prepare_body,
    input wire status_request,
    input wire [10:0] cursor_x,
    input wire [9:0] cursor_y,
    input wire local_step,
    input wire frame_begin,
    input wire [15:0] frame_id,frame_generation,
    input wire [1:0] frame_layout,frame_window,
    input wire [4:0] frame_index,
    input wire [11:0] frame_width,frame_height,
    input wire writer_result_valid,
    input wire [7:0] writer_result,
    input wire [1:0] transition_mode_cfg,
    input wire transition_done_toggle,
    input wire single_display_buffer,
    input wire cfg_drained_epoch,
    output wire accepted_begin,
    output wire image_owned,
    output wire [15:0] owned_frame_id,
    output reg abort_image,
    output reg target_buffer,
    output reg [1:0] target_layout,target_window,
    output reg [15:0] target_generation,
    output wire busy,
    output reg [1:0] active_layout,
    output reg [3:0] active_mask,
    output reg [15:0] active_generation,
    output reg [1:0] focus_window,
    output reg [4:0] focus_index,
    output reg [11:0] focus_width,focus_height,
    output reg prepare_reply_valid,
    output reg [63:0] prepare_reply_body,
    output reg view_status_valid,
    output reg [127:0] view_status_body,
    output reg image_result_valid,
    output reg [7:0] image_result,
    output reg [15:0] image_result_frame,
    output reg config_epoch,config_buffer,
    output reg [1:0] config_layout,
    output reg [3:0] config_mask,
    output reg [3:0] config_window_buffers,
    output reg view_transition_start_toggle,
    output reg [1:0] view_transition_mode,
    output reg view_transition_direction_prev,
    output reg view_transition_release_toggle,
    output reg view_transition_active
);
    localparam IDLE=0,TRANSFER=1,SHOW_WAIT=2,SNAPSHOT=3,CANCEL_DRAIN=4,VIEW_TRANSITION=5;
    reg [2:0] state;
    reg active_buffer,active_valid,page_build,owned;
    reg [3:0] staged_mask,active_window_buffers;
    reg transition_commit_wait;
    reg [1:0] pending_transition_mode;
    reg target_direction_prev;
    // Metadata follows physical image banks. Committing a page changes a bank
    // pointer instead of copying four wide register records in parallel.
    reg [19:0] bank_indices[0:1];
    wire [4:0] indices[0:3];
    wire [3:0] selected_pages={4{active_buffer}}^active_window_buffers;
    genvar mw;
    generate for(mw=0;mw<4;mw=mw+1)begin:g_indices
        assign indices[mw]=bank_indices[selected_pages[mw]][mw*5+:5];
    end endgenerate
    reg [23:0] dimensions[0:7]; /* fehdl force_ram=1, ram_style="bram" */
    reg [23:0] focus_dimensions;
    reg [2:0] focus_tag;
    reg [23:0] pending_dimensions;
    reg [4:0] pending_index;
    reg [15:0] accepted_id;
    reg [7:0] request_sequence,event_sequence,last_result;
    reg [4:0] prepare_base_index;
    reg [47:0] last_request;
    reg [1:0] cached_window;
    reg [3:0] cached_mask;
    reg cache_valid,local_target_valid;
    reg [1:0] local_target;
    reg [2:0] drain_sync,transition_sync;
    reg [29:0] watchdog;
    wire [7:0] req_action=prepare_body[15:8];
    wire [7:0] req_layout=prepare_body[23:16];
    wire [7:0] req_window=prepare_body[31:24];
    wire [15:0] req_generation=prepare_body[47:32];
    wire [1:0] cursor_window=active_layout==0 ? 2'd0 :
                            (active_layout==1 ? {1'b0,cursor_x>=640} :
                             {cursor_y>=360,cursor_x>=640});
    wire transition_done_pulse=transition_sync[2]^transition_sync[1];
    wire [1:0] chosen_window=req_window==8'hfe && local_target_valid ? local_target :
                             (req_window>=8'hfe ? cursor_window : req_window[1:0]);
    wire [3:0] full_mask=target_layout==2 ? 4'b1111 : (target_layout==1 ? 4'b0011 : 4'b0001);
    wire metadata_commit=writer_result_valid && owned && state==TRANSFER &&
                         ((target_layout!=0 && writer_result==0) || (target_layout==0 && writer_result==2));
    always @(posedge clk)begin
        if(metadata_commit)dimensions[{target_buffer,target_window}]<=pending_dimensions;
        focus_dimensions<=dimensions[{selected_pages[cursor_window],cursor_window}];
    end
    wire focus_tag_matches=focus_tag=={selected_pages[cursor_window],cursor_window};
    wire legal_request=req_layout<=2 && !(active_layout!=0 && req_layout!=0 && req_layout!=active_layout) &&
                       prepare_body[63:48]==0 && (req_window>=8'hfe || req_window<4) &&
                       !(active_layout==1 && chosen_window>1) && req_action<=5;
    assign busy=state!=IDLE;
    assign image_owned=owned;
    assign owned_frame_id=accepted_id;
    assign accepted_begin=frame_begin && state==TRANSFER && !owned &&
        frame_layout==target_layout && frame_window==target_window && frame_generation==target_generation;
    task automatic reply(input [7:0] result,input [1:0] win,input [15:0] generation,
                          input [4:0] index,input [3:0] mask_value);
        begin
            prepare_reply_valid<=1;
            prepare_reply_body<={4'd0,mask_value,3'd0,index,generation,6'd0,target_layout,6'd0,win,result,request_sequence};
        end
    endtask
    task automatic result(input [7:0] code);
        begin image_result_valid<=1;image_result<=code;image_result_frame<=accepted_id;end
    endtask
    task automatic status_event(input [7:0] result_code);
        begin
            view_status_valid<=1;event_sequence<=event_sequence+1'b1;last_result<=result_code;
            view_status_body[7:0]<=event_sequence;
            view_status_body[23:8]<=active_generation;
            view_status_body[31:24]<={6'd0,active_layout};
            view_status_body[39:32]<={7'd0,busy};
            view_status_body[47:40]<={6'd0,cursor_window};
            view_status_body[55:48]<={4'd0,active_mask};
            view_status_body[63:56]<={3'd0,indices[0]};
            view_status_body[71:64]<={3'd0,indices[1]};
            view_status_body[79:72]<={3'd0,indices[2]};
            view_status_body[87:80]<={3'd0,indices[3]};
            view_status_body[103:88]<=active_valid ? {4'd0,focus_dimensions[11:0]} : 16'd0;
            view_status_body[119:104]<=active_valid ? {4'd0,focus_dimensions[23:12]} : 16'd0;
            view_status_body[127:120]<=result_code;
        end
    endtask
    reg publish_pending;
    integer i;
    always @(posedge clk or posedge rst)begin
        if(rst)begin
            state<=IDLE;active_layout<=0;active_mask<=0;active_generation<=0;
            active_buffer<=0;active_window_buffers<=0;active_valid<=0;page_build<=0;owned<=0;staged_mask<=0;
            target_buffer<=0;target_layout<=0;target_window<=0;target_generation<=0;
            config_epoch<=0;config_buffer<=0;config_layout<=0;config_mask<=0;
            config_window_buffers<=0;drain_sync<=0;transition_sync<=0;
            view_transition_start_toggle<=0;view_transition_mode<=0;
            view_transition_direction_prev<=0;view_transition_release_toggle<=0;
            view_transition_active<=0;transition_commit_wait<=0;
            accepted_id<=0;request_sequence<=0;event_sequence<=0;last_result<=0;
            last_request<=0;cached_window<=0;cached_mask<=0;cache_valid<=0;local_target_valid<=0;local_target<=0;
            prepare_base_index<=0;
            watchdog<=0;abort_image<=0;prepare_reply_valid<=0;prepare_reply_body<=0;
            view_status_valid<=0;view_status_body<=0;image_result_valid<=0;image_result<=0;image_result_frame<=0;
            focus_window<=0;focus_index<=0;focus_width<=0;focus_height<=0;publish_pending<=0;
            bank_indices[0]<=0;bank_indices[1]<=0;focus_tag<=0;pending_dimensions<=0;pending_index<=0;
            pending_transition_mode<=0;target_direction_prev<=0;
        end else begin
            drain_sync<={drain_sync[1:0],cfg_drained_epoch};
            transition_sync<={transition_sync[1:0],transition_done_toggle};
            prepare_reply_valid<=0;view_status_valid<=0;image_result_valid<=0;abort_image<=0;
            focus_window<=cursor_window;focus_index<=indices[cursor_window];
            focus_tag<={selected_pages[cursor_window],cursor_window};
            focus_width<=active_valid && focus_tag_matches ? focus_dimensions[11:0] : 12'd0;
            focus_height<=active_valid && focus_tag_matches ? focus_dimensions[23:12] : 12'd0;
            if(local_step && !busy)begin local_target<=cursor_window;local_target_valid<=1;end
            if(status_request || focus_window!=cursor_window)publish_pending<=1;
            if(publish_pending && (!active_valid || focus_tag_matches))begin
                status_event(last_result);publish_pending<=0;
            end
            if(busy)watchdog<=watchdog+1'b1;else watchdog<=0;
            // Timeout aborts the producer into deterministic padding first; it
            // does not unlock a bank while its old write request still exists.
            if(owned && watchdog>=CLK_HZ*8-1 && state==TRANSFER)begin
                abort_image<=1;state<=CANCEL_DRAIN;watchdog<=0;
            end
            if(!owned && watchdog>=CLK_HZ*8-1 && (state==TRANSFER || state==SNAPSHOT))begin
                state<=IDLE;cache_valid<=0;publish_pending<=1;last_result<=1;
            end
            if(accepted_begin)begin
                owned<=1;accepted_id<=frame_id;watchdog<=0;
                pending_index<=frame_index;pending_dimensions<={frame_height,frame_width};
            end
            if(frame_begin && !accepted_begin)begin
                image_result_valid<=1;image_result<=8'h11;image_result_frame<=frame_id;
            end
            if(prepare_valid)begin
                if(req_action==3 || req_action==5)begin
                    if(req_action==5 && state==SNAPSHOT)begin state<=IDLE;publish_pending<=1;end
                    else if(req_action==3 && !owned && state!=SHOW_WAIT && state!=VIEW_TRANSITION)begin
                        state<=IDLE;publish_pending<=1;cache_valid<=0;
                    end else if(req_action==3 && owned && state==TRANSFER)begin
                        abort_image<=1;state<=CANCEL_DRAIN;
                    end
                    prepare_reply_valid<=1;prepare_reply_body<={56'd0,prepare_body[7:0]};
                end else if(cache_valid && busy && prepare_body[47:0]==last_request &&
                            prepare_body[63:48]==0)begin
                    prepare_reply_valid<=1;
                    prepare_reply_body<={4'd0,cached_mask,3'd0,prepare_base_index,target_generation,
                                        6'd0,target_layout,6'd0,cached_window,8'd0,request_sequence};
                end else if(busy || !legal_request || req_generation!=active_generation)begin
                    last_result<=busy ? 1 : (req_generation!=active_generation ? 3 : 2);publish_pending<=1;
                    prepare_reply_valid<=1;
                    prepare_reply_body<={16'd0,active_generation,6'd0,active_layout,6'd0,cursor_window,
                                         (busy ? 8'd1 : (req_generation!=active_generation ? 8'd3 : 8'd2)),prepare_body[7:0]};
                end else begin
                    request_sequence<=prepare_body[7:0];last_request<=prepare_body[47:0];local_target_valid<=0;
                    prepare_base_index<=indices[chosen_window];
                    target_layout<=req_layout[1:0];
                    target_window<=req_layout!=active_layout ? 2'd0 : chosen_window;
                    target_generation<=req_layout!=active_layout ? active_generation+1'b1 : active_generation;
                    target_buffer<=req_layout!=0 && req_layout==active_layout ?
                                   ~(active_buffer ^ active_window_buffers[chosen_window]) :
                                   (active_valid ? ~active_buffer : 1'b0);
                    page_build<=req_layout!=0 && req_layout!=active_layout;
                    staged_mask<=req_layout!=active_layout ? 4'd0 : active_mask;
                    pending_transition_mode<=transition_mode_cfg;
                    target_direction_prev<=req_action==2;
                    transition_commit_wait<=0;
                    watchdog<=0;publish_pending<=1;last_result<=0;
                    if(req_action==4)state<=SNAPSHOT;
                    else state<=TRANSFER;
                    cache_valid<=0;
                end
            end
            // Build the response only after the chosen target registers settle.
            if(!cache_valid && (state==TRANSFER || state==SNAPSHOT))begin
                reply(0,target_window,target_generation,prepare_base_index,active_mask);
                cached_window<=target_window;cached_mask<=active_mask;
                cache_valid<=1;
            end
            if(writer_result_valid && owned)begin
                if(metadata_commit)bank_indices[target_buffer][target_window*5+:5]<=pending_index;
                if(state==CANCEL_DRAIN)begin
                    result(1);state<=IDLE;owned<=0;cache_valid<=0;publish_pending<=1;last_result<=1;
                end else if(writer_result[7:4]!=0 || writer_result==1)begin
                    result(writer_result);owned<=0;watchdog<=0;last_result<=1;publish_pending<=1;
                end else if(target_layout==0 && writer_result==0)begin
                    result(0); // single image accepted: existing WAV/transition follows
                end else if(target_layout!=0 && writer_result==0)begin
                    owned<=0;staged_mask<=staged_mask | (4'b0001<<target_window);
                    if(page_build && ((staged_mask | (4'b0001<<target_window))!=full_mask))begin
                        target_window<=target_window+1'b1;result(3);watchdog<=0;
                    end else if(page_build)begin
                        config_buffer<=target_buffer;config_layout<=target_layout;
                        config_mask<=full_mask;config_window_buffers<=4'd0;
                        config_epoch<=~config_epoch;state<=SHOW_WAIT;
                    end else if(pending_transition_mode!=0)begin
                        view_transition_mode<=pending_transition_mode;
                        view_transition_direction_prev<=target_direction_prev;
                        view_transition_active<=1'b1;
                        view_transition_start_toggle<=~view_transition_start_toggle;
                        transition_commit_wait<=1'b1;
                        state<=VIEW_TRANSITION;watchdog<=0;
                    end else begin
                        config_buffer<=active_buffer;config_layout<=active_layout;
                        config_mask<=active_mask;
                        config_window_buffers<=active_window_buffers ^ (4'b0001<<target_window);
                        config_epoch<=~config_epoch;state<=SHOW_WAIT;
                        transition_commit_wait<=1'b0;
                    end
                end else if(target_layout==0 && writer_result==2)begin
                    owned<=0;config_buffer<=single_display_buffer;config_layout<=0;config_mask<=1;
                    config_window_buffers<=4'd0;transition_commit_wait<=1'b0;
                    config_epoch<=~config_epoch;state<=SHOW_WAIT;
                end
            end
            if(state==VIEW_TRANSITION && transition_done_pulse)begin
                config_buffer<=active_buffer;config_layout<=active_layout;config_mask<=active_mask;
                config_window_buffers<=active_window_buffers ^ (4'b0001<<target_window);
                config_epoch<=~config_epoch;state<=SHOW_WAIT;transition_commit_wait<=1'b1;
            end
            if(state==SHOW_WAIT && drain_sync[2]==config_epoch)begin
                active_buffer<=config_buffer;active_layout<=config_layout;active_mask<=config_mask;
                active_window_buffers<=config_window_buffers;
                active_generation<=target_generation;active_valid<=1;
                state<=IDLE;cache_valid<=0;result(2);publish_pending<=1;last_result<=0;
                if(transition_commit_wait)begin
                    view_transition_release_toggle<=~view_transition_release_toggle;
                    view_transition_active<=1'b0;transition_commit_wait<=1'b0;
                end
            end
        end
    end
endmodule
